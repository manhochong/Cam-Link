package hk.camlink.usb;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import org.json.JSONObject;

/** Separate from the Google queue so a OneDrive job is never sent to Drive. */
final class OneDriveStore extends SQLiteOpenHelper {
    private static OneDriveStore instance;
    static synchronized OneDriveStore get(Context c){ if(instance==null) instance=new OneDriveStore(c.getApplicationContext()); return instance; }
    private OneDriveStore(Context c){ super(c,"onedrive.db",null,1); setWriteAheadLoggingEnabled(true); }
    public void onCreate(SQLiteDatabase db){ db.execSQL("CREATE TABLE items (key TEXT PRIMARY KEY,path TEXT NOT NULL,name TEXT NOT NULL,session TEXT NOT NULL,size INTEGER NOT NULL,sha TEXT NOT NULL,account TEXT NOT NULL,folder TEXT NOT NULL,remote TEXT NOT NULL DEFAULT '',uri TEXT NOT NULL DEFAULT '',offset INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL DEFAULT 'WAITING',attempts INTEGER NOT NULL DEFAULT 0,next INTEGER NOT NULL DEFAULT 0,error TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL)"); }
    public void onUpgrade(SQLiteDatabase db,int from,int to){ throw new IllegalStateException("Unsupported OneDrive queue"); }
    static final class Job {
        String key,path,name,session,sha,account,folder,remote,uri,state,error; long size,offset,next; int attempts;
        static Job from(Cursor c){ Job j=new Job(); j.key=s(c,"key"); j.path=s(c,"path"); j.name=s(c,"name"); j.session=s(c,"session"); j.sha=s(c,"sha"); j.account=s(c,"account"); j.folder=s(c,"folder"); j.remote=s(c,"remote"); j.uri=s(c,"uri"); j.state=s(c,"state"); j.error=s(c,"error"); j.size=c.getLong(c.getColumnIndexOrThrow("size")); j.offset=c.getLong(c.getColumnIndexOrThrow("offset")); j.next=c.getLong(c.getColumnIndexOrThrow("next")); j.attempts=c.getInt(c.getColumnIndexOrThrow("attempts")); return j; }
        private static String s(Cursor c,String col){ return c.getString(c.getColumnIndexOrThrow(col)); }
    }
    synchronized boolean enqueue(File file,String name,String session,long size,String sha,JSONObject dest) throws Exception {
        if(dest==null) return false;
        String folder=dest.getString("folder");
        if(folder.isEmpty()) folder="name:"+dest.getString("eventName");
        String canonical=file.getCanonicalPath();
        String key=DriveApi.hex(MessageDigest.getInstance("SHA-256").digest((canonical+"\n"+dest.getString("account")+"\n"+folder).getBytes(StandardCharsets.UTF_8)));
        ContentValues v=new ContentValues(); v.put("key",key); v.put("path",canonical); v.put("name",name); v.put("session",session); v.put("size",size); v.put("sha",sha); v.put("account",dest.getString("account")); v.put("folder",folder); v.put("created",System.currentTimeMillis());
        return getWritableDatabase().insertWithOnConflict("items",null,v,SQLiteDatabase.CONFLICT_IGNORE)>0;
    }
    synchronized Job next(String account){
        String order=CaptureService.running?"created DESC":"created";
        try(Cursor c=getReadableDatabase().query("items",null,"account=? AND state IN ('WAITING','UPLOADING','RETRY') AND next<=?",new String[]{account,Long.toString(System.currentTimeMillis())},null,null,order,"1")){
            return c.moveToFirst()?Job.from(c):null;
        }
    }
    synchronized boolean pending(String account){ try(Cursor c=getReadableDatabase().rawQuery("SELECT COUNT(*) FROM items WHERE account=? AND (state IN ('WAITING','UPLOADING','RETRY') OR (state='ERROR' AND (error LIKE '%itemNotFound%' OR error LIKE '%notFound%' OR error LIKE '%資料夾不存在%')))",new String[]{account})){ c.moveToFirst(); return c.getInt(0)>0; } }
    synchronized int reviveMissingFolder(String account){
        if(account==null||account.isEmpty()) return 0;
        ContentValues v=new ContentValues(); v.put("state","WAITING"); v.put("attempts",0); v.put("next",0);
        return getWritableDatabase().update("items",v,"account=? AND state='ERROR' AND (error LIKE '%itemNotFound%' OR error LIKE '%notFound%' OR error LIKE '%資料夾不存在%')",new String[]{account});
    }
    synchronized int retargetFolder(String account,String oldFolder,String newFolder){
        if(account==null||account.isEmpty()||oldFolder==null||oldFolder.isEmpty()||newFolder==null||newFolder.isEmpty()||oldFolder.equals(newFolder)) return 0;
        ContentValues v=new ContentValues(); v.put("folder",newFolder); v.put("state","WAITING"); v.put("attempts",0); v.put("next",0); v.put("error",""); v.put("uri",""); v.put("offset",0);
        return getWritableDatabase().update("items",v,"account=? AND folder=? AND state!='DONE'",new String[]{account,oldFolder});
    }
    synchronized boolean unfinished(String account){ try(Cursor c=getReadableDatabase().rawQuery("SELECT 1 FROM items WHERE account=? AND state!='DONE' LIMIT 1",new String[]{account})){ return c.moveToFirst(); } }
    synchronized Set<String> storedNames(String account){
        Set<String> names=new HashSet<>(); if(account==null||account.isEmpty()) return names;
        try(Cursor c=getReadableDatabase().rawQuery("SELECT name FROM items WHERE account=?",new String[]{account})){ while(c.moveToNext()) names.add(c.getString(0)); }
        return names;
    }
    synchronized String shootIssue(String session){
        try(Cursor c=getReadableDatabase().rawQuery("SELECT error FROM items WHERE session=? AND state IN ('ERROR','AUTH') AND error!='' ORDER BY created DESC LIMIT 1",new String[]{session==null?"":session})){
            return c.moveToFirst()&&c.getString(0)!=null?c.getString(0):"";
        }
    }
    /** [queued, verified, failed, current]. current is 2 verified, 1 failed, 0 waiting, -1 if that file is not queued. */
    synchronized int[] shoot(String session,String latest){
        try(Cursor cur=getReadableDatabase().rawQuery("SELECT COUNT(*),COALESCE(SUM(state='DONE'),0),COALESCE(SUM(state IN ('ERROR','AUTH')),0),COALESCE(MAX(CASE WHEN path=? THEN CASE WHEN state='DONE' THEN 2 WHEN state IN ('ERROR','AUTH') THEN 1 ELSE 0 END END),-1) FROM items WHERE session=?",new String[]{latest==null?"":latest,session==null?"":session})){
            cur.moveToFirst();return new int[]{cur.getInt(0),cur.getInt(1),cur.getInt(2),cur.getInt(3)};
        }
    }
    synchronized Map<String,Integer> counts(String account){
        Map<String,Integer> out=new HashMap<>();
        try(Cursor c=getReadableDatabase().rawQuery("SELECT state,COUNT(*) FROM items WHERE account=? GROUP BY state",new String[]{account})){ while(c.moveToNext()) out.put(c.getString(0),c.getInt(1)); }
        return out;
    }
    synchronized String recent(String account){
        StringBuilder s=new StringBuilder();
        try(Cursor c=getReadableDatabase().query("items",new String[]{"name","state","offset","size","error"},"account=?",new String[]{account},null,null,"created DESC","25")){
            while(c.moveToNext()){ s.append(c.getString(0)).append(" · ").append(CloudStore.label(c.getString(1))).append(" · ").append(c.getLong(2)*100/Math.max(1,c.getLong(3))).append("%\n"); if(!c.getString(4).isEmpty()) s.append(c.getString(4)).append('\n'); }
        }
        return s.toString();
    }
    synchronized void retry(String account){ ContentValues v=new ContentValues(); v.put("state","WAITING"); v.put("attempts",0); v.put("next",0); v.put("error",""); getWritableDatabase().update("items",v,"account=? AND state IN ('ERROR','AUTH','RETRY')",new String[]{account}); }
    synchronized void save(Job j){
        ContentValues v=new ContentValues(); v.put("remote",j.remote); v.put("uri",j.uri); v.put("offset",j.offset); v.put("state",j.state); v.put("attempts",j.attempts); v.put("next",j.next); v.put("error",j.error==null?"":j.error);
        getWritableDatabase().update("items",v,"key=?",new String[]{j.key});
    }
    int importSession(Context context,File dir,JSONObject dest) throws Exception {
        File photos=new File(dir,"jpg"); File[] files=photos.listFiles((d,n)->n.toLowerCase(Locale.ROOT).endsWith(".jpg")); int count=0;
        if(files!=null) for(File f:files){ JpegCheck checked=JpegCheck.check(f,f.length()); String name=f.getName().replaceFirst("^[0-9]+_",""); if(enqueue(f,name,dir.getName(),checked.bytes,checked.sha256,dest)) count++; }
        File[] refs=Gallery.index(dir).listFiles((d,n)->n.toLowerCase(Locale.ROOT).endsWith(".jpg.json"));
        if(refs!=null) for(File ref:refs){
            File f=new File(photos,ref.getName().substring(0,ref.getName().length()-5)); if(f.exists()) continue;
            JSONObject saved=Gallery.record(ref); if(saved.optBoolean("published")&&enqueue(f,saved.getString("name"),dir.getName(),saved.getLong("size"),saved.getString("sha"),dest)) count++;
        }
        return count;
    }
}
