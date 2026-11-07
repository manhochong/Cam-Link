package hk.camlink.usb;

import android.accounts.AccountManager;
import android.app.*;
import android.content.*;
import android.content.pm.*;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.*;
import android.widget.*;
import com.google.android.gms.auth.api.identity.*;
import com.google.android.gms.common.api.ApiException;
import org.json.*;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;

public final class CloudActivity extends ConsoleActivity {
    private final Handler handler=new Handler(Looper.getMainLooper());private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private TextView account,folder,state,list;private Switch enabled,wifi;private Button login,choose,create,importButton;private boolean busy,refreshing;
    private String pendingEmail="";
    private Button manage,openFolder,resume,pause,history,tools,byEvent;
    private LinearLayout support,historyPanel;
    private QueueStrip queueStrip; private TextView queueScope; private LinearLayout settings;
    private boolean editing,showHistory,showSupport;
    private CloudNetwork internet;
    private SharedPreferences prefs(){return CloudStore.prefs(this);}
    private final Runnable tick=new Runnable(){public void run(){refresh();handler.postDelayed(this,1000);}};
    @Override public void onCreate(Bundle b){super.onCreate(b);if(b!=null)pendingEmail=b.getString("email","");
        internet=new CloudNetwork(this);
        LinearLayout root=page(); masthead(root,"Google Drive","TRANSFER");
        editing=b!=null&&b.getBoolean("editing");
        showHistory=b!=null&&b.getBoolean("history");
        showSupport=b!=null&&b.getBoolean("support");
        Button back=button(root,"‹   返回目的地",false,()->finish()); back.setGravity(android.view.Gravity.START|android.view.Gravity.CENTER_VERTICAL);back.setBackgroundColor(BG);back.setTextColor(MUTED);
        LinearLayout progressCard=card(root); section(progressCard,"01","上傳進度");
        queueScope=label(progressCard,"此帳戶累計 · 張",12,MUTED); queueStrip=new QueueStrip(progressCard);
        LinearLayout destination=card(root); section(destination,"02","上傳目的地");
        account=label(destination,"",16,TEXT);
        folder=label(destination,"",16,TEXT);
        manage=button(destination,"更改帳戶或資料夾",false,()->{editing=!editing;refresh();});
        login=button(destination,"登入 Google",true,this::chooseAccount);
        choose=button(destination,"選擇已有資料夾",false,this::chooseFolder);
        create=button(destination,"建立上傳資料夾",true,this::createFolder);
        byEvent=button(destination,"改為按活動名稱建資料夾",false,()->{
            prefs().edit().remove("folder").remove("folder_name").apply();
            editing=false;refresh();
        });
        openFolder=button(destination,"在 Drive 查看照片",false,()->{
            String id=prefs().getString("folder","");
            if(!id.isEmpty()) startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse("https://drive.google.com/drive/folders/"+Uri.encode(id))));
        });
        settings=card(root);section(settings,"03","上傳設定");
        enabled=new Switch(this);enabled.setText("自動上傳新拍 JPG");enabled.setTextColor(TEXT);enabled.setPadding(0,dp(12),0,dp(12));settings.addView(enabled);
        enabled.setOnCheckedChangeListener((v,on)->{if(refreshing)return;prefs().edit().putBoolean("enabled",on).apply();if(on){prefs().edit().putBoolean("paused",false).apply();UploadService.start(this);}refresh();});
        wifi=new Switch(this);wifi.setText("只用 Wi-Fi（關閉可用 4G／5G）");wifi.setTextColor(TEXT);wifi.setPadding(0,dp(10),0,dp(10));settings.addView(wifi);wifi.setOnCheckedChangeListener((v,on)->{if(!refreshing)prefs().edit().putBoolean("wifi",on).apply();});
        label(settings,"Wi-Fi 連相機時，關閉「只用 Wi-Fi」並開啟流動數據，Drive 便可用 4G／5G 上傳；照片會使用流動數據用量。",13,MUTED);
        label(settings,"自動上傳設定適用於下一輪拍攝。",13,MUTED);
        state=label(progressCard,"",15,MUTED);
        resume=button(progressCard,"繼續上傳",true,()->{
            if(!prefs().getBoolean("paused",false))CloudStore.get(this).retry(prefs().getString("account",""));
            prefs().edit().putBoolean("paused",false).apply();UploadService.start(this);refresh();
        });
        pause=button(progressCard,"暫停上傳",false,()->{UploadService.pause(this);refresh();});
        history=button(progressCard,"查看最近照片",false,()->{showHistory=!showHistory;refresh();});
        historyPanel=new LinearLayout(this);historyPanel.setOrientation(LinearLayout.VERTICAL);progressCard.addView(historyPanel);
        list=label(historyPanel,"",14,TEXT);list.setTextIsSelectable(true);
        tools=button(root,showSupport?"收起更多工具":"更多工具",false,()->{
            showSupport=!showSupport;refresh();
        });
        support=new LinearLayout(this);support.setOrientation(LinearLayout.VERTICAL);root.addView(support);
        importButton=button(support,"將最近一輪 JPG 加入上傳",false,this::importLatest);
        button(support,"Google 登入設定說明",false,this::setup);
        button(support,"匯出上傳結果 JSON",false,()->startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json").putExtra(Intent.EXTRA_TITLE,"CamLink-upload-report.json"),73));
        button(support,"登出 Cam Link",false,this::disconnect);
        button(support,"管理 Google 帳戶授權",false,()->new AlertDialog.Builder(this).setTitle("Google 授權由專案共用").setMessage("Cam Link 使用 Gonfolio 的 Google Cloud 專案。若在 Google 帳戶撤銷 Gonfolio 授權，同專案其他 App 也可能需要重新登入。").setPositiveButton("開啟 Google 設定",(d,w)->startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse("https://myaccount.google.com/permissions")))).setNegativeButton("取消",null).show());
        refresh();
    }
    private void text(TextView v,String s){if(!v.getText().toString().equals(s))v.setText(s);}
    private void refresh(){if(account==null)return;String id=prefs().getString("account","");boolean locked=CaptureService.running||UploadService.running||busy;
        boolean signedIn=!id.isEmpty(),hasFolder=configured(),paused=prefs().getBoolean("paused",false);
        text(account,signedIn?prefs().getString("email",""):"先登入要儲存照片的 Google 帳戶");
        text(folder,hasFolder?"固定資料夾　"+prefs().getString("folder_name",""):"按活動名稱在「我的雲端硬碟」建立場次資料夾");
        visible(byEvent,hasFolder&&editing);byEvent.setEnabled(!locked);
        visible(folder,signedIn);
        visible(manage,signedIn);text(manage,editing?"收起目的地設定":"更改帳戶或資料夾");
        visible(login,!signedIn||editing);text(login,signedIn?"重新登入或更改帳戶":"登入 Google");
        visible(choose,signedIn&&(!hasFolder||editing));visible(create,signedIn&&(!hasFolder||editing));
        visible(openFolder,hasFolder);
        visible(settings,signedIn);visible(enabled,signedIn);visible(wifi,signedIn);
        refreshing=true;enabled.setChecked(prefs().getBoolean("enabled",false));wifi.setChecked(prefs().getBoolean("wifi",false));refreshing=false;
        enabled.setEnabled(!CaptureService.running&&!busy);
        login.setEnabled(!locked);choose.setEnabled(!locked);create.setEnabled(!locked);importButton.setEnabled(!CaptureService.running&&!busy&&hasFolder);
        boolean unfinished=signedIn&&CloudStore.get(this).hasUnfinished(id);
        visible(resume,signedIn&&(paused||(!UploadService.running&&unfinished)));
        text(resume,paused?"繼續待傳佇列":"重試此帳戶的上傳");
        visible(pause,signedIn&&UploadService.running&&!paused);
        text(tools,showSupport?"收起更多工具":"更多工具");
        visible(history,signedIn);text(history,showHistory?"收起最近照片":"查看最近照片");
        visible(historyPanel,showHistory&&signedIn);visible(support,showSupport);
        double rate=UploadService.running?UploadService.sent/1e6/Math.max(0.001,(SystemClock.elapsedRealtime()-UploadService.started)/1000.0):0;
        visible(queueStrip,signedIn); visible(queueScope,signedIn);
        if(signedIn)queueStrip.display(CloudStore.get(this).counts(id));
        String status=busy?"處理中…":UploadService.running?UploadService.status:paused&&signedIn?"上傳已暫停":"";
        if(!UploadService.running&&signedIn&&!paused&&CloudStore.get(this).pending(id))status="有照片等待上傳，請按「繼續上傳」。";
        String warning=prefs().getString("recovery_warning","");
        String error=prefs().getString("cloud_error","");
        String progress=(status.isEmpty()&&signedIn?(unfinished?"有照片需要處理":"目前沒有待傳照片"):status)
            +(UploadService.running?String.format(Locale.US,"\n整輪平均（含等待） %.2f MB/s",rate):"")
            +(warning.isEmpty()?"":"\n"+warning)+(error.isEmpty()?"":"\n上次錯誤："+error);
        String timing=prefs().getString("last_file_rate_"+id,"");
        if(signedIn&&!timing.isEmpty())progress+="\n最近一次完整上傳及核對\n"+timing;
        text(state,progress.trim().isEmpty()?"登入並設定資料夾後，可在這裡查看上傳進度。":progress.trim());
        if(showHistory&&signedIn){String recent=CloudStore.get(this).recent(id);text(list,recent.isEmpty()?"還沒有上傳紀錄":recent);}
    }
    private static void visible(android.view.View view,boolean show){view.setVisibility(show?android.view.View.VISIBLE:android.view.View.GONE);}
    private boolean configured(){return !prefs().getString("account","").isEmpty()&&!prefs().getString("folder","").isEmpty();}
    private DriveApi api(){String id=prefs().getString("account",""),email=prefs().getString("email","");return new DriveApi(()->CloudAuth.token(this,id,email,internet),internet);}
    private interface Task {void run()throws Exception;}
    private void work(Task action){if(busy)return;busy=true;refresh();worker.execute(()->{try{action.run();prefs().edit().remove("cloud_error").apply();}catch(Exception e){String detail=error(e);prefs().edit().putString("cloud_error",detail).apply();runOnUiThread(()->message(detail));}finally{runOnUiThread(()->{busy=false;refresh();});}});}
    private String error(Exception e){if(e instanceof ApiException){int code=((ApiException)e).getStatusCode();return "Google 授權失敗（"+code+"）。請確認已啟用 Drive API、加入測試使用者，並登記本 App 的 package 與 SHA-1。可按『Google 登入設定說明』查看。";}return UploadService.safeError(e);}
    private void message(String s){if(!isFinishing()&&!isDestroyed())new AlertDialog.Builder(this).setTitle("Cam Link · Google Drive").setMessage(s).setPositiveButton("知道了",null).show();}
    private void chooseAccount(){startActivityForResult(AccountManager.newChooseAccountIntent(null,null,new String[]{"com.google"},null,null,null,null),70);}
    private void authorize(){busy=true;refresh();Identity.getAuthorizationClient(this).authorize(CloudAuth.request(pendingEmail)).addOnSuccessListener(r->{
        if(r.hasResolution()){try{startIntentSenderForResult(r.getPendingIntent().getIntentSender(),71,null,0,0,0);}catch(Exception e){authFailure(e);}}
        else accept(r);
    }).addOnFailureListener(this::authFailure);}
    private void authFailure(Exception e){busy=false;String detail=error(e);prefs().edit().putString("cloud_error",detail).apply();message(detail);refresh();}
    private void accept(AuthorizationResult result){busy=false;String access=result.getAccessToken();if(access==null){message("未取得 Drive 授權，請重試");refresh();return;}
        work(()->{JSONObject user=new DriveApi(()->access,internet).user();String id=user.getString("permissionId"),email=user.getString("emailAddress");
            if(!email.equalsIgnoreCase(pendingEmail))throw new IOException("Google 回傳的帳戶與所選帳戶不同，請重新選擇");
            String old=prefs().getString("account","");SharedPreferences.Editor edit=prefs().edit().putString("account",id).putString("email",email).putBoolean("paused",true);
            if(!old.equals(id))edit.remove("folder").remove("folder_name").putBoolean("enabled",false);edit.commit();CloudAuth.remember(access,email,id);
            runOnUiThread(()->message("已登入 "+email+"。啟用自動上傳後，可使用固定資料夾或按活動名稱建資料夾。"));
        });
    }
    private void chooseFolder(){work(()->{JSONArray folders=api().folders();String[] names=new String[folders.length()];for(int i=0;i<names.length;i++)names[i]=folders.getJSONObject(i).getString("name");
        runOnUiThread(()->{if(names.length==0){message("尚沒有本 App 可存取的資料夾，請按『建立上傳資料夾』。");return;}new AlertDialog.Builder(this).setTitle("選擇上傳資料夾").setItems(names,(d,w)->{try{select(folders.getJSONObject(w));}catch(Exception e){message(error(e));}}).setNegativeButton("取消",null).show();});});}
    private void select(JSONObject f)throws Exception {String id=f.getString("id"),name=f.getString("name");work(()->{api().checkFolder(id);prefs().edit().putString("folder",id).putString("folder_name",name).commit();});}
    private void createFolder(){EditText input=new EditText(this);input.setSingleLine(true);input.setText("Cam Link "+new java.text.SimpleDateFormat("yyyy-MM-dd",Locale.US).format(new Date()));new AlertDialog.Builder(this).setTitle("在我的雲端硬碟建立資料夾").setView(input).setPositiveButton("建立",(d,w)->{
        String name=input.getText().toString().trim();if(name.isEmpty()||name.length()>120){message("請輸入 1–120 字的名稱");return;}
        work(()->{DriveApi a=api();String key=prefs().getString("account","")+"\n"+name;String id=prefs().getString("folder_pending_key","").equals(key)?prefs().getString("folder_pending_id",""):"";
            if(id.isEmpty()){id=a.generateId();if(!prefs().edit().putString("folder_pending_key",key).putString("folder_pending_id",id).commit())throw new IOException("無法保存資料夾建立紀錄");}
            try{a.createFolder(name,id);}catch(DriveApi.Failure e){if(e.status!=409)throw e;}
            a.checkFolder(id);prefs().edit().putString("folder",id).putString("folder_name",name).remove("folder_pending_key").remove("folder_pending_id").commit();
        });
    }).setNegativeButton("取消",null).show();}
    private void importLatest(){if(!configured()){message("請先選擇上傳資料夾");return;}String path=getSharedPreferences("state",MODE_PRIVATE).getString("last_session","");if(path.isEmpty()){message("沒有最近接收紀錄");return;}
        new AlertDialog.Builder(this).setTitle("加入最近一輪原圖？").setMessage("將 "+new File(path).getName()+" 的完整 JPG 加入 "+prefs().getString("email","")+" / "+prefs().getString("folder_name","")+"。不加入 .part 或 RAW。").setPositiveButton("加入",(d,w)->work(()->{
            JSONObject dest=new JSONObject().put("account",prefs().getString("account","")).put("email",prefs().getString("email","")).put("folder",prefs().getString("folder",""));
            int count=CloudStore.get(this).importSession(new File(path),dest,()->false);runOnUiThread(()->message("已加入 "+count+" 張。按『繼續上傳』開始。"));
        })).setNegativeButton("取消",null).show();
    }
    private void disconnect(){if(UploadService.running||CaptureService.running){message("請先停拍及暫停上傳，再登出。");return;}if(prefs().getString("email","").isEmpty())return;
        new AlertDialog.Builder(this).setTitle("登出 Cam Link？").setMessage("停止自動上傳，保留本機 JPG、歷史佇列及雲端檔案。Google 專案授權不變。").setPositiveButton("登出",(d,w)->{
            CloudAuth.forget();prefs().edit().putBoolean("enabled",false).putBoolean("paused",true).remove("account").remove("email").remove("folder").remove("folder_name").apply();refresh();
        }).setNegativeButton("取消",null).show();}
    private void setup(){String sha="無法讀取";try{PackageInfo info=getPackageManager().getPackageInfo(getPackageName(),PackageManager.GET_SIGNING_CERTIFICATES);byte[] bytes=MessageDigest.getInstance("SHA-1").digest(info.signingInfo.getApkContentsSigners()[0].toByteArray());StringBuilder s=new StringBuilder();for(byte b:bytes){if(s.length()>0)s.append(':');s.append(String.format(Locale.US,"%02X",b&255));}sha=s.toString();}catch(Exception ignored){}
        String registration="Android package: "+getPackageName()+"\nSHA-1: "+sha+"\nScope: "+CloudAuth.SCOPE;
        new AlertDialog.Builder(this).setTitle("用 manhochong 帳戶設定 Google Cloud").setMessage("1. 建立專案並啟用 Google Drive API\n2. 設定 OAuth 同意畫面，測試模式加入你的實際 Google email\n3. 建立 Android OAuth client，填入下列 package 和 SHA-1\n4. 回本 App 選擇帳戶登入\n\n"+registration+"\n\n不需要把密碼或 client secret 填入 App。").setPositiveButton("複製登記資料",(d,w)->{getSystemService(android.content.ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("Cam Link OAuth",registration));}).setNegativeButton("關閉",null).show();
    }
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);
        if(request==70){if(result==RESULT_OK&&data!=null){pendingEmail=data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME);if(pendingEmail!=null&&!pendingEmail.isEmpty())authorize();else authFailure(new IOException("Google 未回傳所選帳戶，請重新選擇"));}return;}
        if(request==71){busy=false;if(result==RESULT_OK&&data!=null)try{accept(Identity.getAuthorizationClient(this).getAuthorizationResultFromIntent(data));}catch(Exception e){authFailure(e);}else {prefs().edit().putString("cloud_error","Google 授權已取消或未完成").apply();message("Google 授權未完成，沒有開始上傳");}refresh();return;}
        if(request==73&&result==RESULT_OK&&data!=null&&data.getData()!=null){Uri uri=data.getData();work(()->{try(OutputStream out=getContentResolver().openOutputStream(uri)){CloudStore.get(this).export(out);}runOnUiThread(()->message("上傳結果已匯出，不包含照片或授權憑證。"));});}
    }
    @Override protected void onSaveInstanceState(Bundle b){super.onSaveInstanceState(b);b.putString("email",pendingEmail);b.putBoolean("editing",editing);b.putBoolean("history",showHistory);b.putBoolean("support",showSupport);}
    @Override protected void onResume(){super.onResume();handler.post(tick);}
    @Override protected void onPause(){handler.removeCallbacks(tick);super.onPause();}
    @Override protected void onDestroy(){internet.close();worker.shutdown();super.onDestroy();}
}
