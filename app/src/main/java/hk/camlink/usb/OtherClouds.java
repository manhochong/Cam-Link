package hk.camlink.usb;

import android.app.AlertDialog;
import android.content.*;
import android.net.Uri;
import android.os.Bundle;
import android.text.InputType;
import android.widget.*;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;
import java.io.File;
import java.util.ArrayList;

public final class OtherClouds extends LightScreen {
    private static final String[] NAMES={"Dropbox","Box","Google Photos","Flickr"};
    private static final String[] PACKAGES={"com.dropbox.android","com.box.android","com.google.android.apps.photos","com.yahoo.mobile.client.android.flickr"};
    private int selected;
    private boolean discovering,pairQueued,pairAuto;
    private String pairRaw="";
    @Override public void onCreate(Bundle state){
        super.onCreate(state);if(state!=null)selected=state.getInt("provider");
        light();
        if(state==null)queuePair(getIntent());
    }
    @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);queuePair(intent);}
    private void queuePair(Intent intent){
        if(intent==null)return;
        String raw=intent.getStringExtra("pair_uri");
        if(raw==null||raw.isEmpty())return;
        pairRaw=raw;pairAuto=intent.getBooleanExtra("pair_auto",false);pairQueued=true;
        intent.removeExtra("pair_uri");intent.removeExtra("pair_auto");
    }
    private final int[] colors={0xff2463da,0xff237bb3,0xffac4130,0xffba2675};
    private final String[] marks={"db","box","相簿","fl"};
    private void directory(){
        body.removeAllViews();
        LinearLayout head=row(body);fill(head,copy("傳送目的地",26,INK,true));pill(head,"＋",this::chooseProvider);
        space(body,16);label(body,"可用目的地",13,GRAY,true);
        SharedPreferences prefs=CloudStore.prefs(this);
        boolean linked=!prefs.getString("account","").isEmpty();
        String routing=prefs.getString("folder","").isEmpty()?"按活動名稱建資料夾":prefs.getString("folder_name","");
        serviceRow("GD",0xff287453,"Google Drive",linked?routing:"設定帳戶及資料夾",linked,()->startActivity(new Intent(this,CloudActivity.class)));
        SharedPreferences one=OneDriveAuth.prefs(this); boolean oneSigned=OneDriveAuth.signedIn(one);
        String oneDetail=oneSigned?(one.getString("folder","").isEmpty()?"按活動名稱建資料夾":one.getString("folder_name","")):"登入 Microsoft 帳戶，不需要 OneDrive App";
        serviceRow("OD",0xff1673bc,"OneDrive",oneDetail,oneSigned&&one.getBoolean("enabled",false),()->startActivity(new Intent(this,OneDriveActivity.class)));
        SharedPreferences pc=DavBackup.pc(this);SharedPreferences pcB=DavBackup.pc2(this);
        boolean paired=DavBackup.pcPaired(this);
        String pcDetail=!pc.getString("active","").isEmpty()&&!pcB.getString("active","").isEmpty()?"兩部電腦已配對 · 新 JPG 會傳到兩邊":
                paired?(pc.getString("status",pcB.getString("status","已配對 · 同一 Wi-Fi 接收"))):"同一 Wi-Fi 直傳 · 可配對兩部電腦";
        serviceRow("PC",INK,"電腦 · Windows / Mac",pcDetail,paired,this::computer);
        boolean hasDav=!DavBackup.active(this).isEmpty();
        if(hasDav)serviceRow("W",0xff52545b,"WebDAV",DavBackup.prefs(this).getString("status","已啟用 · 下一場自動傳送"),true,this::dav);
        for(int i=0;i<NAMES.length;i++)if(getPackageManager().getLaunchIntentForPackage(PACKAGES[i])!=null){
            final int k=i;serviceRow(marks[i],colors[i],NAMES[i],"手機已安裝 · 由服務 App 上傳",false,()->provider(k));
        }
        space(body,18);label(body,"加入其他服務",13,GRAY,true);
        LinearLayout grid=null;int column=0;
        for(int i=0;i<=NAMES.length;i++){
            final int index=i;boolean web=i==NAMES.length;
            if(web?hasDav:getPackageManager().getLaunchIntentForPackage(PACKAGES[i])!=null)continue;
            if(column%3==0){grid=row(body);space(body,5);}
            LinearLayout tile=new LinearLayout(this);tile.setOrientation(LinearLayout.VERTICAL);tile.setGravity(android.view.Gravity.CENTER);tile.setBackground(rounded(SOFT,12));
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,dp(78),1);lp.setMargins(0,0,dp(4),0);grid.addView(tile,lp);
            tile.addView(badge(web?"WebDAV":NAMES[i],web?"W":marks[i],web?INK:colors[i],34));
            TextView tileTitle=copy(web?"WebDAV":NAMES[i],13,INK,true);tileTitle.setGravity(android.view.Gravity.CENTER);tile.addView(tileTitle);
            tile.setOnClickListener(v->{if(web)dav();else provider(index);});column++;
        }
        if(grid!=null)while(column++%3!=0)fill(grid,new android.view.View(this));
        space(body,16);serviceRow("▣",GRAY,"手機上的原圖","DCIM / CAM LINK",false,()->notice("在「我的檔案 → 內部儲存空間 → DCIM → CAM LINK」查看完整 JPG。"));
        dock.removeAllViews();dock.setPadding(dp(16),dp(6),dp(16),dp(6));
        Button back=pill(dock,"返回",this::finish);back.setLayoutParams(new LinearLayout.LayoutParams(-1,-2));
    }
    private void serviceRow(String mark,int color,String title,String detail,boolean enabled,Runnable action){
        LinearLayout r=row(body);r.setPadding(0,dp(7),0,dp(7));
        r.addView(badge(title,mark,color,41));LinearLayout words=new LinearLayout(this);words.setPadding(dp(12),0,0,0);words.setOrientation(LinearLayout.VERTICAL);fill(r,words);
        words.addView(copy(title,16,INK,true));words.addView(copy(detail,13,GRAY,false));r.addView(copy(enabled?"●":"›",enabled?13:19,enabled?0xff428452:GRAY,true));
        r.setOnClickListener(v->action.run());hair(body);
    }
    private void chooseProvider(){
        String[] choices={"Google Drive","OneDrive","Dropbox","Box","Google Photos","Flickr","WebDAV","電腦 · Windows / Mac"};
        new AlertDialog.Builder(this).setTitle("加入目的地").setItems(choices,(d,w)->{
            if(w==0)startActivity(new Intent(this,CloudActivity.class));
            else if(w==1)startActivity(new Intent(this,OneDriveActivity.class));
            else if(w==6)dav();else if(w==7)computer();else provider(w-2);
        }).show();
    }
    @Override protected void onResume(){
        super.onResume();directory();
        if(!pairQueued)return;
        pairQueued=false;
        String raw=pairRaw;boolean auto=pairAuto;
        body.post(()->{if(!isDestroyed()&&!isFinishing())computer(raw,auto);});
    }
    private void update(){directory();}
    private void notice(String msg){new AlertDialog.Builder(this).setMessage(msg).setPositiveButton("知道了",null).show();}
    private void provider(int i){
        selected=i;
        Intent launch=getPackageManager().getLaunchIntentForPackage(PACKAGES[i]);
        AlertDialog.Builder dialog=new AlertDialog.Builder(this).setTitle(NAMES[i]);
        if(launch==null){
            dialog.setMessage("在手機安裝並登入 "+NAMES[i]+" 後，即可選相傳送。")
                .setPositiveButton("前往 Google Play",(d,w)->startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse("https://play.google.com/store/apps/details?id="+PACKAGES[i]))));
        }else{
            String hint="請從 CAM LINK 相簿選照片，再在 "+NAMES[i]+" 內確認目的地。";
            if(i==2)hint+="\n自動備份可在 Google Photos 的設定 → 備份 → 備份裝置資料夾選 CAM LINK。原圖請選原始畫質。";
            dialog.setMessage(hint).setPositiveButton("選取 JPG",(d,w)->{
                Intent pick=new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("image/jpeg").putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);
                startActivityForResult(pick,42);
            }).setNeutralButton("開啟 "+NAMES[i],(d,w)->startActivity(launch));
        }
        dialog.setNegativeButton("取消",null).show();
    }
    @Override protected void onSaveInstanceState(Bundle state){super.onSaveInstanceState(state);state.putInt("provider",selected);}
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        if(request!=42||result!=RESULT_OK||data==null)return;
        ArrayList<Uri> files=new ArrayList<>();
        ClipData clip=data.getClipData();
        if(clip!=null){for(int i=0;i<clip.getItemCount();i++)files.add(clip.getItemAt(i).getUri());}
        else if(data.getData()!=null)files.add(data.getData());
        if(files.isEmpty())return;
        Intent send=new Intent(files.size()==1?Intent.ACTION_SEND:Intent.ACTION_SEND_MULTIPLE)
            .setType("image/jpeg").setPackage(PACKAGES[selected]).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        if(files.size()==1)send.putExtra(Intent.EXTRA_STREAM,files.get(0));
        else send.putParcelableArrayListExtra(Intent.EXTRA_STREAM,files);
        ClipData grants=ClipData.newUri(getContentResolver(),"JPG",files.get(0));
        for(int i=1;i<files.size();i++)grants.addItem(new ClipData.Item(files.get(i)));
        send.setClipData(grants);
        try{startActivity(send);}catch(ActivityNotFoundException e){notice("這個版本的 "+NAMES[selected]+" 未提供此分享方式。請開啟該 App，從 CAM LINK 相簿選相上傳。");}
    }
    private EditText field(LinearLayout form,String hint,int type){
        EditText input=new EditText(this);input.setSingleLine(true);input.setInputType(type);input.setHint(hint);
        input.setSaveEnabled(false);form.addView(input);return input;
    }
    private void dav(){
        LinearLayout form=new LinearLayout(this);form.setOrientation(LinearLayout.VERTICAL);form.setPadding(dp(20),0,dp(20),0);
        label(form,"輸入現有 HTTPS 資料夾。下一場起自動傳送完整 JPG，可使用流動數據。檔名含場次，並會回讀核對。",14,MUTED);
        EditText url=field(form,"HTTPS 資料夾網址",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);
        url.setText(DavBackup.prefs(this).getString("url",""));
        EditText user=field(form,"帳戶",InputType.TYPE_CLASS_TEXT);
        EditText pass=field(form,"應用程式密碼",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("WebDAV").setView(form)
            .setPositiveButton("儲存並啟用",null).setNegativeButton("取消",null)
            .setNeutralButton("停用",(d,w)->{DavBackup.disable(this);update();}).create();
        dialog.show();dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{
            try{DavBackup.configure(this,url.getText().toString(),user.getText().toString(),pass.getText().toString());update();dialog.dismiss();}
            catch(Exception e){url.setError("設定未儲存。請檢查 HTTPS 網址、帳戶及密碼。");}
        });
    }
    private void computer(){computer(null,false);}
    private void computer(String incoming,boolean auto){
        LinearLayout form=new LinearLayout(this);form.setOrientation(LinearLayout.VERTICAL);form.setPadding(dp(20),0,dp(20),0);
        label(form,"在電腦按「開始接收」。可配對兩部電腦；新拍／卡內 JPG 會傳到所有已配對電腦。兩部裝置須同一 Wi-Fi。",14,MUTED);
        boolean has1=!DavBackup.pc(this).getString("active","").isEmpty(),has2=!DavBackup.pc2(this).getString("active","").isEmpty();
        label(form,"目前："+(has1&&has2?"兩部已配對":has1||has2?"一部已配對":"尚未配對"),13,GRAY);
        if(DavBackup.pcPaired(this)){
            Button send=new Button(this);send.setAllCaps(false);send.setText("只補傳最近一輪到電腦");
            send.setOnClickListener(v->importLatestPc());form.addView(send);
        }
        if(incoming!=null){
            SharedPreferences slot=DavBackup.pc(this).getString("active","").isEmpty()?DavBackup.pc(this):DavBackup.pc2(this);
            pairSlot(slot,incoming,auto);return;
        }
        Button first=new Button(this);first.setAllCaps(false);first.setText("配對／更新第一部電腦");
        first.setOnClickListener(v->pairSlot(DavBackup.pc(this),null,false));form.addView(first);
        Button second=new Button(this);second.setAllCaps(false);second.setText("配對／更新第二部電腦");
        second.setOnClickListener(v->pairSlot(DavBackup.pc2(this),null,false));form.addView(second);
        new AlertDialog.Builder(this).setTitle("電腦 · Windows / Mac").setView(form)
            .setNeutralButton("全部停用",(d,w)->{DavBackup.disable(this,DavBackup.pc(this));DavBackup.disable(this,DavBackup.pc2(this));update();})
            .setNegativeButton("關閉",null).show();
    }
    private void importLatestPc(){
        String path=getSharedPreferences("state",MODE_PRIVATE).getString("last_session","");
        if(path.isEmpty()){notice("沒有最近接收紀錄");return;}
        new AlertDialog.Builder(this).setTitle("只補傳到電腦？")
            .setMessage("把 "+new File(path).getName()+" 的 JPG 排到已配對的電腦。不會動 Google Drive／OneDrive。電腦須已按「開始接收」。")
            .setPositiveButton("補傳",(d,w)->new Thread(()->{
                try{
                    int count=DavBackup.importPcSession(this,new File(path));
                    runOnUiThread(()->notice(count==0?"沒有可補傳的 JPG，或都已排過。":"已排 "+count+" 張到電腦。"));
                }catch(Exception e){runOnUiThread(()->notice(e.getMessage()==null?"補傳失敗":e.getMessage()));}
            },"pc-import").start()).setNegativeButton("取消",null).show();
    }
    private void pairSlot(SharedPreferences slot,String incoming,boolean auto){
        LinearLayout form=new LinearLayout(this);form.setOrientation(LinearLayout.VERTICAL);form.setPadding(dp(20),0,dp(20),0);
        label(form,"掃描電腦 QR，或手打 IPv4 與配對碼。",14,MUTED);
        Button scan=new Button(this);scan.setAllCaps(false);scan.setText("掃描電腦上的 QR");
        EditText address=field(form,"電腦 IPv4 地址",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);
        String remembered=slot.getString("draft_address","");
        if(remembered.isEmpty()){String old=slot.getString("url","");if(!old.isEmpty())remembered=Uri.parse(old).getHost();}
        if(remembered!=null)address.setText(remembered);
        EditText pass=field(form,"電腦顯示的配對碼",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        String code=slot.getString("draft_code","");if(code.isEmpty())code=DavBackup.savedPassword(slot);pass.setText(code);
        boolean filled=incoming!=null&&fillPair(incoming,address,pass);
        scan.setOnClickListener(v->GmsBarcodeScanning.getClient(this,new GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).enableAutoZoom().build()).startScan()
            .addOnSuccessListener(barcode->{if(isDestroyed()||isFinishing())return;if(!fillPair(barcode.getRawValue(),address,pass))notice("這不是 Cam Link 的配對 QR。");})
            .addOnCanceledListener(()->{})
            .addOnFailureListener(e->{if(!isDestroyed()&&!isFinishing())notice("這部手機未能開啟掃描。仍可手打地址和配對碼。");}));
        form.addView(scan,1);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle(slot==DavBackup.pc(this)?"第一部電腦":"第二部電腦").setView(form)
            .setPositiveButton("連接",(d,w)->{
                fillPair(address.getText().toString(),address,pass);
                connectComputer(slot,address.getText().toString(),pass.getText().toString(),null);
            }).setNegativeButton("取消",null)
            .setNeutralButton("停用這部",(d,w)->{DavBackup.disable(this,slot);update();}).create();
        dialog.show();
        if(incoming!=null&&!filled)notice("這不是 Cam Link 的配對 QR。");
        else if(auto&&filled)connectComputer(slot,address.getText().toString(),pass.getText().toString(),dialog);
    }
    private void connectComputer(SharedPreferences slot,String input,String password,AlertDialog form){
        String host=input==null?"":input.trim(),secret=password==null?"":password.trim();
        slot.edit().putString("draft_address",host).putString("draft_code",secret).apply();
        if(discovering)return;
        discovering=true;
        new Thread(()->{
            try{
                String base=PcLink.base(host),seen=PcLink.probe(this,base);
                runOnUiThread(()->{
                    discovering=false;
                    if(isDestroyed()||isFinishing())return;
                    if(form!=null&&form.isShowing())form.dismiss();
                    new AlertDialog.Builder(this).setTitle("核對電腦指紋")
                        .setMessage("電腦畫面應顯示相同的指紋\n\n"+seen.substring(0,16).toUpperCase(java.util.Locale.ROOT))
                        .setPositiveButton("相同，完成配對",(q,n)->completePair(slot,base,secret,seen)).setNegativeButton("取消",null).show();
                });
            }catch(Exception e){runOnUiThread(()->{discovering=false;if(!isDestroyed()&&!isFinishing())notice("未能連接。請確認同一 Wi-Fi，接收器已開始接收，且電腦允許區域網絡連入。");});}
        },"pc-discovery").start();
    }
    private boolean fillPair(String raw,EditText address,EditText pass){
        String[] pair=parsePair(raw);
        if(pair==null)return false;
        address.setText(pair[0]);pass.setText(pair[1]);return true;
    }
    static String[] parsePair(String raw){
        String text=raw==null?"":raw.trim();
        if(text.regionMatches(true,0,"camlink://",0,10)){
            Uri uri=Uri.parse(text);
            String code=uri.getQueryParameter("code");
            String host=pairQuery(uri,"ip","address","host");
            if(host==null){
                String named=uri.getHost(),path=uri.getLastPathSegment();
                if(named!=null&&!"pair".equalsIgnoreCase(named)&&path!=null&&(code==null||code.isEmpty())){host=named;code=path;}
            }
            if(host==null||code==null)return null;
            host=host.trim();code=code.trim();
            if(!pairCode(code)||!pairHost(host))return null;
            return new String[]{host,code};
        }
        if(!text.regionMatches(true,0,"camlink:",0,8))return null;
        String rest=text.substring(8);
        int cut=rest.lastIndexOf(':');
        if(cut<=0||cut>=rest.length()-1)return null;
        String host=rest.substring(0,cut).trim(),code=rest.substring(cut+1).trim();
        if(!pairCode(code)||!pairHost(host))return null;
        return new String[]{host,code};
    }
    private static String pairQuery(Uri uri,String... names){
        for(String name:names){String value=uri.getQueryParameter(name);if(value!=null&&!value.trim().isEmpty())return value;}
        return null;
    }
    private static boolean pairCode(String code){return code.matches("[0-9a-fA-F]{12}");}
    private static boolean pairHost(String host){
        if(host.isEmpty()||host.indexOf(' ')>=0||host.indexOf('/')>=0||host.indexOf('?')>=0)return false;
        return !host.matches("\\d{1,5}");
    }
    private void completePair(SharedPreferences slot,String base,String password,String pin){
        new Thread(()->{
            try{
                PcLink.authenticate(this,base,password,pin);
                DavBackup.configure(this,slot,base,"camlink",password,pin);
                runOnUiThread(()->{if(!isDestroyed()&&!isFinishing()){update();notice(slot==DavBackup.pc2(this)?"第二部電腦已配對。":"已配對，下一場起自動傳送到電腦。");}});
            }catch(Exception e){runOnUiThread(()->{if(!isDestroyed()&&!isFinishing())notice("配對未完成，請核對地址、配對碼及指紋。");});}
        },"pc-pair").start();
    }
}
