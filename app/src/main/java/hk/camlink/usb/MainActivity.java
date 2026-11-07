package hk.camlink.usb;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.hardware.usb.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.util.*;
import java.util.zip.*;

public final class MainActivity extends LightScreen {
    private final Handler handler=new Handler(Looper.getMainLooper());
    private TextView state,metrics,camera,detail,storage;
    private TextView driveMode,folderLine;private View driveBadge;
    private ShootPanel shoot;
    FrameLayout leftPhoto;
    private LinearLayout advanced;
    private boolean cameraAttached;
    private final BroadcastReceiver cable=new BroadcastReceiver(){
        @Override public void onReceive(Context c,Intent i){detectCamera();}
    };
    private void detectCamera(){
        cameraAttached=false;
        for(UsbDevice d:manager.getDeviceList().values()){
            if(UsbWire.candidate(d)){cameraAttached=true;break;}
        }
        refresh();
    }
    private Button wifi,start,cardImport,stop,scan,force,export;
    private boolean importNext;
    private Spinner interval;
    private EditText notes;
    private UsbManager manager;
    private final ArrayList<UsbDevice> candidates=new ArrayList<>();
    private String pendingExport;
    private boolean registered;
    private final BroadcastReceiver permission=new BroadcastReceiver(){public void onReceive(Context c,Intent i){
        if((getPackageName()+".USB_PERMISSION").equals(i.getAction())){
            UsbDevice d=i.getParcelableExtra(UsbManager.EXTRA_DEVICE);
            if(d!=null&&i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED,false))begin(d);else message("未取得相機 USB 權限，請重新接線或重試。");
        }
    }};
    private final Runnable tick=new Runnable(){public void run(){refresh();handler.postDelayed(this,CaptureService.running?1400:700);}};
    @Override public void onCreate(Bundle b){super.onCreate(b);manager=getSystemService(UsbManager.class);
        if(Build.VERSION.SDK_INT>=33)registerReceiver(permission,new IntentFilter(getPackageName()+".USB_PERMISSION"),Context.RECEIVER_NOT_EXPORTED);else registerReceiver(permission,new IntentFilter(getPackageName()+".USB_PERMISSION"));registered=true;
        LinearLayout root=light();
        if(getResources().getConfiguration().orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE){
            sheet.setOrientation(LinearLayout.HORIZONTAL);
            sheet.setLayoutDirection(View.LAYOUT_DIRECTION_LTR);
            leftPhoto=new FrameLayout(this);leftPhoto.setPadding(dp(12),dp(10),0,dp(8));
            sheet.addView(leftPhoto,0,new LinearLayout.LayoutParams(0,-1,1.55f));
            scroll.setLayoutParams(new LinearLayout.LayoutParams(0,-1,1f));
            dock.setOrientation(LinearLayout.VERTICAL);
            dock.setLayoutParams(new LinearLayout.LayoutParams(dp(60),-1));
        }
        LinearLayout top=row(root);
        LinearLayout route=new LinearLayout(this);route.setOrientation(LinearLayout.VERTICAL);fill(top,route);
        routeHeading=label(route,"上傳目的地",12,GRAY,false);
        LinearLayout serviceLine=row(route);driveBadge=badge("Google Drive","GD",INK,26);serviceLine.addView(driveBadge);
        driveMode=label(serviceLine,"",21,INK,true);driveMode.setPadding(dp(5),0,0,0);folderLine=label(route,"",13,GRAY,false);
        pill(top,"更改",this::destinations);
        space(root,10);shoot=new ShootPanel(this,root);shoot.restore(b);
        space(root,18);
        LinearLayout bar=row(root);fill(bar,copy("相機",17,INK,true));
        wifi=pill(bar,"＋ 連接",()->selectCamera(false));
        hair(root);
        LinearLayout capture=new LinearLayout(this);capture.setOrientation(LinearLayout.VERTICAL);capture.setPadding(dp(4),dp(9),dp(4),dp(9));root.addView(capture);
        state=label(capture,"",18,INK,true);camera=label(capture,"",14,GRAY,false);
        detail=label(capture,"",14,0xff924300,false);
        start=button(capture,"開始接收",true,v->selectCamera(cardImportOpen()));
        cardImport=button(capture,"上傳卡內 JPG",false,this::importCard);
        stop=button(capture,"停拍並完成接收",true,v->{CaptureService service=CaptureService.active;if(service==null)return;if(service.importingCard())service.pauseCardImport();else service.gracefulStop();});
        LinearLayout pocket=row(root);pocket.setBackground(rounded(SOFT,14));pocket.setPadding(dp(14),dp(12),dp(14),dp(12));
        pocket.addView(copy("☾   ",24,INK,true));LinearLayout pocketText=new LinearLayout(this);pocketText.setOrientation(LinearLayout.VERTICAL);fill(pocket,pocketText);
        pocketText.addView(copy("口袋模式",15,INK,true));pocketText.addView(copy("調暗螢幕，接收持續運作",12,GRAY,false));pocket.addView(copy("›",22,GRAY,true));pocket.setOnClickListener(v->pocket());
        LinearLayout setup=advanced=card(root);
        advanced.setVisibility(b!=null&&b.getBoolean("advanced")?View.VISIBLE:View.GONE);
        navItem("首頁",R.drawable.nav_home,true,()->{advanced.setVisibility(View.GONE);scroll.smoothScrollTo(0,0);});
        navItem("紀錄",R.drawable.nav_history,false,()->startActivity(new Intent(this,ShootDetail.class).putExtra("history",true)));
        navItem("傳送",R.drawable.nav_cloud,false,this::destinations);
        navItem("更多",R.drawable.nav_more,false,()->{boolean show=advanced.getVisibility()!=View.VISIBLE;advanced.setVisibility(show?View.VISIBLE:View.GONE);if(show)scroll.post(()->scroll.smoothScrollTo(0,advanced.getTop()));});
        label(setup,"接收設定與診斷",18,TEXT,true);
        metrics=label(setup,"",14,MUTED,false);
        label(setup,"補掃頻率（事件會即時觸發接收）",13,MUTED,false);
        interval=new Spinner(this);ArrayAdapter<String> choices=new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"平衡 · 每 2 秒補掃","低干擾 · 每 5 秒補掃","快速實驗 · 每 0.5 秒補掃"});interval.setAdapter(choices);setup.addView(interval);
        notes=new EditText(this);notes.setHint("記錄：連拍模式、JPG 大小、卡槽、線材");notes.setTextColor(TEXT);notes.setHintTextColor(MUTED);notes.setTextSize(14);notes.setMinLines(2);notes.setMaxLines(4);setup.addView(notes);
        notes.setText(getPreferences(MODE_PRIVATE).getString("notes",""));
        scan=button(advanced,"重新搜尋照片及重試",false,v->{if(CaptureService.active!=null)CaptureService.active.rescan();});
        force=button(advanced,"強制中止接收",false,v->new AlertDialog.Builder(this).setTitle("強制中止接收？").setMessage("正在傳送的照片可能只收到部分內容。").setPositiveButton("強制中止",(d,w)->{if(CaptureService.active!=null)CaptureService.active.emergency("使用者立即停止；需要卡檔比對確認缺圖");}).setNegativeButton("繼續接收",null).show());
        export=button(advanced,"匯出最近一次診斷報告",false,v->export());
        storage=label(advanced,"",12,MUTED,false);storage.setTextIsSelectable(true);
        button(advanced,"查看 USB 裝置診斷",false,v->diagnose());
        label(advanced,"實拍紀錄：LUMIX S1、S1 II、S1R II。Sony、Canon、Nikon、Fujifilm 為實驗接收，只接收可從卡內讀取的新 JPG。",13,MUTED,false);
        label(advanced,"Cam Link "+BuildConfig.VERSION_NAME,12,MUTED,false);
        IntentFilter connections=new IntentFilter(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        connections.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED);
        if(Build.VERSION.SDK_INT>=33)registerReceiver(cable,connections,Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(cable,connections);
        if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},8);
    }
    private TextView routeHeading;
    private static void changeText(TextView view,String value){if(!view.getText().toString().equals(value))view.setText(value);}
    private boolean cardImportOpen(){return getSharedPreferences("state",MODE_PRIVATE).getBoolean("card_import_open",false);}
    private void refresh(){boolean run=CaptureService.running;
        CaptureService service=CaptureService.active;
        boolean finishing=run&&service!=null&&service.isFinishingCapture();
        if(finishing){
            changeText(state,"正在完成接收");changeText(camera,"請保持相機連線，等候剩餘照片存入手機。");
        }else if(run&&CaptureService.ready){
            boolean card=service!=null&&service.importingCard();
            changeText(state,card?(CaptureService.pending>0||CaptureService.validating>0?"正在接收卡內 JPG":"卡內 JPG 已收下"):"可以拍攝");
            boolean toComputer=DavBackup.pcPaired(this);
            SharedPreferences cloudNow=CloudStore.prefs(this);
            boolean toDrive=cloudNow.getBoolean("enabled",false)&&!cloudNow.getString("account","").isEmpty();
            String cardWhere=toComputer&&toDrive?"JPG 會存入手機，並傳到電腦和 Google Drive。RAW 不傳。":toComputer?"JPG 會存入手機並傳到已配對的電腦。RAW 不傳。":toDrive?"JPG 會存入手機並排進 Google Drive。RAW 不傳。":"JPG 會先存入手機。RAW 不傳。";
            changeText(camera,card?cardWhere:CaptureService.camera+"　·　拍完後按下方按鈕。");
        }else if(run){
            changeText(state,"正在連接相機");changeText(camera,CaptureService.status+"；請等候連線完成才拍攝。");
        }else{
            boolean resumeCard=cardImportOpen();
            changeText(state,resumeCard?"卡內 JPG 未傳完":!CaptureService.detail.isEmpty()?"接收需要檢查":cameraAttached?"已偵測到相機":"等待連接相機");
            changeText(camera,resumeCard?"按「繼續接收」。已傳完的會跳過，剩下的接著傳。":!CaptureService.detail.isEmpty()?CaptureService.detail:cameraAttached?"按「開始接收」，按提示允許 USB 存取。":"用 USB 接上相機，選 PC(Tether)。");
        }
        SharedPreferences cloud=CloudStore.prefs(this);
        changeText(routeHeading,run?"本場上傳目的地":"下次開拍的目的地");
        String folder=cloud.getString("folder_name","");
        boolean fixedDrive=!cloud.getString("folder","").isEmpty();
        String eventDrive=service==null?"":service.driveEventName;
        boolean drive=cloud.getBoolean("enabled",false)&&!cloud.getString("account","").isEmpty()&&(fixedDrive||!run||!eventDrive.isEmpty());
        driveBadge.setVisibility(drive?View.VISIBLE:View.GONE);
        boolean dav=!DavBackup.active(this).isEmpty();
        SharedPreferences one=OneDriveAuth.prefs(this);boolean oneDrive=one.getBoolean("enabled",false)&&OneDriveAuth.signedIn(one);
        java.util.List<String> routes=new ArrayList<>();if(drive)routes.add("Google Drive");if(oneDrive)routes.add("OneDrive");if(dav)routes.add("WebDAV");
        boolean pc=DavBackup.pcPaired(this);if(pc){routes.add(DavBackup.pc2(this).getString("active","").isEmpty()?"電腦":"電腦×2");}
        changeText(driveMode,routes.isEmpty()?"只存手機":String.join(" · ",routes));
        String location=drive?(fixedDrive?"／"+folder:eventDrive.isEmpty()?"按活動名稱建資料夾":"／"+eventDrive):dav?"WebDAV 自動傳送":pc?"同一 Wi-Fi 自動傳送":"DCIM / CAM LINK";
        changeText(folderLine,location+(drive&&cloud.getBoolean("paused",false)?" · 已暫停":""));
        wifi.setVisibility(run?View.GONE:View.VISIBLE);
        shoot.refresh();
        start.setVisibility(!run&&cameraAttached?View.VISIBLE:View.GONE);cardImport.setVisibility(!run&&cameraAttached?View.VISIBLE:View.GONE);stop.setVisibility(run?View.VISIBLE:View.GONE);
        changeText(start,cardImportOpen()?"繼續接收":"開始接收");
        changeText(stop,finishing?"正在停下…":service!=null&&service.importingCard()?"停止，下次再續":"停拍並完成接收");
        changeText(cardImport,cardImportOpen()?"繼續上傳卡內 JPG":"上傳卡內 JPG");
        double rate=CaptureService.usbMs==0?0:CaptureService.bytes/1e6/(CaptureService.usbMs/1000.0);
        double overall=CaptureService.elapsedMs==0?0:CaptureService.bytes/1e6/(CaptureService.elapsedMs/1000.0);
        changeText(metrics,String.format(Locale.TRADITIONAL_CHINESE,"%d 張已驗證    %d 待接收    %d 驗證中\n%d 失敗    %d 非 JPG\n接收 %.1f MB/s    全程 %.1f MB/s\n累計 %.1f MB · 基線 %d 個物件\n最近發現至驗證 %.2f 秒\n%s",CaptureService.good,CaptureService.pending,CaptureService.validating,CaptureService.bad,CaptureService.skipped,rate,overall,CaptureService.bytes/1e6,CaptureService.baseline,CaptureService.latestLatency/1000.0,CaptureService.lastFile));
        changeText(detail,CaptureService.detail);detail.setVisibility(CaptureService.detail.isEmpty()?View.GONE:View.VISIBLE);
        start.setEnabled(!run&&cameraAttached);cardImport.setEnabled(!run&&cameraAttached);scan.setEnabled(run&&CaptureService.ready);stop.setEnabled(run&&CaptureService.ready&&!finishing);force.setEnabled(run);interval.setEnabled(!run);notes.setEnabled(!run);export.setEnabled(!run);
        String path=getSharedPreferences("state",MODE_PRIVATE).getString("last_session","");changeText(storage,"完整 JPG 儲存在 DCIM/CAM LINK。"+(path.isEmpty()?"":"\n最近接收紀錄："+new File(path).getName()));
    }
    private void pocket(){
        Dialog dialog=new Dialog(this,android.R.style.Theme_Material_NoActionBar_Fullscreen);
        TextView exit=copy("口袋模式　·　輕觸返回",15,0xff888888,false);exit.setGravity(Gravity.CENTER);exit.setBackgroundColor(0xff000000);
        dialog.setContentView(exit);exit.setOnClickListener(v->dialog.dismiss());
        Window window=dialog.getWindow();window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        WindowManager.LayoutParams attrs=window.getAttributes();attrs.screenBrightness=.015f;window.setAttributes(attrs);dialog.show();
    }
    private void importCard(){
        SharedPreferences cloud=CloudStore.prefs(this);
        boolean drive=cloud.getBoolean("enabled",false)&&!cloud.getString("account","").isEmpty();
        boolean computer=DavBackup.pcPaired(this);
        String folder=cloud.getString("folder_name","");
        String where=computer?"JPG 會傳到已配對的電腦。這台電腦尚未收過的照片會補傳，已經核對過的會跳過。":
                !drive?"JPG 只會先存入手機。之後可在傳送頁把本場加入上傳。":
                folder.isEmpty()?"JPG 會排進這次填寫的活動資料夾。":"JPG 會排進 Drive／"+folder+"。";
        if(computer&&drive)where="JPG 會傳到已配對的電腦，也會排進"+(folder.isEmpty()?"這次填寫的活動資料夾":" Drive／"+folder)+"。";
        String lead=computer?"把記憶卡上已有的 JPG 收到手機，再傳到已配對的電腦。":drive?"把記憶卡上已有的 JPG 收到手機，再排進 Google Drive。":"把記憶卡上已有的 JPG 收到手機。";
        new AlertDialog.Builder(this).setTitle("上傳卡內 JPG")
                .setMessage(lead+"RAW 不傳。已經傳到這個目的地的會跳過，所以中途停止後，下次連接可接著傳。\n\n"+where+"\n\n傳送中可按「停止，下次再續」。這張傳完才停下。")
                .setPositiveButton("繼續",(d,w)->selectCamera(true)).setNegativeButton("取消",null).show();
    }
    private void selectCamera(boolean card){importNext=card;
        candidates.clear();for(UsbDevice d:manager.getDeviceList().values())if(UsbWire.candidate(d))candidates.add(d);
        if(candidates.isEmpty()){importNext=false;message("找不到可接收照片的相機。請用 USB 資料線接上相機，選可拍攝並存卡的 USB 模式；LUMIX 請選 PC(Tether)。");return;}
        if(candidates.size()==1){authorize(candidates.get(0));return;}
        String[] labels=new String[candidates.size()];for(int i=0;i<labels.length;i++)labels[i]=candidates.get(i).getProductName()+" ("+candidates.get(i).getDeviceId()+")";
        new AlertDialog.Builder(this).setTitle("選擇本次測試相機").setItems(labels,(d,w)->authorize(candidates.get(w))).show();
    }
    private void authorize(UsbDevice d){if(manager.hasPermission(d)){begin(d);return;}
        // Explicit package is necessary for Android 14 mutable PendingIntent restrictions.
        PendingIntent p=PendingIntent.getBroadcast(this,d.getDeviceId(),new Intent(getPackageName()+".USB_PERMISSION").setPackage(getPackageName()),PendingIntent.FLAG_MUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        manager.requestPermission(d,p);
    }
    private void begin(UsbDevice d){boolean card=importNext;importNext=false;if(CaptureService.running)return;getPreferences(MODE_PRIVATE).edit().putString("notes",notes.getText().toString()).apply();int[] polls={2000,5000,500};
        int poll=polls[interval.getSelectedItemPosition()];if(card)poll=Math.max(poll,2000);
        Intent i=new Intent(this,CaptureService.class).putExtra("device_id",d.getDeviceId()).putExtra("poll_ms",poll).putExtra("notes",notes.getText().toString()).putExtra("import_card",card);
        nameAndStart(i);
    }
    private void nameAndStart(Intent capture){
        if(CaptureService.running||getFragmentManager().findFragmentByTag("start_shoot")!=null)return;
        StartShoot prompt=new StartShoot();
        prompt.setArguments(capture.getExtras());
        prompt.show(getFragmentManager(),"start_shoot");
    }
    public static final class StartShoot extends DialogFragment {
        private EditText input;
        @Override public Dialog onCreateDialog(Bundle state){
            MainActivity host=(MainActivity)getActivity();
            input=new EditText(host);input.setHint("活動名稱（選填）");input.setSingleLine(true);
            input.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(SessionNames.LIMIT)});
            if(state!=null)input.setText(state.getString("draft",""));
            LinearLayout frame=new LinearLayout(host);frame.setOrientation(LinearLayout.VERTICAL);
            frame.setPadding(host.dp(20),host.dp(8),host.dp(20),0);frame.addView(input);
            SharedPreferences cloud=CloudStore.prefs(host);
            if(cloud.getBoolean("enabled",false)&&!cloud.getString("account","").isEmpty()){
                TextView destination=new TextView(host);frame.addView(destination);
                Runnable preview=()->{
                    String name=input.getText().toString().trim();
                    String route=!cloud.getString("folder","").isEmpty()?"Drive 固定資料夾："+cloud.getString("folder_name",""):
                            name.isEmpty()?"填寫活動名稱即可傳到 Drive；留空則略過 Drive。":"Drive：我的雲端硬碟／"+name;
                    destination.setText(route+(cloud.getBoolean("paused",false)?"（上傳已暫停）":""));
                };
                input.addTextChangedListener(new android.text.TextWatcher(){
                    public void beforeTextChanged(CharSequence s,int start,int count,int after){}
                    public void onTextChanged(CharSequence s,int start,int before,int count){preview.run();}
                    public void afterTextChanged(android.text.Editable s){}
                });
                preview.run();
            }
            boolean card=getArguments()!=null&&getArguments().getBoolean("import_card");
            boolean resume=card&&host.getSharedPreferences("state",MODE_PRIVATE).getBoolean("card_import_open",false);
            return new AlertDialog.Builder(host).setTitle(card?(resume?"繼續上傳卡內 JPG":"上傳卡內 JPG"):"開始拍攝").setView(frame)
                    .setNegativeButton("取消",null).setPositiveButton(card?(resume?"接著傳":"開始上傳"):"開始接收",(dialog,which)->{
                        Intent capture=new Intent(host,CaptureService.class).putExtras(getArguments());
                        capture.putExtra(SessionNames.EXTRA,input.getText().toString().trim());
                        host.startCapture(capture);
                    }).create();
        }
        @Override public void onSaveInstanceState(Bundle state){
            super.onSaveInstanceState(state);if(input!=null)state.putString("draft",input.getText().toString());
        }
    }
    private void startCapture(Intent capture){
        if(CaptureService.running)return;
        try{
            startForegroundService(capture);
            SharedPreferences cloud=CloudStore.prefs(this);
            if(cloud.getBoolean("enabled",false)&&!cloud.getBoolean("paused",false))UploadService.start(this);
            SharedPreferences one=OneDriveAuth.prefs(this);
            if(one.getBoolean("enabled",false)&&OneDriveAuth.signedIn(one)&&!one.getBoolean("paused",false))OneDriveService.start(this);
        }catch(Exception e){message("無法開始接收："+e.getMessage());}
    }
    private void diagnose(){StringBuilder s=new StringBuilder("手機 "+Build.MODEL+" / Android "+Build.VERSION.RELEASE+"\nUSB Host："+getPackageManager().hasSystemFeature(PackageManager.FEATURE_USB_HOST)+"\nUSB 核心自測："+NativeUsb.selfTest()+"\n\n");for(UsbDevice d:manager.getDeviceList().values())s.append(UsbWire.describe(d)).append('\n');if(manager.getDeviceList().isEmpty())s.append("目前沒有 USB 外接裝置。");message(s.toString());}
    private void export(){String path=getSharedPreferences("state",MODE_PRIVATE).getString("last_session","");if(path.isEmpty()){message("尚未有相機測試報告。請先連接相機並完成一輪測試。");return;}pendingExport=path;
        Intent i=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/zip").putExtra(Intent.EXTRA_TITLE,"CamLink-"+new File(path).getName()+".zip");startActivityForResult(i,42);
    }
    @Override protected void onSaveInstanceState(Bundle out){super.onSaveInstanceState(out);shoot.save(out);out.putString("pending_export",pendingExport);out.putBoolean("advanced",advanced.getVisibility()==View.VISIBLE);}
    @Override protected void onRestoreInstanceState(Bundle in){super.onRestoreInstanceState(in);pendingExport=in.getString("pending_export");}
    @Override protected void onActivityResult(int req,int result,Intent data){super.onActivityResult(req,result,data);
        if(req!=42||result!=RESULT_OK||data==null||pendingExport==null)return;Uri uri=data.getData();String path=pendingExport;
        new Thread(()->{try{try(OutputStream stream=getContentResolver().openOutputStream(uri);ZipOutputStream zip=new ZipOutputStream(stream)){
            File dir=new File(path);for(String name:new String[]{"device.json","summary.json","files.csv","events.log"}){File f=new File(dir,name);if(!f.isFile())continue;zip.putNextEntry(new ZipEntry(name));try(InputStream in=new FileInputStream(f)){byte[] b=new byte[65536];int n;while((n=in.read(b))>=0)zip.write(b,0,n);}zip.closeEntry();}
            }runOnUiThread(()->message("診斷報告已匯出。請配合記憶卡 JPG 執行電腦端 compare_card.py，確認有否漏圖。"));
        }catch(Exception e){runOnUiThread(()->message("匯出失敗："+e.getMessage()));}},"report-export").start();
    }
    private void message(String s){new AlertDialog.Builder(this).setTitle("相機接收").setMessage(s).setPositiveButton("知道了",null).show();}
    @Override protected void onResume(){super.onResume();
        detectCamera();handler.post(tick);}
    @Override protected void onPause(){handler.removeCallbacks(tick);super.onPause();}
    @Override protected void onDestroy(){shoot.close();if(registered){unregisterReceiver(permission);unregisterReceiver(cable);}super.onDestroy();}
}
