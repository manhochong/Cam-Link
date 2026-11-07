package hk.camlink.usb;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;

/** Exercise only navigation and disclosures. Leave account and transfer settings intact. */
final class WorkspaceUiCheck {
    private static volatile Activity foreground;
    private static final android.app.Application.ActivityLifecycleCallbacks tracker=new android.app.Application.ActivityLifecycleCallbacks(){
        public void onActivityCreated(Activity a,Bundle b){}
        public void onActivityStarted(Activity a){}
        public void onActivityResumed(Activity a){foreground=a;}
        public void onActivityPaused(Activity a){if(foreground==a)foreground=null;}
        public void onActivityStopped(Activity a){}
        public void onActivitySaveInstanceState(Activity a,Bundle b){}
        public void onActivityDestroyed(Activity a){}
    };
    private static Activity returned(Class<?> type){
        for(int i=0;i<80;i++){
            Activity a=foreground;if(type.isInstance(a)&&!a.isFinishing()&&!a.isDestroyed())return a;
            android.os.SystemClock.sleep(80);
        }
        throw new AssertionError("Did not resume "+type.getSimpleName());
    }
    private static boolean hasThumbnail(View view){
        if(view.getVisibility()!=View.VISIBLE)return false;
        if(view instanceof android.widget.ImageView && view.getContentDescription()!=null &&
            view.getContentDescription().toString().startsWith("最新照片 ") &&
            ((android.widget.ImageView)view).getDrawable()!=null)return true;
        if(view instanceof ViewGroup){
            ViewGroup group=(ViewGroup)view;
            for(int i=0;i<group.getChildCount();i++)if(hasThumbnail(group.getChildAt(i)))return true;
        }
        return false;
    }
    static View find(View parent,String text){
        if(parent.getVisibility()!=View.VISIBLE)return null;
        if(text.contentEquals(parent.getContentDescription()==null?"":parent.getContentDescription()))return parent;
        if(parent instanceof TextView && text.contentEquals(((TextView)parent).getText()))return parent;
        if(parent instanceof ViewGroup){
            ViewGroup children=(ViewGroup)parent;
            for(int i=0;i<children.getChildCount();i++){
                View match=find(children.getChildAt(i),text);
                if(match!=null)return match;
            }
        }
        return null;
    }
    private static View require(Activity activity,String text){
        View match=find(activity.getWindow().getDecorView(),text);
        if(match==null)throw new AssertionError("Missing "+text);
        return match;
    }
    private static void hidden(Activity activity,String text){
        if(find(activity.getWindow().getDecorView(),text)!=null)throw new AssertionError("Unexpected "+text);
    }
    private static void preview(Activity activity,String name){
        View view=activity.findViewById(android.R.id.content);
        Bitmap bitmap=Bitmap.createBitmap(view.getWidth(),view.getHeight(),Bitmap.Config.ARGB_8888);
        view.draw(new Canvas(bitmap));
        try(FileOutputStream out=new FileOutputStream(new File(activity.getExternalFilesDir(null),name))){
            if(!bitmap.compress(Bitmap.CompressFormat.PNG,100,out))throw new AssertionError("Preview encoding failed");
        }catch(java.io.IOException e){throw new AssertionError(e);}
        finally{bitmap.recycle();}
    }
    static void click(Instrumentation test,Activity a,String text){
        View[] match={null};
        for(int i=0;i<60&&match[0]==null;i++){
            test.runOnMainSync(()->match[0]=find(a.getWindow().getDecorView(),text));
            if(match[0]==null)android.os.SystemClock.sleep(65);
        }
        if(match[0]==null)throw new AssertionError("Missing "+text);
        View item=match[0];
        while(!item.isClickable()&&item.getParent() instanceof View)item=(View)item.getParent();
        final View target=item;test.runOnMainSync(target::performClick);test.waitForIdleSync();
    }
    private static Activity open(Instrumentation test,Activity a,String text,Class<?> target){
        Instrumentation.ActivityMonitor monitor=test.addMonitor(target.getName(),null,false);
        click(test,a,text);Activity next=test.waitForMonitorWithTimeout(monitor,5000);test.removeMonitor(monitor);
        if(next==null)throw new AssertionError("Navigation failed: "+text);
        test.waitForIdleSync();return next;
    }
    static void run(Instrumentation test){
        Bundle result=new Bundle();
        try{
            ((android.app.Application)test.getTargetContext().getApplicationContext()).registerActivityLifecycleCallbacks(tracker);
            Activity main=test.startActivitySync(new Intent(test.getTargetContext(),MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            test.waitForIdleSync();
            // The latest JPEG and per-shoot queue are read off the UI thread.
            String session=test.getTargetContext().getSharedPreferences("state",0).getString("last_session","");
            if(!session.isEmpty()&&new File(session,"summary.json").isFile()){
                int expected=new org.json.JSONObject(new String(java.nio.file.Files.readAllBytes(
                    new File(session,"summary.json").toPath()),java.nio.charset.StandardCharsets.UTF_8)).optInt("valid_jpg",0);
                if(expected>0){
                    boolean[] loaded={false};
                    for(int i=0;i<60&&!loaded[0];i++){
                        test.runOnMainSync(()->loaded[0]=find(main.getWindow().getDecorView(),String.valueOf(expected))!=null&&
                            hasThumbnail(main.getWindow().getDecorView()));
                        if(!loaded[0])Thread.sleep(100);
                    }
                    if(!loaded[0])throw new AssertionError("Session count / thumbnail did not load");
                    PhotoGesturesCheck.run(test,expected);
                    result.putString("photo_gestures","PASS double tap 2x and fit, pinch and single tap dismissal; session size="+expected);
                }
            }
            {
                android.content.Context context=test.getTargetContext();
                File[] history=new File(context.getExternalFilesDir(null),"sessions").listFiles(File::isDirectory);
                if(history!=null){
                    java.util.Arrays.sort(history,java.util.Comparator.reverseOrder());
                    for(File prior:history){
                        File summary=new File(prior,"summary.json");
                        if(!summary.isFile())continue;
                        int count=new org.json.JSONObject(new String(java.nio.file.Files.readAllBytes(summary.toPath()),
                                java.nio.charset.StandardCharsets.UTF_8)).optInt("valid_jpg");
                        if(count<2)continue;
                        Activity list=open(test,main,"紀錄",ShootDetail.class);
                        android.widget.ListView rows=(android.widget.ListView)require(list,"拍攝場次列表");
                        View[] verifiedRow={null};
                        for(int attempt=0;attempt<80&&verifiedRow[0]==null;attempt++){
                            test.runOnMainSync(()->{
                                for(int i=0;i<rows.getCount();i++){
                                    if(!prior.equals(rows.getItemAtPosition(i)))continue;
                                    View row=rows.getChildAt(i-rows.getFirstVisiblePosition());
                                    if(row==null){rows.setSelection(i);break;}
                                    View cover=find(row,"場次封面");
                                    if(find(row,count+" 張照片")!=null&&cover instanceof android.widget.ImageView
                                            &&((android.widget.ImageView)cover).getDrawable() instanceof android.graphics.drawable.BitmapDrawable)
                                        verifiedRow[0]=row;
                                    break;
                                }
                            });
                            if(verifiedRow[0]==null)Thread.sleep(80);
                        }
                        if(verifiedRow[0]==null)throw new AssertionError("Session cover or count missing: "+count);
                        java.util.Set<File> listed=new java.util.HashSet<>();
                        test.runOnMainSync(()->{
                            for(int i=0;i<rows.getCount();i++)listed.add((File)rows.getItemAtPosition(i));
                        });
                        int hiddenEmpty=0;
                        for(File recorded:history){
                            File totals=new File(recorded,"summary.json");
                            if(!recorded.getName().matches("[0-9]{8}-[0-9]{6}-.+")||!totals.isFile())continue;
                            int received=new org.json.JSONObject(new String(java.nio.file.Files.readAllBytes(totals.toPath()),
                                    java.nio.charset.StandardCharsets.UTF_8)).optInt("valid_jpg",-1);
                            if(received<0)continue;
                            if(listed.contains(recorded)!=(received>0))throw new AssertionError("History filter mismatch for "+recorded.getName());
                            if(received==0)hiddenEmpty++;
                        }
                        test.runOnMainSync(()->preview(list,"history-ui.png"));
                        Instrumentation.ActivityMonitor shootMonitor=test.addMonitor(ShootDetail.class.getName(),null,false);
                        test.runOnMainSync(()->{
                            int position=rows.getPositionForView(verifiedRow[0]);
                            rows.performItemClick(verifiedRow[0],position,rows.getItemIdAtPosition(position));
                        });
                        Activity shoot=test.waitForMonitorWithTimeout(shootMonitor,5000);test.removeMonitor(shootMonitor);
                        if(shoot==null)throw new AssertionError("Session row did not open");
                        Activity album=open(test,shoot,"瀏覽本場照片",SessionAlbum.class);
                        android.widget.GridView grid=(android.widget.GridView)require(album,"本場照片列表");
                        for(int i=0;i<60&&grid.getChildCount()<2;i++)Thread.sleep(80);
                        if(grid.getCount()!=count)throw new AssertionError("History and album counts differ");
                        java.util.List<String> names=ShootPanel.readPhotoNames(prior);
                        String first="大圖 "+names.get(0).replaceFirst("^[0-9]+_","");
                        String second="大圖 "+names.get(1).replaceFirst("^[0-9]+_","");
                        test.runOnMainSync(()->grid.performItemClick(grid.getChildAt(1),1,1));
                        ReviewPhoto big=PhotoGesturesCheck.waitFor(test,second);
                        test.runOnMainSync(()->PhotoGesturesCheck.stroke(big,.25f,.75f));
                        PhotoGesturesCheck.waitFor(test,first);
                        test.runOnMainSync(()->PhotoGesturesCheck.stroke(big,.75f,.25f));
                        PhotoGesturesCheck.checkZoom(test,PhotoGesturesCheck.waitFor(test,second));
                        click(test,album,"‹ 返回");click(test,shoot,"‹ 返回");click(test,list,"‹ 返回");
                        result.putString("photo_gestures","PASS history album: open second photo, swipe both ways, double tap 2x and fit, pinch and dismiss; session size="+count+"; hidden empty sessions="+hiddenEmpty);
                        break;
                    }
                }
            }
            click(test,main,"更多");require(main,"查看 USB 裝置診斷");click(test,main,"首頁");
            test.waitForIdleSync();
            final String[] misaligned={null};
            test.runOnMainSync(()->{
                for(String name:new String[]{"首頁","紀錄","傳送","更多"}){
                    ViewGroup tab=(ViewGroup)require(main,name);
                    View icon=tab.getChildAt(0);TextView title=(TextView)tab.getChildAt(1);
                    float glyphCenter=title.getLeft()+title.getCompoundPaddingLeft()+
                        (title.getLayout().getLineLeft(0)+title.getLayout().getLineRight(0))/2f;
                    if(Math.abs(glyphCenter-(icon.getLeft()+icon.getWidth()/2f))>2)misaligned[0]=name;
                }
                preview(main,"workspace-ui.png");
            });
            if(misaligned[0]!=null)throw new AssertionError("Navigation label off center: "+misaligned[0]);
            Activity detail=open(test,main,"查看本場傳送詳情",ShootDetail.class);
            for(int i=0;i<40&&!session.isEmpty()&&find(detail.getWindow().getDecorView(),"最近已核對")==null;i++)Thread.sleep(100);
            if(!session.isEmpty())require(detail,"最近已核對");
            test.runOnMainSync(()->preview(detail,"shoot-ui.png"));click(test,detail,"‹ 返回");
            Activity directory=open(test,returned(MainActivity.class),"傳送",OtherClouds.class);
            require(directory,"加入其他服務");test.runOnMainSync(()->preview(directory,"destinations-ui.png"));
            Activity cloud=open(test,directory,"Google Drive",CloudActivity.class);
            require(cloud,"上傳進度");click(test,cloud,"更多工具");require(cloud,"Google 登入設定說明");
            click(test,cloud,"收起更多工具");click(test,cloud,"‹   返回目的地");click(test,returned(OtherClouds.class),"返回");
            result.putString("stream","PASS latest photo, shoot counters, advanced tools, shoot details, destinations, Drive settings and return\n"+result.getString("photo_gestures","Gesture checks skipped: no session photo")+"\n");
            test.finish(Activity.RESULT_OK,result);
        }catch(Throwable error){
            result.putString("stream","FAIL "+error+"\n");
            test.finish(Activity.RESULT_CANCELED,result);
        }
    }
}
