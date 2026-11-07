package hk.camlink.usb;

import android.graphics.Bitmap;
import android.graphics.ImageDecoder;
import android.net.Uri;
import android.view.View;
import android.widget.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.*;
import java.util.regex.*;
import org.json.JSONObject;

/** Reads verified originals and the Drive queue on a single background worker. */
final class ShootPanel {
    private final MainActivity host;
    private final ExecutorService reader=Executors.newSingleThreadExecutor();
    private final TextView scope,caption,received,pending,verified,verifiedCaption,issues;
    private final ReviewPhoto photo;
    private final TextView latest;
    private ReviewPhoto large;
    private TextView largeCaption,largeLatest;
    private android.app.Dialog viewer;
    private int selected=-1,index=-1,total,generation;
    private boolean high,restoreViewer;
    private String frame="";
    private Bitmap displayed;
    private final ProgressBar bar; private final TextView footer;
    private final LinearLayout delivery;
    private final TextView eventTitle,driveTarget;
    private final Button openFolder;
    private String openId="";
    private String targetName="";
    private boolean busy,closed;
    private String shownSession=null;
    // Only accessed by the reader.
    private String savedSession=null,lastLocal="",targetSession=null,targetAccount="",targetFolder="",bitmapKey=null;
    private final java.util.ArrayList<String> savedPhotos=new java.util.ArrayList<>();
    private Bitmap bitmap;
    private static final Pattern OK=Pattern.compile("^\"OK\",\"[0-9]+\",\"[0-9]+\",\"(?:[^\"]|\"\")*\",\"([^\"]+)\",");

    ShootPanel(MainActivity host,LinearLayout parent){
        this.host=host;
        LinearLayout box=new LinearLayout(host);box.setOrientation(LinearLayout.VERTICAL);
        box.setBackground(host.rounded(0xff151516,20));box.setClipToOutline(true);parent.addView(box);
        FrameLayout cover=new FrameLayout(host);cover.setBackground(host.rounded(0xff272726,16));
        if(host.leftPhoto==null)box.addView(cover,new LinearLayout.LayoutParams(-1,host.dp(205)));
        else{cover.setClipToOutline(true);host.leftPhoto.addView(cover,new FrameLayout.LayoutParams(-1,-1));}
        photo=new ReviewPhoto(host,host.leftPhoto==null,this::page,this::inspect,this::open);cover.addView(photo,new FrameLayout.LayoutParams(-1,-1));
        latest=latestChip(cover);
        scope=chip(cover,"本場拍攝",android.view.Gravity.TOP|android.view.Gravity.START);
        caption=chip(cover,"等待完整 JPG",android.view.Gravity.BOTTOM|android.view.Gravity.END);
        LinearLayout stats=new LinearLayout(host);stats.setOrientation(LinearLayout.VERTICAL);stats.setPadding(host.dp(15),host.dp(7),host.dp(15),host.dp(12));box.addView(stats);
        delivery=new LinearLayout(host);delivery.setOrientation(LinearLayout.VERTICAL);stats.addView(delivery);
        eventTitle=host.label(delivery,"",18,ConsoleActivity.TEXT,true);
        driveTarget=host.label(delivery,"",14,ConsoleActivity.MUTED);
        openFolder=host.pill(host.row(delivery),"開啟資料夾",()->{
            if(openId.isEmpty()||!session().equals(shownSession))return;
            try{host.startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW,
                    Uri.parse("https://drive.google.com/drive/folders/"+Uri.encode(openId))));}
            catch(android.content.ActivityNotFoundException e){Toast.makeText(host,"找不到可開啟 Drive 的應用程式",Toast.LENGTH_SHORT).show();}
        });
        delivery.setVisibility(View.GONE);
        LinearLayout row=new LinearLayout(host);stats.addView(row);
        received=metric(row,"已收");pending=metric(row,"待傳");verified=metric(row,"Drive 已核對");
        verifiedCaption=(TextView)((LinearLayout)verified.getParent()).getChildAt(1);
        host.space(stats,7);
        bar=new ProgressBar(host,null,android.R.attr.progressBarStyleHorizontal);bar.setMax(100);
        bar.setProgressTintList(android.content.res.ColorStateList.valueOf(ConsoleActivity.ACCENT));stats.addView(bar,new LinearLayout.LayoutParams(-1,host.dp(6)));
        footer=host.label(stats,"查看本場傳送詳情　›",13,ConsoleActivity.MUTED);
        issues=host.label(stats,"",14,0xffffae95);issues.setVisibility(View.GONE);
        box.setOnClickListener(v->host.shootDetails());box.setContentDescription("查看本場傳送詳情");
    }
    private TextView latestChip(FrameLayout cover){
        TextView link=chip(cover,"回到最新",android.view.Gravity.TOP|android.view.Gravity.END);
        link.setMinHeight(host.dp(44));link.setGravity(android.view.Gravity.CENTER);link.setVisibility(View.GONE);
        link.setOnClickListener(v->{selected=-1;high=false;photo.resetView();if(large!=null)large.resetView();generation++;refresh();});return link;
    }
    private void page(int delta){
        if(total<1)return;
        int next=Math.max(0,Math.min(total-1,(selected<0?total-1:selected)+delta));
        selected=next==total-1?-1:next;high=false;generation++;refresh();
    }
    private void inspect(){
        if(index<0)return;
        if(selected<0)selected=index;
        high=true;generation++;refresh();
    }
    private void open(){
        if(viewer!=null||displayed==null)return;
        android.app.Dialog d=new android.app.Dialog(host,android.R.style.Theme_Material_NoActionBar_Fullscreen);
        FrameLayout stage=new FrameLayout(host);stage.setBackgroundColor(0xff000000);
        viewer=d;large=new ReviewPhoto(host,false,this::page,this::inspect,d::dismiss);
        large.enableDoubleTapZoom();
        stage.addView(large,new FrameLayout.LayoutParams(-1,-1));large.show(frame,displayed);
        large.setContentDescription("大圖 "+caption.getText());
        TextView x=chip(stage,"關閉大圖",android.view.Gravity.TOP|android.view.Gravity.START);
        x.setMinHeight(host.dp(48));x.setGravity(android.view.Gravity.CENTER);x.setOnClickListener(v->d.dismiss());
        largeCaption=chip(stage,caption.getText().toString(),android.view.Gravity.BOTTOM|android.view.Gravity.END);
        largeLatest=latestChip(stage);largeLatest.setVisibility(selected<0?View.GONE:View.VISIBLE);
        d.setContentView(stage);d.setOnDismissListener(dialog->{viewer=null;large=null;largeCaption=largeLatest=null;generation++;if(!closed)refresh();});
        d.getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY|View.SYSTEM_UI_FLAG_HIDE_NAVIGATION|View.SYSTEM_UI_FLAG_FULLSCREEN);
        d.show();generation++;refresh();
    }
    void save(android.os.Bundle b){b.putString("reviewSession",shownSession);b.putInt("reviewIndex",selected);b.putBoolean("reviewLarge",viewer!=null);}
    void restore(android.os.Bundle b){if(b!=null&&session().equals(b.getString("reviewSession"))){shownSession=session();selected=b.getInt("reviewIndex",-1);restoreViewer=b.getBoolean("reviewLarge");}}
    private TextView chip(FrameLayout frame,String text,int gravity){
        TextView chip=host.copy(text,12,0xffffffff,true);chip.setPadding(host.dp(9),host.dp(4),host.dp(9),host.dp(4));
        chip.setBackground(host.rounded(0xb5212121,12));FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(-2,-2,gravity);
        lp.setMargins(host.dp(10),host.dp(9),host.dp(10),host.dp(9));frame.addView(chip,lp);return chip;
    }
    private TextView metric(LinearLayout row,String title){
        LinearLayout cell=new LinearLayout(host);cell.setOrientation(LinearLayout.VERTICAL);
        row.addView(cell,new LinearLayout.LayoutParams(0,-2,1));
        TextView number=host.label(cell,"—",26,ConsoleActivity.TEXT,true);
        number.setGravity(android.view.Gravity.CENTER_HORIZONTAL);number.setMinHeight(host.dp(34));
        number.setFontFeatureSettings("tnum");host.label(cell,title,13,ConsoleActivity.MUTED);
        return number;
    }
    private String session(){
        if(!CaptureService.running)return host.getSharedPreferences("state",0).getString("last_session","");
        CaptureService service=CaptureService.active;
        SessionReport report=service==null?null:service.report;
        return report==null?"":report.dir.getAbsolutePath();
    }
    void refresh(){
        if(closed)return;
        String path=session();
        boolean live=CaptureService.running;
        scope.setText(live?"本場拍攝":path.isEmpty()?"尚未開始拍攝":"上一場拍攝");
        if(!path.equals(shownSession)){
            delivery.setVisibility(View.GONE);openId="";
            shownSession=path;generation++;selected=index=-1;total=0;high=false;displayed=null;restoreViewer=false;
            latest.setVisibility(View.GONE);if(viewer!=null)viewer.dismiss();photo.show("",null);photo.setVisibility(View.GONE);
            bar.setProgress(0);footer.setText("查看本場傳送詳情　›");caption.setText("等待完整 JPG");issues.setVisibility(View.GONE);
            for(TextView n:new TextView[]{received,pending,verified})n.setText("0");
        }
        if(live)delivery.setVisibility(View.GONE);
        if(path.isEmpty()||busy)return;
        CaptureService service=CaptureService.active;
        SessionReport report=service==null?null:service.report;
        if(live&&(report==null||!path.equals(report.dir.getAbsolutePath())))return;
        int wanted=selected,stamp=generation,max=high||viewer!=null?3072:720;
        busy=true;
        reader.execute(()->{
            Result result=null;
            try{result=load(new File(path),live?report:null,wanted,max);}catch(Exception ignored){}
            Result value=result;
            host.runOnUiThread(()->{
                busy=false;
                if(closed||!path.equals(session())||live!=CaptureService.running)return;
                if(stamp!=generation){refresh();return;}
                if(value==null){issues.setText("未能讀取本場紀錄");issues.setVisibility(View.VISIBLE);return;}
                received.setText(String.valueOf(value.count));pending.setText(String.valueOf(value.waiting));
                verified.setText(String.valueOf(value.done));
                if(!live){
                    eventTitle.setText(value.eventTitle);
                    driveTarget.setText(value.route);
                    openId=value.folderId;
                    openFolder.setVisibility(openId.isEmpty()?View.GONE:View.VISIBLE);
                    delivery.setVisibility(View.VISIBLE);
                }
                verifiedCaption.setText(value.computer?"電腦已核對":value.onedrive?"OneDrive 已核對":"Drive 已核對");
                bar.setProgress(value.count==0?0:Math.min(100,Math.round(100f*value.done/value.count)));
                String finished=value.computer?"本場照片已全部傳到電腦　›":value.onedrive?"本場照片已全部傳到 OneDrive　›":"本場照片已全部傳到 Drive　›";
                footer.setText(value.count==0?(live?"等待本場第一張 JPG　›":"本場沒有收到 JPG　›"):value.done==value.count?finished:"查看本場傳送詳情　›");
                issues.setText(value.failed+" 張上傳需處理"+(value.issue.isEmpty()?"":"："+value.issue));issues.setVisibility(value.failed>0?View.VISIBLE:View.GONE);
                photo.setVisibility(value.image==null?View.GONE:View.VISIBLE);
                total=value.count;index=value.index;displayed=value.image;frame=path+"/"+value.local;
                photo.show(frame,displayed);photo.setContentDescription((selected<0?"最新照片 ":"瀏覽照片 ")+value.name);
                caption.setText(value.name.isEmpty()?"等待完整 JPG":value.name+"  ·  "+value.status+"  ·  "+(index+1)+"/"+total+(displayed==null?"  ·  預覽不可用":""));
                latest.setVisibility(selected<0?View.GONE:View.VISIBLE);
                if(large!=null){large.show(frame,displayed);large.setContentDescription("大圖 "+value.name);largeCaption.setText(caption.getText());largeLatest.setVisibility(latest.getVisibility());}
                if(restoreViewer&&displayed!=null){restoreViewer=false;open();}
            });
        });
    }
    private static final class Result {int count,waiting,done,failed,index; boolean computer,onedrive; String name,status,local,eventTitle,route,folderId,issue=""; Bitmap image;}
    private Result load(File dir,SessionReport report,int wanted,int max)throws Exception{
        boolean live=report!=null;
        if(!live){
            if(!dir.getPath().equals(savedSession)){
                savedPhotos.clear();
                savedPhotos.addAll(readPhotoNames(dir));
                savedSession=dir.getPath();
            }
        }else savedSession=null;
        int count=live?report.photoCount():savedPhotos.size(),i=wanted<0?count-1:Math.min(wanted,count-1);
        String local=i<0?"":live?report.photoAt(i):savedPhotos.get(i);
        if(!dir.getPath().equals(targetSession)){
            File target=new File(dir,"cloud-target.json");
            targetAccount="";targetFolder="";targetName="";
            if(target.isFile()){
                JSONObject dest=Gallery.record(target);
                targetAccount=dest.getString("account");targetFolder=dest.getString("folder");
                targetName=dest.optString("eventName",dest.optString("folder_name"));
            }
            targetSession=live&&!target.isFile()?null:dir.getPath();
        }
        File staged=new File(new File(dir,"jpg"),local);
        String stagedPath="";try{stagedPath=staged.getCanonicalPath();}catch(IOException e){stagedPath=staged.getAbsolutePath();}
        int[] queue=CloudStore.get(host).shootCounts(dir.getName(),stagedPath,targetAccount,targetFolder);
        int[] pc=DavBackup.pcShoot(host,dir,stagedPath);
        int[] one=OneDriveStore.get(host).shoot(dir.getName(),stagedPath);
        android.content.SharedPreferences onePrefs=OneDriveAuth.prefs(host);
        boolean oneOn=onePrefs.getBoolean("enabled",false)&&OneDriveAuth.signedIn(onePrefs);
        boolean pcPaired=DavBackup.pcPaired(host);
        boolean computer=pc[0]>0||(live&&pcPaired&&targetAccount.isEmpty()&&queue[0]==0&&one[0]==0);
        boolean onedrive=!computer&&queue[0]==0&&(one[0]>0||(oneOn&&targetAccount.isEmpty()));
        Result r=new Result();r.index=i;r.local=local;r.count=count;r.computer=computer;r.onedrive=onedrive;
        if(computer){r.done=pc[1];r.failed=pc[2];}
        else if(onedrive){r.done=one[1];r.failed=one[2];
            if(r.failed>0){String err=OneDriveStore.get(host).shootIssue(dir.getName());r.issue=err.contains("itemNotFound")||err.contains("notFound")?"OneDrive 資料夾不存在或這個 App 讀不到":err;}}
        else{r.done=queue[1];r.failed=queue[2];
            if(r.failed>0)try(android.database.Cursor failures=CloudStore.get(host).shootFailures(dir.getName(),targetAccount,targetFolder)){
                if(failures.moveToFirst()){String err=failures.getString(2);r.issue=err!=null&&err.contains("notFound")?"Drive 資料夾不存在或這個 App 讀不到":err==null?"":err;}
            }}
        if(!live){
            String name=SessionNames.get(host,dir);
            r.eventTitle=name.isEmpty()?"上一場交付紀錄":name;
            r.folderId=targetFolder;
            if(EventFolder.key(dir).equals(targetFolder))r.folderId=EventFolder.readyId(dir);
            String label=targetName;
            android.content.SharedPreferences cloud=CloudStore.prefs(host);
            if(label.isEmpty()&&targetAccount.equals(cloud.getString("account",""))&&targetFolder.equals(cloud.getString("folder","")))
                label=cloud.getString("folder_name","");
            if(computer){r.route="電腦 · 同一 Wi-Fi";r.folderId="";}
            else if(onedrive){r.route="OneDrive";r.folderId="";}
            else if(targetFolder.isEmpty())r.route=queue[0]==0?"本場未設定 Drive 上傳":"手動加入 Drive · 查看本場傳送詳情";
            else{
                r.route=label.isEmpty()?"Google Drive · 本場指定資料夾":"Google Drive ／ "+label;
                if(r.folderId.isEmpty())r.route+=" · 待建立";
            }
        }
        int expected=computer?Math.max(count,pc[0]):onedrive?Math.max(count,one[0]):targetAccount.isEmpty()?queue[0]:Math.max(count,queue[0]);
        r.waiting=Math.max(0,expected-r.done-r.failed);
        r.name=local.replaceFirst("^[0-9]+_","");
        int stage=computer?pc[3]:onedrive?one[3]:queue[3];
        r.status=stage==2?(computer?"電腦已核對":onedrive?"OneDrive 已核對":"Drive 已核對"):stage==1?"上傳需處理":stage==0&&computer&&pc[0]>0?"正在傳電腦":stage==0&&onedrive&&one[0]>0?"正在傳 OneDrive":"已存手機";
        String key=local.isEmpty()?"":staged.getPath()+"#"+max;
        if(!key.equals(bitmapKey)){
            bitmap=null;
            if(!local.isEmpty())try{
                bitmap=thumbnail(host,staged,max);
            }catch(Exception ignored){}
            bitmapKey=key;
        }
        r.image=bitmap;return r;
    }
    static java.util.List<String> readPhotoNames(File dir)throws IOException{
        java.util.List<String> names=new java.util.ArrayList<>();
        try(BufferedReader rows=Files.newBufferedReader(new File(dir,"files.csv").toPath(),StandardCharsets.UTF_8)){
            String line;
            while((line=rows.readLine())!=null){
                Matcher match=OK.matcher(line);
                if(match.find())names.add(match.group(1));
            }
        }
        return names;
    }
    static Bitmap thumbnail(android.content.Context context,File staged,int max)throws Exception{
                ImageDecoder.Source src=staged.isFile()?ImageDecoder.createSource(staged):
                    ImageDecoder.createSource(context.getContentResolver(),Uri.parse(Gallery.record(Gallery.marker(staged)).getString("uri")));
                return ImageDecoder.decodeBitmap(src,(decoder,info,source)->{
                    int longest=Math.max(info.getSize().getWidth(),info.getSize().getHeight());
                    decoder.setTargetSampleSize(Math.max(1,(longest+max-1)/max));
                    decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
                });
    }
    void close(){closed=true;if(viewer!=null)viewer.dismiss();reader.shutdownNow();}
}
