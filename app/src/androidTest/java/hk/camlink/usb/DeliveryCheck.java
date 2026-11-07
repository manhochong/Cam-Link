package hk.camlink.usb;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.view.View;
import java.io.File;
import java.nio.file.Files;
import java.util.UUID;
import org.json.JSONObject;

/** The queued fixture is not eligible to send for 24 hours. No credentials are used. */
final class DeliveryCheck {
    static void run(Instrumentation test)throws Exception{
        Context context=test.getTargetContext();
        if(CaptureService.running||UploadService.running)throw new AssertionError("Transfer active");
        CloudStore db=CloudStore.get(context);
        SharedPreferences cloud=CloudStore.prefs(context),state=context.getSharedPreferences("state",0);
        String previousSession=state.getString("last_session",null),previousAccount=cloud.getString("account",null);
        Boolean previousPause=cloud.contains("paused")?cloud.getBoolean("paused",false):null;
        Boolean previousEnabled=cloud.contains("enabled")?cloud.getBoolean("enabled",false):null;
        String account="qa-"+UUID.randomUUID();
        File dir=Files.createTempDirectory(context.getCacheDir().toPath(),"delivery-").toFile();
        File target=new File(dir,"cloud-target.json"),rows=new File(dir,"files.csv"),receipt=new File(dir,"drive-event-folder.json");
        Activity main=null;
        try{
            JSONObject binding=EventFolder.bind(dir,new JSONObject().put("account",account).put("email","").put("folder",""),"原定活動");
            SessionReport.writeJson(target,binding);
            Files.write(rows.toPath(),new byte[0]);
            SessionNames.save(context,dir,"改名後的場次");
            state.edit().putString("last_session",dir.getAbsolutePath()).commit();
            cloud.edit().putString("account",account).putBoolean("paused",true).putBoolean("enabled",true).commit();
            db.enqueue(new File(dir,"fixture.jpg"),"fixture.jpg",dir.getName(),8,"fixture",binding);
            CloudStore.Job job=db.next(account);
            job.state="RETRY";job.next=System.currentTimeMillis()+86400000;db.save(job);
            Intent home=new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            main=test.startActivitySync(home);
            awaitText(test,main,"改名後的場次");awaitText(test,main,"Google Drive ／ 原定活動 · 待建立");
            if(UploadService.running)throw new AssertionError("Manual pause ignored");
            SessionReport.writeJson(receipt,new JSONObject().put("id","fixture-folder").put("ready",true));
            awaitText(test,main,"Google Drive ／ 原定活動");awaitText(test,main,"開啟資料夾");
            finish(test,main);main=null;
            cloud.edit().putBoolean("paused",false).commit();
            main=test.startActivitySync(home);
            for(int i=0;i<100&&!UploadService.running;i++)SystemClock.sleep(50);
            if(!UploadService.running)throw new AssertionError("Reopened app did not resume queue");
        }finally{
            if(main!=null)finish(test,main);
            cloud.edit().putBoolean("paused",true).commit();
            for(int i=0;i<150&&UploadService.running;i++)SystemClock.sleep(100);
            db.getWritableDatabase().delete("uploads","account=?",new String[]{account});
            SharedPreferences.Editor restore=cloud.edit().putString("account",previousAccount);
            if(previousPause==null)restore.remove("paused");else restore.putBoolean("paused",previousPause);
            if(previousEnabled==null)restore.remove("enabled");else restore.putBoolean("enabled",previousEnabled);
            restore.commit();
            state.edit().putString("last_session",previousSession).commit();
            SessionNames.save(context,dir,"");receipt.delete();rows.delete();target.delete();dir.delete();
        }
    }
    private static void finish(Instrumentation test,Activity activity){
        test.runOnMainSync(activity::finish);test.waitForIdleSync();
    }
    private static void awaitText(Instrumentation test,Activity main,String label){
        View[] match={null};
        for(int i=0;i<80&&match[0]==null;i++){
            test.runOnMainSync(()->match[0]=WorkspaceUiCheck.find(main.getWindow().getDecorView(),label));
            if(match[0]==null)SystemClock.sleep(60);
        }
        if(match[0]==null)throw new AssertionError("Missing "+label);
    }
}
