package hk.camlink.usb;

import android.app.Instrumentation;
import android.os.Bundle;
import android.content.Context;
import android.graphics.Bitmap;
import java.io.*;
import java.util.*;
import org.json.JSONObject;

/** Isolated local-only checks against Android SQLite and filesystem, never Google/network. */
public final class CloudDeviceChecks extends CloudLoginProbe {
    private int count;private final StringBuilder log=new StringBuilder();
    private String namePhase; private boolean auth,ui,migrate,wireless,pc; private Bundle speedArgs;
    private boolean networkRoute;
    @Override public void onCreate(Bundle args){networkRoute=args!=null&&"network_route".equals(args.getString("mode"));namePhase=args==null?null:args.getString("namePhase");pc=args!=null&&"pc".equals(args.getString("mode"));wireless=args!=null&&"wireless".equals(args.getString("mode"));auth=args!=null&&"auth".equals(args.getString("mode"));ui=args!=null&&"ui".equals(args.getString("mode"));if(args!=null&&"speed".equals(args.getString("mode")))speedArgs=new Bundle(args);migrate=args!=null&&"move_album".equals(args.getString("mode"));super.onCreate(args);}
    private void check(boolean value,String message){if(!value)throw new AssertionError(message);count++;log.append("PASS ").append(message).append('\n');}
    @Override public void onStart(){if(networkRoute){NetworkRouteCheck.run(this);return;}if(namePhase!=null){SessionNameCheck.run(this,namePhase);return;}if(pc){WirelessChecks.pc(this);return;}if(wireless){WirelessChecks.run(this);return;}if(migrate){MoveExisting.run(this);return;}if(speedArgs!=null){SpeedCheck.run(this,speedArgs);return;}if(ui){WorkspaceUiCheck.run(this);return;}if(auth){super.onStart();return;}Bundle result=new Bundle();int code=0;Context c=getTargetContext();CloudStore db=CloudStore.get(c);String account="__local_test_"+UUID.randomUUID();File dir=new File(new File(c.getExternalFilesDir(null),"sessions"),account);File photos=new File(dir,"jpg");File one=new File(photos,"1_ONE.JPG"),two=new File(photos,"2_TWO.JPG"),part=new File(photos,"3_BAD.JPG.part");
        try {
            if(!photos.mkdirs())throw new IOException("Fixture directory unavailable");
            Bitmap image=Bitmap.createBitmap(32,24,Bitmap.Config.ARGB_8888);image.eraseColor(0xff387a90);try(FileOutputStream out=new FileOutputStream(one)){if(!image.compress(Bitmap.CompressFormat.JPEG,90,out))throw new IOException("Fixture JPEG failure");}image.recycle();
            java.nio.file.Files.copy(one.toPath(),two.toPath());try(FileOutputStream out=new FileOutputStream(part)){out.write(new byte[]{1,2,3});}
            JpegCheck jpeg=JpegCheck.check(one,one.length());JSONObject dest=new JSONObject().put("account",account).put("email","local-test@example.invalid").put("folder","folder-a");
            check(db.enqueue(one,"ONE.JPG",dir.getName(),one.length(),jpeg.sha256,dest),"first enqueue committed");
            check(!db.enqueue(one,"ONE.JPG",dir.getName(),one.length(),jpeg.sha256,dest),"same source and destination deduplicated");
            check(db.next(account+"-other")==null,"other account cannot claim queued file");
            CloudStore.Job job=db.next(account);check(job!=null&&job.folder.equals("folder-a"),"destination bound to queued file");
            job.remote="durable-file-id";job.uri="https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture";job.offset=128;job.state="UPLOADING";db.save(job);db.close();
            CloudStore.Job restored=db.next(account);check(restored.remote.equals("durable-file-id")&&restored.offset==128&&restored.uri.equals(job.uri),"file ID session URI and offset survive database reopen");
            check(db.importSession(dir,dest,()->false)==1,"recovery imports second JPG but skips duplicate and part");
            check(db.importSession(dir,dest,()->false)==0,"recovery is idempotent");
            check(db.nextExcept(account,restored.key)!=null&&!db.nextExcept(account,restored.key).key.equals(restored.key),"parallel worker excludes the reserved source");
            restored.state="DONE";restored.offset=restored.size;restored.uri="";db.save(restored);CloudStore.Job next=db.next(account);
            check(next!=null&&next.name.equals("TWO.JPG"),"identical-content separate captures both retained");
            next.state="AUTH";db.save(next);check(!db.pending(account),"auth-blocked jobs do not spin retries");db.retry(account);check(db.next(account)!=null&&db.next(account).state.equals("WAITING"),"explicit retry restores auth-blocked job");
            ByteArrayOutputStream report=new ByteArrayOutputStream();db.export(report);String json=report.toString("UTF-8");check(!json.contains("upload_id=")&&!json.contains("local-test@example.invalid"),"report excludes resumable URL and email");
            check(one.exists()&&two.exists()&&part.exists(),"queue operations preserve originals and partial file");
        }catch(Throwable e){code=1;log.append("FAIL ").append(e).append('\n');}
        finally{db.getWritableDatabase().delete("uploads","account=?",new String[]{account});one.delete();two.delete();part.delete();photos.delete();dir.delete();}
        result.putString("stream",log+"\nLOCAL DEVICE CHECKS: "+count+"\nNo Google API calls performed.\n");finish(code,result);
    }
}
