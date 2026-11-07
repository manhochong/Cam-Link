package hk.camlink.usb;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.net.*;
import android.os.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;

public final class UploadService extends Service {
    public static volatile boolean running;public static volatile String status="尚未啟用上傳",current="";
    public static volatile long sent,started;private volatile boolean stopped;private PowerManager.WakeLock wake;
    private CloudNetwork internet;
    public static void start(Context c){try{c.startForegroundService(new Intent(c,UploadService.class));}catch(Exception e){status="上傳待恢復：請返回 App 按繼續";}}
    public static void pause(Context c){CloudStore.prefs(c).edit().putBoolean("paused",true).apply();status="已暫停 · 本機原檔保留";}
    static String resumeAccount(Context context){
        SharedPreferences settings=CloudStore.prefs(context);
        if(settings.getBoolean("paused",false)||!settings.getBoolean("enabled",false))return "";
        return settings.getString("account","");
    }
    @Override public IBinder onBind(Intent i){return null;}
    @Override public int onStartCommand(Intent intent,int flags,int startId){
        if(intent==null){stopSelf();return START_NOT_STICKY;}
        if("PAUSE".equals(intent.getAction())){pause(this);return START_NOT_STICKY;}
        if(running)return START_NOT_STICKY;
        NotificationManager nm=getSystemService(NotificationManager.class);nm.createNotificationChannel(new NotificationChannel("upload","Google Drive 上傳",NotificationManager.IMPORTANCE_LOW));
        PendingIntent open=PendingIntent.getActivity(this,3,new Intent(this,CloudActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        PendingIntent pause=PendingIntent.getService(this,4,new Intent(this,UploadService.class).setAction("PAUSE"),PendingIntent.FLAG_IMMUTABLE);
        Notification n=new Notification.Builder(this,"upload").setSmallIcon(R.drawable.ic_camera).setContentTitle("Cam Link · Google Drive")
            .setContentText("接收原圖後自動上傳 · 點按查看佇列").setContentIntent(open).setOngoing(true).addAction(new Notification.Action.Builder(null,"暫停",pause).build()).build();
        try{startForeground(2,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);wake=getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"camlink:upload");wake.acquire(6*60*60*1000L);}
        catch(Exception e){status="無法啟動上傳服務，請回 App 重試";stopSelf();return START_NOT_STICKY;}
        running=true;stopped=false;needsLogin=false;sent=0;started=SystemClock.elapsedRealtime();new Thread(this::work,"drive-upload").start();return START_NOT_STICKY;
    }
    private boolean cancelled(){return stopped||CloudStore.prefs(this).getBoolean("paused",false);}
    private boolean network(){return internet!=null&&internet.available();}
    private volatile boolean needsLogin;
    private synchronized void countSent(long bytes){sent+=bytes;}

    private String apiAccount="",apiEmail="",readyFolder="";
    private DriveApi accountApi;
    private synchronized DriveApi apiFor(String account,String email){
        if(accountApi==null||!account.equals(apiAccount)||!email.equals(apiEmail)){
            accountApi=new DriveApi(()->CloudAuth.token(this,account,email,internet),internet);
            apiAccount=account;apiEmail=email;
        }
        return accountApi;
    }
    private String ensureFolder(CloudStore db,CloudStore.Job job,DriveApi api)throws Exception{
        if(job.folder.startsWith("event:"))return job.folder;
        synchronized(this){
            if(job.folder.equals(readyFolder))return readyFolder;
            try{api.checkFolder(job.folder);readyFolder=job.folder;return readyFolder;}
            catch(DriveApi.Failure e){if(e.status!=404)throw e;}
            String saved=CloudStore.prefs(this).getString("folder","");
            if(!saved.isEmpty()&&!saved.equals(job.folder))try{api.checkFolder(saved);db.retargetFolder(job.account,job.folder,saved);job.folder=saved;readyFolder=saved;return saved;}
            catch(DriveApi.Failure e){if(e.status!=404)throw e;}
            String name=CloudStore.prefs(this).getString("folder_name","").trim();
            if(name.isEmpty())name="Cam Link";
            String id=api.generateId();
            try{api.createFolder(name,id);}catch(DriveApi.Failure e){if(e.status!=409)throw e;}
            api.checkFolder(id);
            CloudStore.prefs(this).edit().putString("folder",id).putString("folder_name",name).commit();
            String old=job.folder;
            db.retargetFolder(job.account,old,id);
            job.folder=id;readyFolder=id;
            status="原資料夾已不存在，已建立「"+name+"」並繼續上傳";
            return id;
        }
    }
    private void upload(CloudStore db,CloudStore.Job j){
        try{
            long fileStarted=SystemClock.elapsedRealtime();
            db.markStarted(j);
            boolean fresh=j.remote.isEmpty();
            DriveApi api=apiFor(j.account,j.email);
            j.folder=ensureFolder(db,j,api);
            File session=new File(new File(getExternalFilesDir(null),"sessions"),j.session);
            String driveFolder=EventFolder.resolve(session,j.account,j.folder,api);
            new UploadEngine(api,db::save,()->cancelled()||!network()||!j.account.equals(CloudStore.prefs(this).getString("account","")),this::countSent).run(j,Gallery.source(this,new File(j.path)),driveFolder);
            if(fresh){
                double seconds=Math.max(1,SystemClock.elapsedRealtime()-fileStarted)/1000.0;
                String timing=String.format(Locale.US,"%s　%.1f 秒（%.2f MB/s）",j.name,seconds,j.size/1e6/seconds);
                CloudStore.prefs(this).edit().putString("last_file_rate_"+j.account,timing).apply();
            }
        }catch(Exception e){
            j.error=safeError(e);
            if(cancelled()||needsLogin||e instanceof CloudNetwork.Waiting||e instanceof InterruptedIOException&&!network()){
                j.state="WAITING";j.next=0;
            }
            else{
                j.attempts++;
                if(e instanceof CloudAuth.LoginRequired||e instanceof DriveApi.Failure&&((DriveApi.Failure)e).status==401){
                    needsLogin=true;
                    CloudAuth.invalidate(this);
                    j.state="AUTH";j.next=0;
                }else if(e instanceof DriveApi.Failure&&!((DriveApi.Failure)e).retryable||j.attempts>=8){
                    j.state="ERROR";j.next=0;
                }else{
                    j.state="RETRY";j.next=System.currentTimeMillis()+Math.min(300000L,2000L*(1L<<Math.min(7,j.attempts)))+(long)(Math.random()*1000);
                }
            }
            db.save(j);
        }
    }

    private void work(){
        internet=new CloudNetwork(this);
        CloudStore db=CloudStore.get(this);
        ExecutorService pool=Executors.newFixedThreadPool(2);
        // Only this dispatcher selects jobs. An in-flight key stays reserved until its worker exits.
        Map<String,Future<?>> active=new LinkedHashMap<>();
        Thread recovery=new Thread(()->{try{db.recover(this::cancelled);}catch(Exception ignored){}},"drive-recover");
        recovery.setDaemon(true);recovery.start();
        try{
            db.reviveMissingFolder(CloudStore.prefs(this).getString("account",""));
            while(!cancelled()&&!needsLogin){
                for(Iterator<Future<?>> it=active.values().iterator();it.hasNext();){
                    Future<?> task=it.next();
                    if(task.isDone()){task.get();it.remove();}
                }
                if(SystemClock.elapsedRealtime()-started>5*60*60*1000L+50*60*1000L){status="已到背景上傳時限，請回 App 按繼續";break;}
                String account=CloudStore.prefs(this).getString("account","");
                if(account.isEmpty()){status="請先登入 Google Drive";break;}
                if(active.isEmpty()&&!db.pending(account)&&!CaptureService.running&&!recovery.isAlive()){
                    if(SystemClock.elapsedRealtime()-started<2000){Thread.sleep(250);continue;}
                    status="目前佇列已處理完畢；請查看是否有失敗項目";break;
                }
                if(!network()){status=internet.label();Thread.sleep(500);continue;}
                int limit=internet.wifi()?2:1;
                if(active.size()<limit){
                    String reserved=active.isEmpty()?"":active.keySet().iterator().next();
                    CloudStore.Job job=db.nextExcept(account,reserved);
                    if(job!=null){
                        current=job.name;active.put(job.key,pool.submit(()->upload(db,job)));
                        status=(active.size()==2?"正在上傳 2 張照片":"正在上傳 "+job.name)+" · "+internet.label();
                        continue;
                    }
                }
                status=(active.isEmpty()?"等待新 JPG 或重試時間":"正在上傳 "+active.size()+" 張照片")+" · "+internet.label();
                Thread.sleep(200);
            }
            if(needsLogin)status="請重新登入 Google Drive";
            else if(cancelled())status="已暫停 · 佇列及原檔保留";
        }catch(Exception e){status="上傳暫停："+safeError(e);}
        finally{
            stopped=true;boolean interrupted=false;
            try{recovery.join(3000);}catch(InterruptedException e){interrupted=true;}
            pool.shutdown();
            while(!pool.isTerminated()){
                try{pool.awaitTermination(1,TimeUnit.SECONDS);}
                catch(InterruptedException e){interrupted=true;}
            }
            internet.close();current="";if(wake!=null&&wake.isHeld())wake.release();
            running=false;stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();
            if(interrupted)Thread.currentThread().interrupt();
        }
    }
    static String safeError(Exception e){if(e instanceof DriveApi.Failure||e instanceof CloudAuth.LoginRequired)return e.getMessage();String s=e.getMessage();if(s==null||s.contains("https:")||s.contains("Bearer"))return "網絡或服務錯誤，請重試";return s.length()>180?s.substring(0,180):s;}
    @Override public void onTimeout(int startId,int fgsType){stopped=true;status="Android 已暫停背景上傳，重開 App 可繼續";stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
    @Override public void onDestroy(){stopped=true;super.onDestroy();}
}
