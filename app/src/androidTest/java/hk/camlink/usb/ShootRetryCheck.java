package hk.camlink.usb;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.*;
import android.database.Cursor;
import android.os.SystemClock;
import android.view.View;
import android.view.inspector.WindowInspector;
import java.io.File;
import java.nio.file.Files;
import org.json.JSONObject;

final class ShootRetryCheck {
    static void run(Instrumentation test)throws Exception{
        Context c=test.getTargetContext();
        if(CaptureService.running||UploadService.running)throw new AssertionError("Transfer active");
        CloudStore db=CloudStore.get(c);
        File dir=Files.createTempDirectory(c.getCacheDir().toPath(),"shoot-retry-").toFile();
        String session=dir.getName(),account=session+"-qa",other=account+"-other";
        SharedPreferences prefs=CloudStore.prefs(c);
        String old=prefs.getString("account",null);
        Boolean paused=prefs.contains("paused")?prefs.getBoolean("paused",false):null;
        File binding=new File(dir,"cloud-target.json"),summary=new File(dir,"summary.json");
        Activity detail=null;
        try{
            prefs.edit().putBoolean("paused",true).putString("account",account).commit();
            JSONObject dest=new JSONObject().put("account",account).put("email","qa@example.invalid").put("folder","folder");
            SessionReport.writeJson(binding,dest);SessionReport.writeJson(summary,new JSONObject().put("valid_jpg",3));
            String[] states={"ERROR","AUTH","DONE","ERROR","ERROR","ERROR","RETRY"};
            for(int i=0;i<states.length;i++){
                String name="QA"+i+".JPG";
                dest.put("account",i==5?other:account).put("folder",i==4?"another-folder":"folder");
                db.enqueue(new File(dir,name),name,i==3?session+"-other":session,1,"qa",dest);
                ContentValues values=new ContentValues();values.put("state",states[i]);values.put("error","reason-"+i);
                values.put("remote","stable-id");values.put("offset",1);values.put("attempts",4);
                db.getWritableDatabase().update("uploads",values,"account=? AND name=?",new String[]{dest.getString("account"),name});
            }
            detail=test.startActivitySync(new Intent(c,ShootDetail.class).putExtra("session",dir.getPath()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            WorkspaceUiCheck.click(test,detail,"需處理 2 項　›");
            boolean[] tapped={false};
            for(int i=0;i<80&&!tapped[0];i++){
                test.runOnMainSync(()->{
                    for(View root:WindowInspector.getGlobalWindowViews()){
                        View retry=WorkspaceUiCheck.find(root,"只重試本場");
                        if(retry!=null&&WorkspaceUiCheck.find(root,"QA0.JPG\nreason-0")!=null&&
                                WorkspaceUiCheck.find(root,"QA1.JPG\nreason-1\n請先重新登入 Google Drive")!=null){retry.performClick();tapped[0]=true;break;}
                    }
                });
                if(!tapped[0])SystemClock.sleep(60);
            }
            if(!tapped[0])throw new AssertionError("Missing failure details or action");
            for(int i=0;i<80;i++){
                try(Cursor failed=db.shootFailures(session,account,"folder")){if(failed.getCount()==0)break;}
                SystemClock.sleep(50);
            }
            try(Cursor rows=db.getReadableDatabase().rawQuery("SELECT state,remote,offset,attempts FROM uploads WHERE account IN (?,?) ORDER BY name",new String[]{account,other})){
                for(int i=0;i<states.length;i++){
                    if(!rows.moveToNext()||!(i<2?"WAITING":states[i]).equals(rows.getString(0))||
                            !"stable-id".equals(rows.getString(1))||rows.getInt(2)!=1||rows.getInt(3)!=(i<2?0:4))
                        throw new AssertionError("Incorrect retry scope or lost progress at "+i);
                }
            }
            if(UploadService.running||!prefs.getBoolean("paused",false))throw new AssertionError("Manual pause ignored");
        }finally{
            if(detail!=null){Activity screen=detail;test.runOnMainSync(screen::finish);test.waitForIdleSync();}
            db.getWritableDatabase().delete("uploads","account IN (?,?)",new String[]{account,other});
            SharedPreferences.Editor restore=prefs.edit().putString("account",old);
            if(paused==null)restore.remove("paused");else restore.putBoolean("paused",paused);
            restore.commit();binding.delete();summary.delete();dir.delete();
        }
    }
}
