package hk.camlink.usb;

import android.app.*;
import android.content.*;
import android.graphics.Bitmap;
import android.os.SystemClock;
import android.view.View;
import android.view.inspector.WindowInspector;
import java.io.*;
import java.nio.file.Files;
import java.util.*;
import org.json.*;

final class PhotoTimesCheck {
    static void run(Instrumentation test)throws Exception{
        Context context=test.getTargetContext();
        File dir=Files.createTempDirectory(context.getCacheDir().toPath(),"photo-times-").toFile();
        String session=dir.getName(),name="QA,晚宴.JPG";
        File jpg=new File(dir,"1_QA.JPG"),csv=new File(dir,"files.csv");
        CloudStore db=CloudStore.get(context);
        Activity detail=null;
        try{
            try(FileOutputStream out=new FileOutputStream(jpg)){
                Bitmap photo=Bitmap.createBitmap(16,16,Bitmap.Config.ARGB_8888);
                photo.compress(Bitmap.CompressFormat.JPEG,90,out);photo.recycle();
            }
            String[] hashes=DriveApi.hashes(jpg,()->false);
            Files.write(csv.toPath(),Arrays.asList("\"OK\",\"1\",\"1\",\""+name+"\",\"1_QA.JPG\",\"0\",\"0\",\"hash\",\"16\",\"16\",\"0\",\"120\",\"1370\",",
                    "\"OK\",\"2\",\"1\",\"local.JPG\",\"2_local.JPG\","));
            db.enqueue(jpg,name,session,jpg.length(),hashes[0],new JSONObject().put("account",session).put("email","").put("folder","folder"));
            SystemClock.sleep(25);
            CloudStore.Job job=db.next(session);db.markStarted(job);
            DriveApi api=new DriveApi(()->"qa",(method,url,headers,body)->{
                String data="{}";Map<String,String> resultHeaders=Collections.emptyMap();
                if(url.contains("generateIds"))data="{\"ids\":[\"file-id\"]}";
                else if(method.equals("POST"))resultHeaders=Collections.singletonMap("Location","https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture");
                else if(method.equals("PUT")){
                    body.write(new ByteArrayOutputStream());SystemClock.sleep(35);throw new EOFException("Lost reply");
                }else if(method.equals("GET")){
                    SystemClock.sleep(40);
                    data=new JSONObject().put("id","file-id").put("size",jpg.length()).put("md5Checksum",hashes[1]).put("parents",new JSONArray().put("folder")).toString();
                }else throw new AssertionError("Unexpected method");
                return new DriveApi.Reply(200,data,resultHeaders);
            });
            UploadEngine engine=new UploadEngine(api,db::save,()->false,n->{});
            try{engine.run(job);throw new AssertionError("Missing simulated interruption");}
            catch(EOFException expected){job.state="RETRY";db.save(job);}
            long initialQueue=job.queueMs,send=job.sendMs;
            job=db.next(session);db.markStarted(job);engine.run(job);
            if(!"DONE".equals(job.state)||initialQueue<20||initialQueue!=job.queueMs||send<30||send!=job.sendMs||job.verifyMs<35)
                throw new AssertionError("Timings lost or counted twice");
            List<String> rows=PhotoTimes.read(db,dir);
            String timed=rows.stream().filter(s->s.startsWith(name+"\n")).findFirst().orElseThrow(AssertionError::new);
            if(!timed.contains("接收 1.25 秒")||!timed.contains("雲端已核對")||timed.contains("—")||
                    !rows.contains("local.JPG\n接收 —\n未加入 Drive 上傳"))throw new AssertionError("Incorrect join or missing values");
            detail=test.startActivitySync(new Intent(context,ShootDetail.class).putExtra("session",dir.getPath()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            WorkspaceUiCheck.click(test,detail,"每張 JPG 耗時");
            boolean[] found={false};
            for(int i=0;i<80&&!found[0];i++){
                test.runOnMainSync(()->{for(View root:WindowInspector.getGlobalWindowViews())
                    if(WorkspaceUiCheck.find(root,timed)!=null)found[0]=true;});
                if(!found[0])SystemClock.sleep(60);
            }
            if(!found[0])throw new AssertionError("Timing row not shown in shoot details");
        }finally{
            if(detail!=null){Activity screen=detail;test.runOnMainSync(screen::finish);}
            db.getWritableDatabase().delete("uploads","account=?",new String[]{session});
            jpg.delete();csv.delete();dir.delete();
        }
    }
}
