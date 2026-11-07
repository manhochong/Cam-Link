package hk.camlink.usb;

import android.content.*;
import android.database.*;
import android.database.sqlite.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;

/** Local durable queue; a destination is immutable once enqueued. */
public final class CloudStore extends SQLiteOpenHelper {
    private static CloudStore instance;
    public static synchronized CloudStore get(Context c){if(instance==null)instance=new CloudStore(c.getApplicationContext());return instance;}
    private final Context context;
    private CloudStore(Context c){super(c,"cloud.db",null,2);context=c;setWriteAheadLoggingEnabled(true);}
    public void onCreate(SQLiteDatabase db){db.execSQL("CREATE TABLE uploads (key TEXT PRIMARY KEY,path TEXT NOT NULL,name TEXT NOT NULL,session TEXT NOT NULL,size INTEGER NOT NULL,sha TEXT NOT NULL,md5 TEXT NOT NULL DEFAULT '',account TEXT NOT NULL,email TEXT NOT NULL,folder TEXT NOT NULL,remote TEXT NOT NULL DEFAULT '',uri TEXT NOT NULL DEFAULT '',offset INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL DEFAULT 'WAITING',attempts INTEGER NOT NULL DEFAULT 0,next INTEGER NOT NULL DEFAULT 0,error TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL,queue_ms INTEGER NOT NULL DEFAULT -1,send_ms INTEGER NOT NULL DEFAULT -1,verify_ms INTEGER NOT NULL DEFAULT -1)");db.execSQL("CREATE INDEX pending ON uploads(account,state,next,created)");}
    public void onUpgrade(SQLiteDatabase db,int from,int to){
        if(from!=1||to!=2)throw new IllegalStateException("Unsupported queue migration");
        for(String column:new String[]{"queue_ms","send_ms","verify_ms"})
            db.execSQL("ALTER TABLE uploads ADD COLUMN "+column+" INTEGER NOT NULL DEFAULT -1");
        // A legacy job may have started before the upgrade. Its first dispatch is unknown.
        db.execSQL("UPDATE uploads SET queue_ms=-2 WHERE state!='WAITING' OR attempts>0 OR remote!=''");
    }
    @Override public void onOpen(SQLiteDatabase db){
        super.onOpen(db);
        db.execSQL("CREATE INDEX IF NOT EXISTS shoot_uploads ON uploads(session,account,folder,path)");
    }
    public static SharedPreferences prefs(Context c){return c.getSharedPreferences("cloud",Context.MODE_PRIVATE);}
    public static final class Job {
        public String key,path,name,session,sha,md5,account,email,folder,remote,uri,state,error;public long size,offset,next;public int attempts;
        long created,queueMs=-1,sendMs=-1,verifyMs=-1;
        static Job from(Cursor c){Job j=new Job();j.key=s(c,"key");j.path=s(c,"path");j.name=s(c,"name");j.session=s(c,"session");j.sha=s(c,"sha");j.md5=s(c,"md5");j.account=s(c,"account");j.email=s(c,"email");j.folder=s(c,"folder");j.remote=s(c,"remote");j.uri=s(c,"uri");j.state=s(c,"state");j.error=s(c,"error");j.size=c.getLong(c.getColumnIndexOrThrow("size"));j.offset=c.getLong(c.getColumnIndexOrThrow("offset"));j.next=c.getLong(c.getColumnIndexOrThrow("next"));j.attempts=c.getInt(c.getColumnIndexOrThrow("attempts"));j.created=c.getLong(c.getColumnIndexOrThrow("created"));j.queueMs=c.getLong(c.getColumnIndexOrThrow("queue_ms"));j.sendMs=c.getLong(c.getColumnIndexOrThrow("send_ms"));j.verifyMs=c.getLong(c.getColumnIndexOrThrow("verify_ms"));return j;}
        private static String s(Cursor c,String col){return c.getString(c.getColumnIndexOrThrow(col));}
    }
    public JSONObject destination()throws Exception {
        SharedPreferences p=prefs(context);String account=p.getString("account",""),folder=p.getString("folder","");
        if(!p.getBoolean("enabled",false)||account.isEmpty())return null;
        return new JSONObject().put("account",account).put("email",p.getString("email","")).put("folder",folder)
                .put("folder_name",p.getString("folder_name",""));
    }
    public JSONObject bindSession(File dir,String eventName)throws Exception {
        JSONObject dest=EventFolder.bind(dir,destination(),eventName);if(dest!=null){android.util.AtomicFile target=new android.util.AtomicFile(new File(dir,"cloud-target.json"));FileOutputStream out=null;
            try{out=target.startWrite();out.write(dest.toString().getBytes(StandardCharsets.UTF_8));target.finishWrite(out);}catch(Exception e){if(out!=null)target.failWrite(out);throw e;}}
        return dest;
    }
    public synchronized boolean enqueue(File file,String original,String session,long size,String sha,JSONObject dest)throws Exception {
        return enqueue(file,original,session,size,sha,"",dest);
    }
    public synchronized boolean enqueue(File file,String original,String session,long size,String sha,String md5,JSONObject dest)throws Exception {
        if(dest==null)return false;String canonical=file.getCanonicalPath();
        String key=DriveApi.hex(java.security.MessageDigest.getInstance("SHA-256").digest((canonical+"\n"+dest.getString("account")+"\n"+dest.getString("folder")).getBytes(StandardCharsets.UTF_8)));
        ContentValues v=new ContentValues();v.put("key",key);v.put("path",canonical);v.put("name",original);v.put("session",session);v.put("size",size);v.put("sha",sha);v.put("md5",md5==null?"":md5);v.put("account",dest.getString("account"));v.put("email",dest.getString("email"));v.put("folder",dest.getString("folder"));v.put("created",System.currentTimeMillis());
        return getWritableDatabase().insertWithOnConflict("uploads",null,v,SQLiteDatabase.CONFLICT_IGNORE)!=-1;
    }
    public synchronized void save(Job j){ContentValues v=new ContentValues();v.put("queue_ms",j.queueMs);v.put("send_ms",j.sendMs);v.put("verify_ms",j.verifyMs);v.put("remote",j.remote);v.put("uri",j.uri);v.put("md5",j.md5);v.put("offset",j.offset);v.put("state",j.state);v.put("attempts",j.attempts);v.put("next",j.next);v.put("error",j.error);int count=getWritableDatabase().update("uploads",v,"key=?",new String[]{j.key});if(count!=1)throw new IllegalStateException("Upload queue update lost");}
    public Job next(String account){return nextExcept(account,"");}
    void markStarted(Job job){
        if(job.queueMs!=-1)return;
        long wait=System.currentTimeMillis()-job.created;
        job.queueMs=wait<0?-2:wait;
        save(job);
    }
    public synchronized Job nextExcept(String account,String activeKey){
        String where="account=? AND key!=? AND state IN ('WAITING','UPLOADING','RETRY') AND next<=?";
        String[] args={account,activeKey,Long.toString(System.currentTimeMillis())};
        String order=CaptureService.running?"created DESC":"created ASC";
        try(Cursor rows=getReadableDatabase().query("uploads",null,where,args,null,null,order,"1")){
            return rows.moveToFirst()?Job.from(rows):null;
        }
    }
    public synchronized boolean pending(String account){try(Cursor c=getReadableDatabase().rawQuery("SELECT COUNT(*) FROM uploads WHERE account=? AND (state IN ('WAITING','UPLOADING','RETRY') OR (state='ERROR' AND error LIKE '%notFound%'))",new String[]{account})){c.moveToFirst();return c.getInt(0)>0;}}
    /** Point photos that failed because the folder is gone at a folder this app can write. */
    public synchronized int retargetFolder(String account,String oldFolder,String newFolder){
        if(account.isEmpty()||oldFolder.isEmpty()||newFolder.isEmpty()||oldFolder.equals(newFolder))return 0;
        ContentValues v=new ContentValues();
        v.put("folder",newFolder);v.put("state","WAITING");v.put("attempts",0);v.put("next",0);v.put("error","");v.put("uri","");
        return getWritableDatabase().update("uploads",v,"account=? AND folder=? AND state!='DONE'",new String[]{account,oldFolder});
    }
    public synchronized int reviveMissingFolder(String account){
        if(account.isEmpty())return 0;
        ContentValues v=new ContentValues();
        v.put("state","WAITING");v.put("attempts",0);v.put("next",0);
        return getWritableDatabase().update("uploads",v,"account=? AND state='ERROR' AND error LIKE '%notFound%'",new String[]{account});
    }
    public synchronized Set<String> storedNames(String account){
        Set<String> names=new HashSet<>();if(account==null||account.isEmpty())return names;
        try(Cursor c=getReadableDatabase().rawQuery("SELECT name FROM uploads WHERE account=?",new String[]{account})){while(c.moveToNext())names.add(c.getString(0));}
        return names;
    }
    public boolean hasUnfinished(String account){
        try(Cursor rows=getReadableDatabase().rawQuery("SELECT 1 FROM uploads WHERE account=? AND state!='DONE' LIMIT 1",new String[]{account})){
            return rows.moveToFirst();
        }
    }
    public synchronized void retry(String account){ContentValues v=new ContentValues();v.put("state","WAITING");v.put("attempts",0);v.put("next",0);v.put("error","");getWritableDatabase().update("uploads",v,"account=? AND state IN ('ERROR','AUTH','RETRY')",new String[]{account});}
    private static final String FAILED_SHOOT="session=? AND state IN ('ERROR','AUTH')";
    Cursor shootFailures(String session,String account,String folder){
        boolean bound=!folder.isEmpty();
        return getReadableDatabase().query("uploads",new String[]{"name","state","error","account","email"},
                FAILED_SHOOT+(bound?" AND account=? AND folder=?":""),
                bound?new String[]{session,account,folder}:new String[]{session},null,null,"created ASC, key ASC");
    }
    synchronized int retryShoot(String session,String account,String folder){
        if(account.isEmpty()||session.isEmpty())return 0;
        ContentValues values=new ContentValues();
        values.put("state","WAITING");values.put("attempts",0);values.put("next",0);values.put("error","");
        boolean bound=!folder.isEmpty();
        return getWritableDatabase().update("uploads",values,FAILED_SHOOT+" AND account=?"+(bound?" AND folder=?":""),
                bound?new String[]{session,account,folder}:new String[]{session,account});
    }
    public synchronized Map<String,Integer> counts(String account){
        Map<String,Integer> rows=new HashMap<>();
        try(Cursor c=getReadableDatabase().rawQuery("SELECT state,COUNT(*) FROM uploads WHERE account=? GROUP BY state",new String[]{account})){
            while(c.moveToNext())rows.put(c.getString(0),c.getInt(1));
        }
        return rows;
    }
    /** Each received original counts once, including when manually sent to two folders. */
    int[] shootCounts(String session,String latest,String account,String folder){
        String filter=account.isEmpty()?"":" AND account=? AND folder=?";
        String[] args=account.isEmpty()?new String[]{latest,session}:new String[]{latest,session,account,folder};
        String sql="SELECT COUNT(*),COALESCE(SUM(stage=2),0),COALESCE(SUM(stage=1),0),"+
                "COALESCE(MAX(CASE WHEN path=? THEN stage ELSE 0 END),0) FROM "+
                "(SELECT path,MAX(CASE WHEN state='DONE' THEN 2 WHEN state IN ('AUTH','ERROR') THEN 1 ELSE 0 END) stage "+
                "FROM uploads WHERE session=?"+filter+" GROUP BY path)";
        try(Cursor row=getReadableDatabase().rawQuery(sql,args)){
            row.moveToFirst();
            return new int[]{row.getInt(0),row.getInt(1),row.getInt(2),row.getInt(3)};
        }
    }
    public synchronized String recent(String account){StringBuilder s=new StringBuilder();try(Cursor c=getReadableDatabase().query("uploads",new String[]{"name","state","offset","size","error"},"account=?",new String[]{account},null,null,"created DESC","25")){while(c.moveToNext()){s.append(c.getString(0)).append(" · ").append(label(c.getString(1))).append(" · ").append(c.getLong(2)*100/Math.max(1,c.getLong(3))).append("%\n");if(!c.getString(4).isEmpty())s.append(c.getString(4)).append('\n');}}return s.toString();}
    public static String label(String s){switch(s){case "DONE":return "雲端已核對";case "UPLOADING":return "上傳中";case "ERROR":return "失敗";case "AUTH":return "需登入";case "RETRY":return "等待重試";default:return "待上傳";}}
    public int recover(DriveApi.Cancel cancel)throws Exception {
        File root=new File(context.getExternalFilesDir(null),"sessions");File[] dirs=root.listFiles(File::isDirectory);int count=0;
        String warning="";
        if(dirs!=null)for(File dir:dirs){if(cancel.stopped())break;File target=new File(dir,"cloud-target.json");if(target.isFile())try{JSONObject dest=new JSONObject(new String(new android.util.AtomicFile(target).readFully(),StandardCharsets.UTF_8));count+=importSession(dir,dest,cancel);}catch(Exception e){warning="部分本機照片未能補回佇列："+dir.getName()+"；請保留原檔並檢查這輪紀錄";}}
        if(!cancel.stopped())prefs(context).edit().putString("recovery_warning",warning).apply();return count;
    }
    public int importSession(File dir,JSONObject dest,DriveApi.Cancel cancel)throws Exception {
        File root=new File(context.getExternalFilesDir(null),"sessions").getCanonicalFile();if(!dir.getCanonicalPath().startsWith(root.getPath()+File.separator))throw new IOException("Invalid session path");
        File photos=new File(dir,"jpg");
        Set<File> sources=new LinkedHashSet<>();
        File[] files=photos.listFiles((d,n)->n.toLowerCase(Locale.ROOT).endsWith(".jpg"));
        if(files!=null)Collections.addAll(sources,files);
        File[] refs=Gallery.index(dir).listFiles((d,n)->n.toLowerCase(Locale.ROOT).endsWith(".jpg.json"));
        if(refs!=null)for(File ref:refs)sources.add(new File(photos,ref.getName().substring(0,ref.getName().length()-5)));
        int count=0;
        for(File f:sources){if(cancel.stopped())break;
            try(Cursor c=getReadableDatabase().rawQuery("SELECT key FROM uploads WHERE path=? AND account=? AND folder=?",new String[]{f.getCanonicalPath(),dest.getString("account"),dest.getString("folder")})){if(c.moveToFirst())continue;}
            if(!f.exists()){
                JSONObject ref=Gallery.record(Gallery.marker(f));
                if(ref.optBoolean("published")&&enqueue(f,ref.getString("name"),dir.getName(),ref.getLong("size"),ref.getString("sha"),dest))count++;
            }else{
                JpegCheck checked=JpegCheck.check(f,f.length());String name=f.getName().replaceFirst("^[0-9]+_","");
                if(enqueue(f,name,dir.getName(),checked.bytes,checked.sha256,checked.md5,dest))count++;
            }
        }return count;
    }
    public synchronized void export(OutputStream out)throws Exception {
        // Deliberately omit token, resumable URI, local absolute paths and account email.
        JSONArray rows=new JSONArray();try(Cursor c=getReadableDatabase().query("uploads",null,null,null,null,null,"created")){while(c.moveToNext()){Job j=Job.from(c);rows.put(new JSONObject().put("session",j.session).put("name",j.name).put("size",j.size).put("sha256",j.sha).put("state",j.state).put("remote_id",j.remote).put("uploaded_bytes",j.offset).put("error",j.error));}}
        out.write(new JSONObject().put("schema",1).put("files",rows).toString(2).getBytes(StandardCharsets.UTF_8));
    }
}
