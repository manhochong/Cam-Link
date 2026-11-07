package hk.camlink.usb;

import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.*;
import android.widget.*;
import java.io.File;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;

/** Same kind of account, folder and auto-upload settings as Google Drive, using Microsoft directly. */
public final class OneDriveActivity extends ConsoleActivity {
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private TextView account,folder,state,list; private Switch enabled,wifi; private Button login,choose,create,byEvent,manage,resume,pause,history,importButton;
    private LinearLayout settings,historyPanel; private QueueStrip queue; private boolean busy,refreshing,editing,showHistory;
    private final Runnable tick=new Runnable(){ public void run(){ refresh(); handler.postDelayed(this,1000); } };
    private SharedPreferences prefs(){ return OneDriveAuth.prefs(this); }
    @Override public void onCreate(Bundle b){
        super.onCreate(b); if(b!=null){ editing=b.getBoolean("editing"); showHistory=b.getBoolean("history"); }
        LinearLayout root=page(); masthead(root,"OneDrive","TRANSFER");
        button(root,"‹   返回目的地",false,this::finish).setBackgroundColor(BG);
        LinearLayout progress=card(root); section(progress,"01","上傳進度");
        queue=new QueueStrip(progress); state=label(progress,"",15,MUTED);
        resume=button(progress,"繼續上傳",true,()->{ prefs().edit().putBoolean("paused",false).apply(); OneDriveStore.get(this).retry(prefs().getString("account","")); OneDriveService.start(this); refresh(); });
        pause=button(progress,"暫停上傳",false,()->{ OneDriveService.pause(this); refresh(); });
        history=button(progress,"查看最近照片",false,()->{ showHistory=!showHistory; refresh(); });
        historyPanel=new LinearLayout(this); historyPanel.setOrientation(LinearLayout.VERTICAL); progress.addView(historyPanel);
        list=label(historyPanel,"",14,TEXT); list.setTextIsSelectable(true);
        LinearLayout destination=card(root); section(destination,"02","上傳目的地");
        account=label(destination,"",16,TEXT); folder=label(destination,"",16,TEXT);
        login=button(destination,"登入 Microsoft",true,this::login);
        choose=button(destination,"選擇已有資料夾",false,this::chooseFolder);
        create=button(destination,"建立上傳資料夾",true,this::createFolder);
        byEvent=button(destination,"改為按活動名稱建資料夾",false,()->{ prefs().edit().remove("folder").remove("folder_name").apply(); editing=false; refresh(); });
        manage=button(destination,"更改資料夾",false,()->{ editing=!editing; refresh(); });
        settings=card(root); section(settings,"03","上傳設定");
        enabled=new Switch(this); enabled.setText("自動上傳新拍 JPG"); enabled.setTextColor(TEXT); enabled.setPadding(0,dp(12),0,dp(12)); settings.addView(enabled);
        enabled.setOnCheckedChangeListener((v,on)->{ if(refreshing) return; prefs().edit().putBoolean("enabled",on).putBoolean("paused",on?false:prefs().getBoolean("paused",false)).apply(); if(on) OneDriveService.start(this); refresh(); });
        wifi=new Switch(this); wifi.setText("只用 Wi-Fi（關閉可用 4G／5G）"); wifi.setTextColor(TEXT); wifi.setPadding(0,dp(10),0,dp(10)); settings.addView(wifi);
        wifi.setOnCheckedChangeListener((v,on)->{ if(!refreshing) prefs().edit().putBoolean("wifi",on).apply(); });
        label(settings,"跟 Google Drive 一樣：可指定一個資料夾，或不指定、按活動名稱建立場次資料夾。不需要 OneDrive App。",13,MUTED);
        label(settings,"自動上傳設定適用於下一輪拍攝。",13,MUTED);
        importButton=button(root,"將最近一輪 JPG 加入上傳",false,this::importLatest);
        button(root,"登出 OneDrive",false,this::disconnect);
        refresh();
    }
    private void text(TextView v,String s){ if(!v.getText().toString().equals(s)) v.setText(s); }
    private static void visible(android.view.View view,boolean show){ view.setVisibility(show?android.view.View.VISIBLE:android.view.View.GONE); }
    private boolean signed(){ return OneDriveAuth.signedIn(prefs()); }
    private void refresh(){
        if(account==null) return; boolean on=signed(); boolean hasFolder=!prefs().getString("folder","").isEmpty(); boolean paused=prefs().getBoolean("paused",false);
        text(account,on?prefs().getString("email",""):"先登入要儲存照片的 Microsoft 帳戶");
        text(folder,hasFolder?"固定資料夾　"+prefs().getString("folder_name",""):"按活動名稱在 OneDrive 建立場次資料夾");
        visible(folder,on); visible(manage,on); text(manage,editing?"收起資料夾設定":"更改資料夾");
        visible(choose,on&&(!hasFolder||editing)); visible(create,on&&(!hasFolder||editing)); visible(byEvent,hasFolder&&editing);
        text(login,on?"重新登入或更改帳戶":"登入 Microsoft"); login.setEnabled(!busy&&!CaptureService.running);
        visible(settings,on); visible(enabled,on); visible(wifi,on);
        refreshing=true; enabled.setChecked(prefs().getBoolean("enabled",false)); wifi.setChecked(prefs().getBoolean("wifi",false)); refreshing=false;
        enabled.setEnabled(!CaptureService.running&&!busy);
        String id=prefs().getString("account",""); boolean unfinished=on&&OneDriveStore.get(this).unfinished(id);
        visible(queue,on); if(on) queue.display(OneDriveStore.get(this).counts(id));
        visible(resume,on&&(paused||(!OneDriveService.running&&unfinished))); visible(pause,on&&OneDriveService.running&&!paused);
        visible(history,on); text(history,showHistory?"收起最近照片":"查看最近照片"); visible(historyPanel,showHistory&&on);
        if(showHistory&&on){ String recent=OneDriveStore.get(this).recent(id); text(list,recent.isEmpty()?"還沒有上傳紀錄":recent); }
        String note=prefs().getString("status",""); String progress=busy?"處理中…":OneDriveService.running?OneDriveService.status:paused&&on?"上傳已暫停":on?(unfinished?"有照片需要處理":"目前沒有待傳照片"):"登入並設定資料夾後，可在這裡查看上傳進度。";
        text(state,note.isEmpty()?progress:progress+"\n"+note);
        importButton.setEnabled(on&&!CaptureService.running&&!busy);
    }
    private interface Task { void run() throws Exception; }
    private void work(Task action){ if(busy) return; busy=true; refresh(); worker.execute(()->{ try{ action.run(); prefs().edit().remove("status").apply(); }catch(Exception e){ String detail=OneDriveAuth.safe(e); prefs().edit().putString("status",detail).apply(); runOnUiThread(()->message(detail)); }finally{ runOnUiThread(()->{ busy=false; refresh(); }); } }); }
    private void message(String s){ if(!isFinishing()&&!isDestroyed()) new AlertDialog.Builder(this).setTitle("Cam Link · OneDrive").setMessage(s).setPositiveButton("知道了",null).show(); }
    private void login(){ startActivity(new Intent(this,OneDriveLogin.class)); }
    private OneDriveApi api(){ return new OneDriveApi(()->OneDriveAuth.token(this)); }
    private void chooseFolder(){ work(()->{ JSONArray folders=api().folders(); String[] names=new String[folders.length()]; for(int i=0;i<names.length;i++) names[i]=folders.getJSONObject(i).getString("name"); runOnUiThread(()->{ if(names.length==0){ message("尚沒有資料夾，請按「建立上傳資料夾」。"); return; } new AlertDialog.Builder(this).setTitle("選擇 OneDrive 資料夾").setItems(names,(d,w)->{ try{ JSONObject f=folders.getJSONObject(w); prefs().edit().putString("folder",f.getString("id")).putString("folder_name",f.getString("name")).commit(); editing=false; refresh(); }catch(Exception e){ message(OneDriveAuth.safe(e)); } }).setNegativeButton("取消",null).show(); }); }); }
    private void createFolder(){ EditText input=new EditText(this); input.setSingleLine(true); input.setText("Cam Link "+new java.text.SimpleDateFormat("yyyy-MM-dd",java.util.Locale.US).format(new java.util.Date())); new AlertDialog.Builder(this).setTitle("在 OneDrive 建立資料夾").setView(input).setPositiveButton("建立",(d,w)->{ String name=input.getText().toString().trim(); if(name.isEmpty()||name.length()>120){ message("請輸入 1–120 字的名稱"); return; } work(()->{ JSONObject created=api().createFolder(name); prefs().edit().putString("folder",created.getString("id")).putString("folder_name",created.getString("name")).commit(); editing=false; }); }).setNegativeButton("取消",null).show(); }
    private void importLatest(){ if(!signed()){ message("請先登入"); return; } String path=getSharedPreferences("state",MODE_PRIVATE).getString("last_session",""); if(path.isEmpty()){ message("沒有最近接收紀錄"); return; }
        new AlertDialog.Builder(this).setTitle("加入最近一輪原圖？").setMessage("把最近一輪完整 JPG 排進 OneDrive。不加入 RAW。").setPositiveButton("加入",(d,w)->work(()->{
            JSONObject dest=OneDriveAuth.destination(this); if(dest==null) throw new java.io.IOException("請先開啟自動上傳");
            File dir=new File(path); if(dest.getString("folder").isEmpty()){ String name=SessionNames.get(this,dir); if(name.isEmpty()) name=dir.getName(); dest.put("eventName",name); }
            int count=OneDriveStore.get(this).importSession(this,dir,dest); if(count>0&&!prefs().getBoolean("paused",false)) OneDriveService.start(this); int added=count; runOnUiThread(()->message(added==0?"這一輪已經在上傳清單裡":"已加入 "+added+" 張，開始上傳。"));
        })).setNegativeButton("取消",null).show();
    }
    private void disconnect(){ if(OneDriveService.running||CaptureService.running){ message("請先停拍及暫停上傳，再登出。"); return; }
        new AlertDialog.Builder(this).setTitle("登出 OneDrive？").setMessage("停止自動上傳，保留本機 JPG 和雲端檔案。").setPositiveButton("登出",(d,w)->{ OneDriveAuth.forget(this); refresh(); }).setNegativeButton("取消",null).show();
    }
    @Override protected void onSaveInstanceState(Bundle b){ super.onSaveInstanceState(b); b.putBoolean("editing",editing); b.putBoolean("history",showHistory); }
    @Override protected void onResume(){ super.onResume(); handler.post(tick); String id=prefs().getString("account",""); if(signed()&&prefs().getBoolean("enabled",false)&&!prefs().getBoolean("paused",false)&&!OneDriveService.running&&OneDriveStore.get(this).pending(id)) OneDriveService.start(this); }
    @Override protected void onPause(){ handler.removeCallbacks(tick); super.onPause(); }
    @Override protected void onDestroy(){ worker.shutdown(); super.onDestroy(); }
}
