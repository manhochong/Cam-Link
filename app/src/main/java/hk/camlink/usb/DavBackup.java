package hk.camlink.usb;

import android.app.job.*;
import android.content.*;
import android.database.*;
import android.database.sqlite.*;
import android.net.Uri;
import android.security.keystore.*;
import android.util.Base64;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.HashSet;
import java.util.Set;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import javax.net.ssl.HttpsURLConnection;

/** Opt-in, independent destination. Never redirects credentials or overwrites a remote original. */
public final class DavBackup extends JobService {
    private static final int JOB=904,SWEEP=905;
    private static final String KEY="camlink.dav.1";
    private volatile Thread worker;
    private static Queue queue;
    static synchronized Queue db(Context c){
        if(queue==null)queue=new Queue(c.getApplicationContext());
        return queue;
    }
    static final class Queue extends SQLiteOpenHelper{
        Queue(Context c){super(c,"dav.db",null,1);}
        public void onCreate(SQLiteDatabase d){d.execSQL("CREATE TABLE items(id INTEGER PRIMARY KEY, profile TEXT, path TEXT, name TEXT, sha TEXT, size INTEGER, state INTEGER DEFAULT 0, UNIQUE(profile,path))");}
        public void onUpgrade(SQLiteDatabase d,int old,int next){throw new IllegalStateException();}
    }
    static SharedPreferences prefs(Context c){return c.getSharedPreferences("dav",MODE_PRIVATE);}
    static String active(Context c){return prefs(c).getString("active","");}
    static SharedPreferences pc(Context c){return c.getSharedPreferences("pc_receiver",MODE_PRIVATE);}
    static SharedPreferences pc2(Context c){return c.getSharedPreferences("pc_receiver_2",MODE_PRIVATE);}
    static SharedPreferences[] pcSlots(Context c){return new SharedPreferences[]{pc(c),pc2(c)};}
    static boolean pcPaired(Context c){for(SharedPreferences slot:pcSlots(c))if(!slot.getString("active","").isEmpty())return true;return false;}
    /** [queued, verified, failed, current] for this session's computer transfers. current is 2 verified, 1 failed, 0 waiting, -1 if that file is not queued. */
    static int[] pcShoot(Context c,File dir,String latest){
        String prefix=new File(dir,"jpg").getAbsolutePath()+File.separator;
        try(Cursor cur=db(c).getReadableDatabase().rawQuery("SELECT COUNT(*),COALESCE(SUM(state=1),0),COALESCE(SUM(state=2),0),COALESCE(MAX(CASE WHEN path=? THEN CASE state WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE 0 END END),-1) FROM items WHERE profile LIKE 'pc:%' AND substr(path,1,?)=?",new String[]{latest==null?"":latest,Integer.toString(prefix.length()),prefix})){
            cur.moveToFirst();return new int[]{cur.getInt(0),cur.getInt(1),cur.getInt(2),cur.getInt(3)};
        }
    }
    static Set<String> storedNames(Context c,String profile){
        Set<String> names=new HashSet<>();
        if(profile==null||profile.isEmpty())return names;
        try(Cursor cur=db(c).getReadableDatabase().rawQuery("SELECT name FROM items WHERE profile=?",new String[]{profile})){
            while(cur.moveToNext())if(cur.getString(0)!=null)names.add(cur.getString(0));
        }
        return names;
    }
    static int[] counts(Context c,File dir,boolean pc){
        String prefix=new File(dir,"jpg").getAbsolutePath()+File.separator;
        try(Cursor cur=db(c).getReadableDatabase().rawQuery("SELECT COUNT(*),COALESCE(SUM(state=1),0) FROM items WHERE substr(path,1,?)=? AND "+(pc?"profile LIKE 'pc:%'":"profile NOT LIKE 'pc:%'"),new String[]{Integer.toString(prefix.length()),prefix})){
            cur.moveToFirst();return new int[]{cur.getInt(0),cur.getInt(1)};
        }
    }
    private static SecretKey key()throws Exception{
        KeyStore ks=KeyStore.getInstance("AndroidKeyStore");ks.load(null);
        if(ks.containsAlias(KEY))return (SecretKey)ks.getKey(KEY,null);
        KeyGenerator gen=KeyGenerator.getInstance("AES","AndroidKeyStore");
        gen.init(new KeyGenParameterSpec.Builder(KEY,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return gen.generateKey();
    }
    static void configure(Context c,String url,String user,String password)throws Exception{
        configure(c,prefs(c),url,user,password,"");
    }
    static void configure(Context c,SharedPreferences slot,String url,String user,String password,String pin)throws Exception{
        URI uri=new URI(url.trim()).normalize();
        if(!"https".equalsIgnoreCase(uri.getScheme())||uri.getHost()==null||uri.getUserInfo()!=null||
                uri.getFragment()!=null||uri.getQuery()!=null||user.contains(":")||user.isEmpty()||password.isEmpty())
            throw new IOException("請填寫 HTTPS 資料夾網址、帳戶及應用程式密碼");
        String base=uri.toASCIIString();if(!base.endsWith("/"))base+="/";
        String profile=DriveApi.hex(MessageDigest.getInstance("SHA-256").digest((base+"\n"+user).getBytes(StandardCharsets.UTF_8)));
        if(!pin.isEmpty())profile="pc:"+pin;
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
        byte[] token=cipher.doFinal((user+":"+password).getBytes(StandardCharsets.UTF_8));
        if(!slot.edit().putString("pin",pin).putString("active",profile).putString("url",base)
            .putString("iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP))
            .putString("secret",Base64.encodeToString(token,Base64.NO_WRAP)).remove("status").commit())throw new IOException("無法保存設定");
        db(c).getWritableDatabase().execSQL("UPDATE items SET state=0 WHERE profile=? AND state=2",new Object[]{profile});
        schedule(c,true);schedule(c,false);
    }
    static String savedPassword(SharedPreferences slot){
        String iv=slot.getString("iv",""),secret=slot.getString("secret","");
        if(iv.isEmpty()||secret.isEmpty())return "";
        try{
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(iv,Base64.DEFAULT)));
            String userPass=new String(cipher.doFinal(Base64.decode(secret,Base64.DEFAULT)),StandardCharsets.UTF_8);
            int colon=userPass.indexOf(':');return colon<0?"":userPass.substring(colon+1);
        }catch(Exception e){return "";}
    }
    static void disable(Context c){disable(c,prefs(c));}
    static void disable(Context c,SharedPreferences slot){
        slot.edit().clear().commit();
        if(enabled(c))return;
        JobScheduler jobs=c.getSystemService(JobScheduler.class);jobs.cancel(JOB);jobs.cancel(SWEEP);
    }
    static void enqueue(Context c,String profile,File source,String name,long size,String sha)throws IOException{
        if(profile.isEmpty())return;
        ContentValues values=new ContentValues();values.put("profile",profile);values.put("path",source.getCanonicalPath());
        values.put("name",name);values.put("size",size);values.put("sha",sha);
        db(c).getWritableDatabase().insertWithOnConflict("items",null,values,SQLiteDatabase.CONFLICT_IGNORE);
        schedule(c,false);
    }
    static void enqueueAllPc(Context c,File source,String name,long size,String sha)throws IOException{
        for(SharedPreferences slot:pcSlots(c))enqueue(c,slot.getString("active",""),source,name,size,sha);
    }
    static int importPcSession(Context c,File dir)throws Exception{
        File root=new File(c.getExternalFilesDir(null),"sessions").getCanonicalFile();
        if(!dir.getCanonicalFile().getPath().startsWith(root.getPath()+File.separator))throw new IOException("Invalid session path");
        if(!pcPaired(c))throw new IOException("尚未配對電腦");
        File photos=new File(dir,"jpg");
        java.util.LinkedHashSet<File> sources=new java.util.LinkedHashSet<>();
        File[] files=photos.listFiles((d,n)->n.toLowerCase(java.util.Locale.ROOT).endsWith(".jpg"));
        if(files!=null)java.util.Collections.addAll(sources,files);
        File[] refs=Gallery.index(dir).listFiles((d,n)->n.toLowerCase(java.util.Locale.ROOT).endsWith(".jpg.json"));
        if(refs!=null)for(File ref:refs)sources.add(new File(photos,ref.getName().substring(0,ref.getName().length()-5)));
        int count=0;
        for(File f:sources){
            String camera=f.getName().replaceFirst("^[0-9]+_","");
            try{
                if(f.exists()){
                    JpegCheck checked=JpegCheck.check(f,f.length());
                    enqueueAllPc(c,f,camera,checked.bytes,checked.sha256);count++;
                }else{
                    org.json.JSONObject ref=Gallery.record(Gallery.marker(f));
                    if(ref.optBoolean("published")){enqueueAllPc(c,f,ref.optString("name",camera),ref.getLong("size"),ref.getString("sha"));count++;}
                }
            }catch(Exception ignored){}
        }
        return count;
    }
    private static synchronized void schedule(Context c,boolean periodic){
        JobScheduler jobs=c.getSystemService(JobScheduler.class);int id=periodic?SWEEP:JOB;
        boolean wifi=pcPaired(c);
        int network=wifi?JobInfo.NETWORK_TYPE_UNMETERED:JobInfo.NETWORK_TYPE_ANY;
        JobInfo existing=jobs.getPendingJob(id);
        if(existing!=null){
            if(periodic||existing.getNetworkType()==network)return;
            jobs.cancel(id);
        }
        JobInfo.Builder job=new JobInfo.Builder(id,new ComponentName(c,DavBackup.class))
            .setRequiredNetworkType(network).setPersisted(true);
        if(periodic)job.setPeriodic(15*60_000);else job.setMinimumLatency(0).setOverrideDeadline(2_000);
        jobs.schedule(job.build());
    }
    // Periodic recovery only wakes the one-shot worker, so two jobs cannot send the same item.
    static boolean enabled(Context c){return !active(c).isEmpty()||pcPaired(c);}
    public boolean onStartJob(JobParameters job){
        if(!enabled(this))return false;
        if(job.getJobId()==SWEEP){schedule(this,false);return false;}
        Thread task=new Thread(()->{
            Thread current=Thread.currentThread();
            boolean retry=false;
            for(SharedPreferences slot:new SharedPreferences[]{pc(this),pc2(this),prefs(this)}){
                try{drain(slot);}catch(Exception e){slot.edit().putString("status",explain(e)).apply();retry=true;DeliveryNotify.issue(this,explain(e));}
            }
            boolean again=retry;
            new android.os.Handler(getMainLooper()).post(()->{if(worker==current){worker=null;jobFinished(job,again);}});
        },"dav-upload");worker=task;task.start();return true;
    }
    public boolean onStopJob(JobParameters job){if(job.getJobId()==JOB)worker=null;return enabled(this);}
    private boolean stopped(){return Thread.currentThread()!=worker;}
    private void drain(SharedPreferences p)throws Exception{
        java.util.Map<String,?> config=p.getAll();
        String profile=(String)config.get("active");
        if(profile==null||!profile.equals(p.getString("active",""))||profile.isEmpty())return;
        String base=(String)config.get("url"),iv=(String)config.get("iv"),secret=(String)config.get("secret");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(iv,Base64.DEFAULT)));
        String auth="Basic "+Base64.encodeToString(cipher.doFinal(Base64.decode(secret,Base64.DEFAULT)),Base64.NO_WRAP);
        SQLiteDatabase database=db(this).getWritableDatabase();
        while(!stopped()&&profile.equals(p.getString("active",""))){
            try(Cursor row=database.rawQuery("SELECT id,path,name,sha,size FROM items WHERE profile=? AND state=0 ORDER BY id LIMIT 1",new String[]{profile})){
                if(!row.moveToFirst())return;
                File file=new File(row.getString(1));
                String name=file.getParentFile().getParentFile().getName()+"_"+file.getName();
                URL target=new URL(base+Uri.encode(name));
                p.edit().putString("status","正在上傳 "+row.getString(2)).apply();
                try{
                    String pin=(String)config.get("pin");
                    android.net.Network network=null;
                    if(pin!=null&&!pin.isEmpty()){
                        network=PcLink.wifi(this);if(network==null)throw new IOException("手機未接上電腦所在的 Wi-Fi");
                    }
                    transfer(target,auth,Gallery.source(this,file),row.getLong(4),row.getString(3),pin,network,
                        ()->stopped()||!profile.equals(p.getString("active","")));
                    database.execSQL("UPDATE items SET state=1 WHERE id=?",new Object[]{row.getLong(0)});
                    p.edit().putString("status","已核對 "+row.getString(2)).apply();
                }catch(Rejected e){
                    p.edit().putString("status",e.getMessage()).apply();
                    database.execSQL("UPDATE items SET state=2 WHERE id=?",new Object[]{row.getLong(0)});
                    DeliveryNotify.issue(this,e.getMessage());
                    return;
                }
            }
        }
    }
    private static String explain(Exception e){
        String msg=e.getMessage()==null?"":e.getMessage();
        if(msg.contains("Wi-Fi")||msg.contains("wifi"))return msg;
        if(msg.contains("憑證")||msg.contains("指紋")||msg.contains("Certificate"))return "指紋不符，請重新配對電腦";
        if(msg.contains("503")||msg.contains("忙"))return "電腦接收器忙碌，稍後重試";
        if(msg.contains("拒絕連線")||msg.contains("Connection refused")||msg.contains("failed to connect")||msg.contains("ECONNREFUSED"))return "接收器未開啟或地址不對";
        if(msg.contains("timeout")||msg.contains("Timeout")||msg.contains("逾時"))return "連線逾時，請確認同一 Wi-Fi 且接收器已開始接收";
        if(msg.isEmpty())return "連線中斷，等候重試";
        return msg;
    }
    private static HttpsURLConnection open(URL url,String method,String auth)throws IOException{
        HttpsURLConnection c=(HttpsURLConnection)url.openConnection();
        c.setInstanceFollowRedirects(false);c.setConnectTimeout(15000);c.setReadTimeout(30000);
        c.setRequestMethod(method);c.setRequestProperty("Authorization",auth);return c;
    }
    private static final class Rejected extends IOException{Rejected(String s){super(s);}}
    private static void check(int code)throws IOException{
        if(code>=200&&code<300)return;
        if(code==503)throw new IOException("電腦接收器忙碌，稍後重試");
        if(code==401)throw new Rejected("配對碼不符，請重新配對");
        if(code==408||code==429||code>=500)throw new IOException("伺服器忙碌 HTTP "+code);
        throw new Rejected("WebDAV HTTP "+code+"，請檢查資料夾及權限後重新儲存設定");
    }
    static void transfer(URL url,String auth,DriveApi.Input source,long size,String sha,
                         java.util.function.BooleanSupplier cancelled)throws Exception{
        transfer(url,auth,source,size,sha,"",null,cancelled);
    }
    static void transfer(URL url,String auth,DriveApi.Input source,long size,String sha,String pin,android.net.Network network,
                         java.util.function.BooleanSupplier cancelled)throws Exception{
        boolean pc=pin!=null&&!pin.isEmpty();
        HttpsURLConnection put;
        if(pc){
            put=PcLink.connection(url,pin,network);put.setInstanceFollowRedirects(false);put.setConnectTimeout(8000);put.setReadTimeout(45000);
            put.setRequestMethod("PUT");put.setRequestProperty("Authorization",auth);put.setRequestProperty("X-CamLink-SHA256",sha);
        }else put=open(url,"PUT",auth);
        try{
            put.setRequestProperty("If-None-Match","*");put.setRequestProperty("Content-Type","image/jpeg");
            put.setFixedLengthStreamingMode(size);put.setDoOutput(true);
            try(InputStream in=source.open();OutputStream out=put.getOutputStream()){
                byte[] block=new byte[131072];int n;while((n=in.read(block))!=-1){
                    if(cancelled.getAsBoolean())throw new InterruptedIOException();
                    out.write(block,0,n);
                }
            }catch(IOException e){int code=put.getResponseCode();if(code!=412){check(code);throw e;}}
            int code=put.getResponseCode();if(code!=412)check(code);
            if(pc){
                if(code==503)throw new IOException("電腦接收器忙碌，稍後重試");
                if(code!=201||!sha.equalsIgnoreCase(put.getHeaderField("X-CamLink-SHA256")))throw new Rejected("電腦未確認原圖，請確認接收器已開始接收");
                return;
            }
        }finally{put.disconnect();}
        HttpsURLConnection get=open(url,"GET",auth);
        try{
            check(get.getResponseCode());
            MessageDigest digest=MessageDigest.getInstance("SHA-256");long length=0;
            try(InputStream in=get.getInputStream()){
                byte[] block=new byte[131072];int n;while((n=in.read(block))!=-1){
                    if(cancelled.getAsBoolean())throw new InterruptedIOException();
                    digest.update(block,0,n);length+=n;if(length>size)break;
                }
            }
            if(length!=size||!sha.equalsIgnoreCase(DriveApi.hex(digest.digest())))throw new Rejected("遠端檔案不符，請檢查同名檔後重新儲存設定");
        }finally{get.disconnect();}
    }
}
