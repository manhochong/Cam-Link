package hk.camlink.usb;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.net.*;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;
import java.io.InterruptedIOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;

/** Uploads the OneDrive queue. It never opens the OneDrive app. */
public final class OneDriveService extends Service {
    public static volatile boolean running; public static volatile String status="尚未啟用 OneDrive";
    private volatile boolean stopped; private PowerManager.WakeLock wake; private ConnectivityManager.NetworkCallback cellular;
    private final java.util.HashMap<String,String> folderIds=new java.util.HashMap<>();
    public static void start(Context c){ try{ c.startForegroundService(new Intent(c,OneDriveService.class)); }catch(Exception e){ status="OneDrive 上傳待恢復：請返回 App 按繼續"; } }
    public static void pause(Context c){ OneDriveAuth.prefs(c).edit().putBoolean("paused",true).apply(); status="OneDrive 已暫停 · 本機原檔保留"; }
    @Override public IBinder onBind(Intent i){ return null; }
    @Override public int onStartCommand(Intent intent,int flags,int startId){
        if(intent==null){ stopSelf(); return START_NOT_STICKY; }
        if("PAUSE".equals(intent.getAction())){ pause(this); stopped=true; return START_NOT_STICKY; }
        if(running) return START_NOT_STICKY;
        NotificationManager nm=getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("onedrive","OneDrive 上傳",NotificationManager.IMPORTANCE_LOW));
        PendingIntent open=PendingIntent.getActivity(this,8,new Intent(this,OneDriveActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        PendingIntent pause=PendingIntent.getService(this,9,new Intent(this,OneDriveService.class).setAction("PAUSE"),PendingIntent.FLAG_IMMUTABLE);
        Notification n=new Notification.Builder(this,"onedrive").setSmallIcon(R.drawable.ic_camera).setContentTitle("Cam Link · OneDrive")
            .setContentText("接收原圖後自動上傳").setContentIntent(open).setOngoing(true).addAction(new Notification.Action.Builder(null,"暫停",pause).build()).build();
        try{ startForeground(5,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC); wake=getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"camlink:onedrive"); wake.acquire(6*60*60*1000L); }
        catch(Exception e){ status="無法啟動 OneDrive 上傳"; stopSelf(); return START_NOT_STICKY; }
        running=true; stopped=false; new Thread(this::work,"onedrive-upload").start(); return START_NOT_STICKY;
    }
    private boolean cancelled(){ return stopped||OneDriveAuth.prefs(this).getBoolean("paused",false); }
    private Network network(){
        ConnectivityManager cm=getSystemService(ConnectivityManager.class); boolean wifiOnly=OneDriveAuth.prefs(this).getBoolean("wifi",false);
        Network active=cm.getActiveNetwork(); NetworkCapabilities ac=active==null?null:cm.getNetworkCapabilities(active); boolean vpn=ac!=null&&ac.hasTransport(NetworkCapabilities.TRANSPORT_VPN);
        Network best=null; int bestScore=-1;
        for(Network n:cm.getAllNetworks()){ NetworkCapabilities c=cm.getNetworkCapabilities(n); if(c==null) continue;
            int score=InternetRoute.score(c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),!c.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED),c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),c.hasTransport(NetworkCapabilities.TRANSPORT_VPN),n.equals(active),vpn,wifiOnly);
            if(score>bestScore){ best=n; bestScore=score; }
        }
        boolean needCell=!wifiOnly&&!vpn&&bestScore<70;
        if(!needCell) releaseCell();
        else if(cellular==null){ ConnectivityManager.NetworkCallback callback=new ConnectivityManager.NetworkCallback(); try{ cm.requestNetwork(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),callback); cellular=callback; }catch(RuntimeException ignored){} }
        return best;
    }
    private void releaseCell(){ if(cellular!=null){ try{ getSystemService(ConnectivityManager.class).unregisterNetworkCallback(cellular); }catch(RuntimeException ignored){} cellular=null; } }
    private String resolveFolder(OneDriveApi api,OneDriveStore db,OneDriveStore.Job job) throws Exception {
        if(job.folder.startsWith("name:")){
            String cached=folderIds.get(job.folder); if(cached!=null) return cached;
            String id=api.ensureFolder(job.folder.substring(5)); folderIds.put(job.folder,id); return id;
        }
        String cached=folderIds.get(job.folder); if(cached!=null) return cached;
        try{ api.checkFolder(job.folder); folderIds.put(job.folder,job.folder); return job.folder; }
        catch(OneDriveApi.Failure e){ if(e.status!=404) throw e; }
        String saved=OneDriveAuth.prefs(this).getString("folder","");
        if(!saved.isEmpty()&&!saved.equals(job.folder))try{ api.checkFolder(saved); db.retargetFolder(job.account,job.folder,saved); job.folder=saved; job.uri=""; job.offset=0; folderIds.put(saved,saved); return saved; }
        catch(OneDriveApi.Failure e){ if(e.status!=404) throw e; }
        String name=OneDriveAuth.prefs(this).getString("folder_name","").trim();
        if(name.isEmpty()) name="Cam Link";
        String id=api.ensureFolder(name);
        OneDriveAuth.prefs(this).edit().putString("folder",id).putString("folder_name",name).commit();
        String old=job.folder;
        db.retargetFolder(job.account,old,id);
        job.folder=id; job.uri=""; job.offset=0; folderIds.put(id,id);
        status="原資料夾已不存在，已建立「"+name+"」並繼續上傳";
        return id;
    }
    private void upload(OneDriveStore db,OneDriveStore.Job job,Network net) throws Exception {
        OneDriveApi api=new OneDriveApi(()->OneDriveAuth.token(this),url->(HttpURLConnection)net.openConnection(url));
        String folder=resolveFolder(api,db,job);
        job.state="UPLOADING"; job.error=""; db.save(job);
        if(job.uri.isEmpty()){
            try{ job.uri=api.session(folder,job.name); }
            catch(OneDriveApi.Failure e){ if(e.status==404){ folderIds.remove(folder); folderIds.remove(job.folder); } throw e; }
            job.offset=0; db.save(job);
        }
        while(job.offset<job.size){
            if(cancelled()) throw new InterruptedIOException("已暫停");
            int count=OneDriveApi.chunk(job.size,job.offset); long previous=job.offset;
            OneDriveApi.Reply reply=api.putRange(job.uri,Gallery.source(this,new java.io.File(job.path)),job.size,job.offset,count,this::cancelled);
            if(reply.status==200||reply.status==201){ OneDriveApi.verify(reply.json(),job.size,job.sha); job.remote=reply.json().getString("id"); job.offset=job.size; job.state="DONE"; job.uri=""; job.error=""; db.save(job); return; }
            if(reply.status==202){ long next=OneDriveApi.nextOffset(reply,previous+count); if(next<=previous||next>previous+count) throw new java.io.IOException("OneDrive 上傳進度異常"); job.offset=next; db.save(job); continue; }
            if(reply.status==404||reply.status==410){ job.uri=""; job.offset=0; db.save(job); throw new java.io.IOException("上傳階段已過期，將重試"); }
            throw OneDriveApi.failure(reply);
        }
    }
    private void work(){
        OneDriveStore db=OneDriveStore.get(this); long started=SystemClock.elapsedRealtime();
        try{
            db.reviveMissingFolder(OneDriveAuth.prefs(this).getString("account",""));
            while(!cancelled()){
                String account=OneDriveAuth.prefs(this).getString("account","");
                if(!OneDriveAuth.signedIn(OneDriveAuth.prefs(this))||!OneDriveAuth.prefs(this).getBoolean("enabled",false)){ status="OneDrive 未啟用"; break; }
                if(!db.pending(account)&&!CaptureService.running){ if(SystemClock.elapsedRealtime()-started<2000){ Thread.sleep(250); continue; } status="OneDrive 佇列已處理完畢"; break; }
                Network net=network(); if(net==null){ status=OneDriveAuth.prefs(this).getBoolean("wifi",false)?"等待可上網的 Wi-Fi":"等待 4G／5G 或 Wi-Fi"; Thread.sleep(500); continue; }
                OneDriveStore.Job job=db.next(account); if(job==null){ status="等待新 JPG 或重試時間"; Thread.sleep(300); continue; }
                status="正在上傳到 OneDrive · "+job.name;
                try{ upload(db,job,net); }
                catch(Exception e){
                    job.error=OneDriveAuth.safe(e);
                    if(cancelled()||e instanceof InterruptedIOException){ job.state="WAITING"; job.next=0; }
                    else if(e instanceof OneDriveAuth.LoginRequired||e instanceof OneDriveApi.Failure&&((OneDriveApi.Failure)e).status==401){ job.state="AUTH"; status="請重新登入 OneDrive"; db.save(job); break; }
                    else if(e instanceof OneDriveApi.Failure&&((OneDriveApi.Failure)e).status==409){ job.state="ERROR"; job.error="OneDrive 已有同名檔案，未覆蓋"; job.next=0; db.save(job); continue; }
                    else { job.attempts++; boolean retry=!(e instanceof OneDriveApi.Failure)||((OneDriveApi.Failure)e).retryable; job.state=retry&&job.attempts<8?"RETRY":"ERROR"; job.next=job.state.equals("RETRY")?System.currentTimeMillis()+Math.min(300000L,2000L<<Math.min(7,job.attempts)):0; }
                    db.save(job);
                }
            }
            if(cancelled()) status="OneDrive 已暫停 · 佇列及原檔保留";
        }catch(Exception e){ status="OneDrive 上傳暫停："+OneDriveAuth.safe(e); }
        finally{ releaseCell(); if(wake!=null&&wake.isHeld()) wake.release(); running=false; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); }
    }
    @Override public void onTimeout(int startId,int fgsType){ stopped=true; status="Android 已暫停 OneDrive 上傳，重開 App 可繼續"; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); }
    @Override public void onDestroy(){ stopped=true; super.onDestroy(); }
}
