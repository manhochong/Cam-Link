package hk.camlink.usb;

import android.app.Instrumentation;
import android.content.*;
import android.os.Bundle;
import com.google.android.gms.auth.api.identity.*;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.tasks.Tasks;
import java.util.concurrent.*;
import org.json.JSONObject;

/** Explicit opt-in real-device auth check; no token is printed or written to disk. */
public class CloudLoginProbe extends Instrumentation {
    private String email,uploadSession;
    @Override public void onCreate(Bundle args){super.onCreate(args);email=args==null?"":args.getString("account","");uploadSession=args==null?"":args.getString("upload_session","");start();}
    @Override public void onStart(){Bundle out=new Bundle();int code=0;Context c=getTargetContext();
        try {
            if(email.isEmpty())throw new IllegalArgumentException("Explicit account required");
            AuthorizationResult r=Tasks.await(Identity.getAuthorizationClient(c).authorize(CloudAuth.request(email)),35,TimeUnit.SECONDS);
            if(r.hasResolution()){out.putString("stream","GOOGLE_AUTH: USER_CONSENT_REQUIRED\nRegistration accepted by API; user interaction is required. No token saved.\n");}
            else if(r.getAccessToken()==null){throw new IllegalStateException("No access token returned");}
            else {
                String access=r.getAccessToken();JSONObject user=new DriveApi(()->access).user();String actual=user.getString("emailAddress"),id=user.getString("permissionId");
                if(!actual.equalsIgnoreCase(email))throw new IllegalStateException("Returned account differs from explicitly selected account");
                SharedPreferences p=CloudStore.prefs(c);SharedPreferences.Editor edit=p.edit().putString("account",id).putString("email",actual).putBoolean("paused",true).remove("cloud_error");
                if(!p.getString("account","").equals(id))edit.putBoolean("enabled",false).remove("folder").remove("folder_name");if(!edit.commit())throw new IllegalStateException("Account persistence failed");
                if(uploadSession.isEmpty())out.putString("stream","GOOGLE_AUTH: SUCCESS\nDrive about.user verified selected account. Account saved; automatic upload remains disabled until configured. No credential exported.\n");
                else {
                    if(!uploadSession.matches("[0-9]{8}-[0-9]{6}-[0-9a-f]{6}"))throw new IllegalArgumentException("Explicit valid session name required");
                    DriveApi api=new DriveApi(()->access);String folder=p.getString("folder","");String folderName=p.getString("folder_name","");
                    if(folder.isEmpty()){
                        folderName="Cam Link USB 驗證 2026-10-31";String pendingKey=id+"\n"+folderName;
                        folder=pendingKey.equals(p.getString("folder_pending_key",""))?p.getString("folder_pending_id",""):"";
                        if(folder.isEmpty()){folder=api.generateId();if(!p.edit().putString("folder_pending_key",pendingKey).putString("folder_pending_id",folder).commit())throw new IllegalStateException("Folder ID persistence failed");}
                        try{api.createFolder(folderName,folder);}catch(DriveApi.Failure e){if(e.status!=409)throw e;}
                        api.checkFolder(folder);p.edit().putString("folder",folder).putString("folder_name",folderName).remove("folder_pending_key").remove("folder_pending_id").commit();
                    }
                    CloudStore db=CloudStore.get(c);java.io.File session=new java.io.File(new java.io.File(c.getExternalFilesDir(null),"sessions"),uploadSession);
                    int added=db.importSession(session,new JSONObject().put("account",id).put("email",actual).put("folder",folder),()->false);
                    java.util.List<CloudStore.Job> jobs=new java.util.ArrayList<>();try(android.database.Cursor rows=db.getReadableDatabase().query("uploads",null,"account=? AND folder=? AND session=?",new String[]{id,folder,uploadSession},null,null,"created")){while(rows.moveToNext())jobs.add(CloudStore.Job.from(rows));}
                    if(jobs.isEmpty())throw new IllegalStateException("No JPG in explicit session");
                    long started=android.os.SystemClock.elapsedRealtime(),bytes=0;int verified=0;
                    for(CloudStore.Job job:jobs){
                        if(!job.state.equals("DONE"))new UploadEngine(api,db::save,()->false,n->{}).run(job,Gallery.source(c,new java.io.File(job.path)));
                        DriveApi.verify(api.metadata(job.remote),job.remote,job.folder,job.size,job.md5,job.sha);verified++;bytes+=job.size;
                        Bundle progress=new Bundle();progress.putString("stream","VERIFIED "+job.name+" bytes="+job.size+"\n");sendStatus(0,progress);
                    }
                    try(java.io.FileOutputStream report=new java.io.FileOutputStream(new java.io.File(c.getExternalFilesDir(null),"cloud-verified-report.json"))){db.export(report);report.getFD().sync();}
                    p.edit().putBoolean("enabled",true).putBoolean("paused",false).commit();
                    out.putString("stream","GOOGLE_AUTH: SUCCESS\nDRIVE_UPLOAD_VERIFIED="+verified+"\nNEWLY_QUEUED="+added+"\nBYTES="+bytes+"\nELAPSED_MS="+(android.os.SystemClock.elapsedRealtime()-started)+"\nFOLDER_ID="+folder+"\nAuto upload enabled for future sessions. Local files retained.\n");
                }
            }
        }catch(Exception e){code=1;Throwable cause=e instanceof ExecutionException?e.getCause():e;String error=cause instanceof ApiException?"Google ApiException status="+((ApiException)cause).getStatusCode():cause instanceof DriveApi.Failure?cause.getMessage():cause.getClass().getSimpleName();CloudStore.prefs(c).edit().putString("cloud_error",error).commit();out.putString("stream","GOOGLE_AUTH: FAILED\n"+error+"\n");}
        finish(code,out);
    }
}
