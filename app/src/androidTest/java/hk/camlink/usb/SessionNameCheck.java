package hk.camlink.usb;

import android.app.*;
import android.content.*;
import android.graphics.Bitmap;
import android.os.*;
import android.view.*;
import android.view.inspector.WindowInspector;
import android.widget.*;
import java.io.*;
import java.nio.file.Files;

/** The write and read checks run in separate processes, using a test-only session. */
final class SessionNameCheck {
    private static final String EVENT="春季攝影晚會 CamLink-QA";
    private static <T extends View> T child(View parent,Class<T> type){
        if(type.isInstance(parent))return type.cast(parent);
        if(parent instanceof ViewGroup){
            ViewGroup group=(ViewGroup)parent;
            for(int i=0;i<group.getChildCount();i++){
                T match=child(group.getChildAt(i),type);
                if(match!=null)return match;
            }
        }
        return null;
    }
    static void run(Instrumentation test,String phase){
        Context c=test.getTargetContext();Bundle result=new Bundle();
        File dir=new File(c.getExternalFilesDir(null),"sessions/20000101-000001-session-name-qa");
        File jpg=new File(dir,"jpg"),photo=new File(jpg,"1_QA.JPG"),log=new File(dir,"files.csv");
        try{
            if(phase.equals("photoTimes")){
                PhotoTimesCheck.run(test);
            }else if(phase.equals("shootRetry")){
                ShootRetryCheck.run(test);
            }else if(phase.equals("delivery")){
                DeliveryCheck.run(test);
            }else if(phase.equals("start")){
                checkStart(test);
            }else if(phase.equals("write")){
                if(!dir.mkdir()||!jpg.mkdir())throw new IOException("Fixture directory unavailable");
                try(FileOutputStream out=new FileOutputStream(photo)){
                    Bitmap bitmap=Bitmap.createBitmap(80,60,Bitmap.Config.ARGB_8888);
                    bitmap.compress(Bitmap.CompressFormat.JPEG,90,out);bitmap.recycle();
                }
                Files.write(log.toPath(),"\"OK\",\"1\",\"1\",\"QA.JPG\",\"1_QA.JPG\",\n".getBytes(java.nio.charset.StandardCharsets.UTF_8));
                Activity detail=test.startActivitySync(new Intent(c,ShootDetail.class).putExtra("session",dir.getPath()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                WorkspaceUiCheck.click(test,detail,"更改場次名稱");
                boolean[] saved={false};
                test.runOnMainSync(()->{
                    for(View root:WindowInspector.getGlobalWindowViews()){
                        View save=WorkspaceUiCheck.find(root,"儲存");EditText edit=child(root,EditText.class);
                        if(save!=null&&edit!=null){edit.setText(EVENT);save.performClick();saved[0]=true;break;}
                    }
                });
                test.waitForIdleSync();
                for(int i=0;i<60;i++){
                    boolean[] dialogOpen={false};
                    test.runOnMainSync(()->{
                        for(View root:WindowInspector.getGlobalWindowViews())
                            if(WorkspaceUiCheck.find(root,"儲存")!=null)dialogOpen[0]=true;
                    });
                    if(!dialogOpen[0])break;
                    SystemClock.sleep(80);
                }
                if(!saved[0]||!EVENT.equals(ShootDetail.eventName(c,dir)))throw new AssertionError("Name not saved; dialog button clicked="+saved[0]);
                test.runOnMainSync(detail::finish);
            }else if(phase.equals("read")){
                Activity main=test.startActivitySync(new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                Instrumentation.ActivityMonitor monitor=test.addMonitor(ShootDetail.class.getName(),null,false);
                WorkspaceUiCheck.click(test,main,"紀錄");
                Activity list=test.waitForMonitorWithTimeout(monitor,5000);test.removeMonitor(monitor);
                View root=list.getWindow().getDecorView();
                SearchView search=child(root,SearchView.class);ListView rows=child(root,ListView.class);
                test.runOnMainSync(()->search.setQuery("攝影晚會 camlink-qa",false));
                boolean[] found={false};
                for(int i=0;i<60&&!found[0];i++){
                    test.runOnMainSync(()->found[0]=rows.getCount()==1&&dir.equals(rows.getItemAtPosition(0))&&WorkspaceUiCheck.find(root,EVENT)!=null);
                    if(!found[0])SystemClock.sleep(100);
                }
                if(!found[0])throw new AssertionError("Search after restart: saved="+EVENT.equals(ShootDetail.eventName(c,dir))+" query="+search.getQuery()+" matches="+rows.getCount()+" photos="+ShootPanel.readPhotoNames(dir).size()+" label="+(WorkspaceUiCheck.find(root,EVENT)!=null));
                monitor=test.addMonitor(ShootDetail.class.getName(),null,false);
                test.runOnMainSync(()->rows.performItemClick(rows.getChildAt(0),0,0));
                Activity detail=test.waitForMonitorWithTimeout(monitor,5000);test.removeMonitor(monitor);
                monitor=test.addMonitor(SessionAlbum.class.getName(),null,false);
                WorkspaceUiCheck.click(test,detail,"瀏覽本場照片");
                Activity album=test.waitForMonitorWithTimeout(monitor,5000);test.removeMonitor(monitor);
                GridView photos=child(album.getWindow().getDecorView(),GridView.class);
                for(int i=0;i<60&&photos.getChildCount()==0;i++)SystemClock.sleep(100);
                test.runOnMainSync(()->photos.performItemClick(photos.getChildAt(0),0,0));
                PhotoGesturesCheck.waitFor(test,"大圖 QA.JPG");
            }
            result.putString("stream","PASS activity name "+phase+"\n");
        }catch(Throwable error){result.putString("stream","FAIL "+error+"\n");}
        finally{
            if(phase.equals("read")||phase.equals("cleanup")){
                c.getSharedPreferences("session_names",0).edit().remove(dir.getName()).commit();
                photo.delete();log.delete();jpg.delete();dir.delete();
            }
        }
        test.finish(Activity.RESULT_OK,result);
    }
    private static void dialogAction(Instrumentation test,String text,String name){
        boolean[] tapped={false};
        for(int attempt=0;attempt<50&&!tapped[0];attempt++){
        test.runOnMainSync(()->{
            for(View root:WindowInspector.getGlobalWindowViews()){
                if(name!=null&&WorkspaceUiCheck.find(root,"開始拍攝")==null)continue;
                View item=WorkspaceUiCheck.find(root,text);
                if(item==null)continue;
                if(name!=null){
                    EditText input=child(root,EditText.class);
                    if(input==null)continue;
                    input.setText(name);
                }
                ListView choices=child(root,ListView.class);
                if(choices!=null&&choices.getPositionForView(item)>=0){
                    int i=choices.getPositionForView(item);choices.performItemClick(item,i,i);
                }else item.performClick();
                tapped[0]=true;break;
            }
        });
        test.waitForIdleSync();
        if(!tapped[0])SystemClock.sleep(80);
        }
        if(!tapped[0])throw new AssertionError("Missing action "+text);
    }
    private static void checkStart(Instrumentation test)throws Exception{
        Context c=test.getTargetContext();
        if(CaptureService.running)throw new IOException("Capture already active");
        SharedPreferences state=c.getSharedPreferences("state",0);
        String previous=state.getString("last_session",null);
        Activity main=test.startActivitySync(new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        SessionReport report=null;
        try{
            report=new SessionReport(new File(c.getExternalFilesDir(null),"sessions"),"USB",2000,"");
            if(!SessionNames.save(c,report.dir,("  "+EVENT+"  ").trim()))throw new AssertionError("Name not saved");
            state.edit().putString("last_session",report.dir.getAbsolutePath()).commit();
            if(!EVENT.equals(SessionNames.get(c,report.dir)))throw new AssertionError("New session name mismatch");
            // Insert a verified test row locally; never queue a fixture to the user's destinations.
            File photo=new File(report.photos,"1_QA.JPG");
            try(FileOutputStream out=new FileOutputStream(photo)){
                Bitmap bmp=Bitmap.createBitmap(32,24,Bitmap.Config.ARGB_8888);
                bmp.compress(Bitmap.CompressFormat.JPEG,90,out);bmp.recycle();
            }
            report.row("OK",new ReceiveQueue.Item(1,0,"test"),new Ptp.Info(1,"QA.JPG",photo.length()),
                    photo.getName(),photo.length(),JpegCheck.check(photo,photo.length()),0,0,"");
            Instrumentation.ActivityMonitor monitor=test.addMonitor(ShootDetail.class.getName(),null,false);
            WorkspaceUiCheck.click(test,main,"紀錄");
            Activity history=test.waitForMonitorWithTimeout(monitor,5000);test.removeMonitor(monitor);
            View root=history.getWindow().getDecorView();SearchView search=child(root,SearchView.class);
            test.runOnMainSync(()->search.setQuery(EVENT,false));
            boolean[] matched={false};File expected=report.dir;
            for(int i=0;i<60&&!matched[0];i++){
                test.runOnMainSync(()->{
                    ListView rows=child(root,ListView.class);
                    matched[0]=rows.getCount()==1&&expected.equals(rows.getItemAtPosition(0))
                            &&WorkspaceUiCheck.find(root,EVENT)!=null&&WorkspaceUiCheck.find(root,"1 張照片")!=null;
                });
                if(!matched[0])SystemClock.sleep(100);
            }
            if(!matched[0])throw new AssertionError("First photo did not appear under the entered event name");
        }finally{
            CaptureService active=CaptureService.active;
            if(active!=null){active.gracefulStop();for(int i=0;i<80&&CaptureService.running;i++)SystemClock.sleep(100);}
            if(report!=null&&!CaptureService.running){
                SharedPreferences.Editor restore=state.edit();
                if(previous==null)restore.remove("last_session");else restore.putString("last_session",previous);
                restore.commit();SessionNames.save(c,report.dir,"");
                new File(report.photos,"1_QA.JPG").delete();report.photos.delete();
                for(String file:new String[]{"device.json","summary.json","files.csv","events.log","cloud-target.json"})new File(report.dir,file).delete();
                report.dir.delete();
            }
        }
    }
}
