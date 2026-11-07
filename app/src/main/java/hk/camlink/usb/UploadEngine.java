package hk.camlink.usb;

import java.io.*;
import org.json.JSONObject;

/** One attempt; the durable worker owns retry policy and user-visible state. */
public final class UploadEngine {
    private static final int CHUNK_BYTES=32*1024*1024;
    public interface Save {void save(CloudStore.Job job)throws Exception;}
    private final DriveApi api;private final Save save;private final DriveApi.Cancel cancel;private final DriveApi.Progress progress;
    public UploadEngine(DriveApi api,Save save,DriveApi.Cancel cancel,DriveApi.Progress progress){this.api=api;this.save=save;this.cancel=cancel;this.progress=progress;}
    public void run(CloudStore.Job j)throws Exception {
        run(j,()->new FileInputStream(j.path));
    }
    public void run(CloudStore.Job j,DriveApi.Input source)throws Exception {
        run(j,source,j.folder);
    }
    public void run(CloudStore.Job j,DriveApi.Input source,String driveFolder)throws Exception {
        if(j.md5==null||j.md5.isEmpty()){String[] hashes=DriveApi.hashes(source,j.size,cancel);if(!hashes[0].equals(j.sha))throw new IOException("本機 SHA-256 已改變，停止上傳");j.md5=hashes[1];}
        j.state="UPLOADING";j.error="";save.save(j);
        if(j.remote.isEmpty()){
            j.remote=api.nextUploadId();
            save.save(j);
        }else{
            // A previous attempt may have finished before the response reached the phone.
            try{complete(j,driveFolder);return;}
            catch(DriveApi.Failure e){if(e.status!=404)throw e;}
        }
        if(cancel.stopped())throw new InterruptedIOException("已暫停");
        if(!j.uri.isEmpty()){
            DriveApi.Reply status=api.probe(j.uri,j.size);
            if(status.status==200||status.status==201){complete(j,driveFolder,status);return;}
            if(status.status==404||status.status==410){j.uri="";j.offset=0;save.save(j);}
            else if(status.status==308){j.offset=DriveApi.acknowledged(status,j.size);save.save(j);}
            else throw DriveApi.failure(status);
        }
        if(j.uri.isEmpty()){
            try{j.uri=api.begin(j.remote,driveFolder,j.name,j.size,j.key,j.sha);j.offset=0;save.save(j);}
            catch(DriveApi.Failure e){if(e.status==409){complete(j,driveFolder);return;}throw e;}
        }
        while(j.offset<j.size){
            if(cancel.stopped())throw new InterruptedIOException("已暫停");long previous=j.offset;
            int count=(int)Math.min(CHUNK_BYTES,j.size-j.offset);
            DriveApi.Reply r;
            long started=System.nanoTime();
            try{r=api.chunk(j.uri,source,j.size,j.offset,count,cancel,progress);}
            finally{j.sendMs=elapsedTotal(j.sendMs,started);}
            if(r.status==200||r.status==201){complete(j,driveFolder,r);return;}
            if(r.status==308){long next=DriveApi.acknowledged(r,j.size);if(next<=previous||next>previous+count)throw new IOException("Drive 上傳進度異常，將重新查詢");j.offset=next;save.save(j);}
            else{if(r.status==404||r.status==410){j.uri="";j.offset=0;save.save(j);throw new IOException("上傳階段已過期，將用相同檔案 ID 重試");}throw DriveApi.failure(r);}
        }
        // A 308 claiming all bytes is not a successful completion response.
        throw new IOException("等待 Drive 完成確認");
    }
    private static long elapsedTotal(long previous,long started){
        return Math.max(0,previous)+(System.nanoTime()-started)/1_000_000L;
    }
    private void complete(CloudStore.Job j,String driveFolder)throws Exception{
        complete(j,driveFolder,null);
    }
    private void complete(CloudStore.Job j,String driveFolder,DriveApi.Reply reply)throws Exception{
        long started=System.nanoTime();
        try{
            JSONObject remote=null;
            if(reply!=null)try{remote=reply.json();}catch(org.json.JSONException ignored){}
            if(remote==null||remote.isNull("id")||remote.isNull("size")||remote.isNull("md5Checksum")
                    ||remote.isNull("sha256Checksum")||remote.isNull("trashed")||remote.optJSONArray("parents")==null)
                remote=api.metadata(j.remote);
            DriveApi.verify(remote,j.remote,driveFolder,j.size,j.md5,j.sha);
        }finally{j.verifyMs=elapsedTotal(j.verifyMs,started);}
        j.offset=j.size;j.state="DONE";j.uri="";j.error="";j.next=0;save.save(j);
    }
}
