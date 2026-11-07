package hk.camlink.usb;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.hardware.usb.*;
import android.os.*;
import org.json.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class CaptureService extends Service {
    public static volatile CaptureService active;
    public static volatile String status="等待連接相機",camera="S1M2 / S1R2 · 尚未驗證",detail="",lastFile="";
    public static volatile int good,bad,skipped,pending,validating,found,baseline,events;
    public static volatile long bytes,usbMs,elapsedMs,latestLatency;
    public static volatile boolean running,ready;
    private volatile boolean abort,finish,scanNow;
    private volatile UsbWire wire;
    volatile SessionReport report;
    private JSONObject cloudDestination,onedriveDestination;
    volatile String driveEventName="";
    private String davProfile="",pcProfile="";
    private String eventName;
    private boolean importCard,haltImport,importFinished;
    private int importLeft;
    private final Set<String> cardSeen=Collections.newSetFromMap(new ConcurrentHashMap<>()),cardStored=Collections.newSetFromMap(new ConcurrentHashMap<>()),oneDriveStored=Collections.newSetFromMap(new ConcurrentHashMap<>()),pcStored=Collections.newSetFromMap(new ConcurrentHashMap<>());
    private final Map<String,String> cardDone=new ConcurrentHashMap<>();
    private Ptp ptp;
    private final ReceiveQueue queue=new ReceiveQueue();
    private final AtomicInteger validationCount=new AtomicInteger();
    private final AtomicBoolean eventScan=new AtomicBoolean();
    private Thread eventThread;
    private ThreadPoolExecutor validator;
    private PowerManager.WakeLock wake;
    private int deviceId,pollMs;
    private CameraProfile profile;
    private boolean receiverRegistered;
    private final BroadcastReceiver detach=new BroadcastReceiver(){public void onReceive(Context c,Intent i){UsbDevice d=i.getParcelableExtra(UsbManager.EXTRA_DEVICE);if(d!=null&&d.getDeviceId()==deviceId)emergency("相機 USB 已拔除，未完成檔案不可視為成功");}};

    @Override public IBinder onBind(Intent i){return null;}
    @Override public int onStartCommand(Intent intent,int flags,int id) {
        if(intent==null){stopSelf();return START_NOT_STICKY;}
        if("STOP".equals(intent.getAction())){finish=true;status="請先停拍；正在補掃及排空";return START_NOT_STICKY;}
        if(running)return START_NOT_STICKY;
        String wifi=intent.getStringExtra("wifi_tree");
        if(wifi!=null&&!wifi.isEmpty()){detail="已移除 Wi-Fi／FTP 接收，請用 USB 連接相機";status="請改用 USB";stopSelf();return START_NOT_STICKY;}
        eventName=intent.getStringExtra(SessionNames.EXTRA);importCard=intent.getBooleanExtra("import_card",false);haltImport=false;importFinished=false;importLeft=0;cardSeen.clear();cardStored.clear();oneDriveStored.clear();pcStored.clear();cardDone.clear();
        active=this;running=true;ready=false;abort=false;finish=false;scanNow=false;
        good=bad=skipped=pending=validating=found=baseline=events=0;bytes=usbMs=elapsedMs=latestLatency=0;lastFile="";detail="";camera="正在識別相機";
        deviceId=intent.getIntExtra("device_id",-1);pollMs=intent.getIntExtra("poll_ms",2000);String notes=intent.getStringExtra("notes");
        NotificationManager nm=getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("usb","USB 接收測試",NotificationManager.IMPORTANCE_LOW));
        PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,CaptureService.class).setAction("STOP"),PendingIntent.FLAG_IMMUTABLE);
        Notification n=new Notification.Builder(this,"usb").setSmallIcon(hk.camlink.usb.R.drawable.ic_camera).setContentTitle("Cam Link USB 接收測試")
            .setContentText("相機原檔保留 · 點按返回接收狀態").setContentIntent(open).setOngoing(true).addAction(new Notification.Action.Builder(null,"停拍後結束",stop).build()).build();
        try {
            if(Build.VERSION.SDK_INT>=29)startForeground(1,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);else startForeground(1,n);
            wake=getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"camlink:usb");wake.acquire(4*60*60*1000L);
            if(Build.VERSION.SDK_INT>=33)registerReceiver(detach,new IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED),Context.RECEIVER_NOT_EXPORTED);else registerReceiver(detach,new IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED));
            receiverRegistered=true;
        }catch(Exception e){detail=e.toString();status="無法啟動 USB 前景服務";running=false;active=null;stopSelf();return START_NOT_STICKY;}
        new Thread(()->runCapture(notes==null?"":notes),"usb-receiver").start();return START_NOT_STICKY;
    }
    public void rescan(){scanNow=true;}
    boolean importingCard(){return importCard;}
    boolean isFinishingCapture(){return finish||abort;}
    public void gracefulStop(){finish=true;status="請先停拍；正在補掃及排空";}
    public void pauseCardImport(){if(!importCard)return;haltImport=true;finish=true;status="這張傳完即停止，進度會保留";}
    public void emergency(String reason){detail=reason;abort=true;ready=false;UsbWire w=wire;if(w!=null)new Thread(w::close,"usb-cancel").start();}
    private void runCapture(String notes) {
        boolean clean=false;
        try {
            UsbManager manager=getSystemService(UsbManager.class);UsbDevice device=null;
            for(UsbDevice d:manager.getDeviceList().values())if(d.getDeviceId()==deviceId)device=d;
            if(device==null||!manager.hasPermission(device))throw new IOException("找不到已授權相機，請重新接線");
            profile=CameraProfile.find(device.getVendorId());
            if(profile==null||!UsbWire.candidate(device))throw new IOException("未支援這個 USB 相機介面");
            String priorPath=getSharedPreferences("state",MODE_PRIVATE).getString("last_session","");
            boolean resumeCard=getSharedPreferences("state",MODE_PRIVATE).getBoolean("card_import_open",false)||unfinishedCardImport(priorPath);
            if(resumeCard)importCard=true;
            openReport(UsbWire.describe(device),notes);
            if(importCard)new File(report.dir,"card-import").createNewFile();
            report.log("SESSION_START "+UsbWire.describe(device));
            status="開啟標準 PTP 介面";wire=new UsbWire(manager,device);ptp=new Ptp(wire,s->report.log(s));
            // Open first for cameras that reject out-of-session GetDeviceInfo.
            // This is session management only; no camera shooting/storage settings change.
            report.log("TRANSPORT native_usbfs chunk="+NativeUsb.BULK_BYTES+" init=OpenSession_then_GetDeviceInfo "+NativeUsb.selfTest());
            Ptp.DeviceInfo info=ptp.initialize();report.camera(info);camera=info.model+" · FW "+info.version;
            int vendorPoll=profile.eventOperation(info);
            long nextVendorPoll=0;
            report.log("CARD_PROFILE "+profile.brand+" event_poll="+Integer.toHexString(vendorPoll));
            for(int op:new int[]{0x1002,0x1004,0x1007,0x1008,0x1009})if(!info.supports(op))throw new IOException(String.format(Locale.US,"相機未宣告必要 PTP 操作 %04X；需研究私有協議，請匯出報告",op));
            status="建立卡內基線，現在請勿拍攝";
            // Nothing may be discovered until every storage has been enumerated successfully.
            int[] card=ptp.inventory();
            File prior=interruptedSession(priorPath);
            int skippedHandles=0;
            if(importCard){
                loadCardDone();
                cardStored.addAll(CloudStore.get(this).storedNames(cloudDestination==null?"":cloudDestination.optString("account")));
                oneDriveStored.addAll(OneDriveStore.get(this).storedNames(onedriveDestination==null?"":onedriveDestination.optString("account")));
                for(android.content.SharedPreferences slot:DavBackup.pcSlots(this)){String profile=slot.getString("active","");if(!profile.isEmpty())pcStored.addAll(DavBackup.storedNames(this,profile));}
                cardSeen.addAll(cardStored);cardSeen.addAll(oneDriveStored);cardSeen.addAll(pcStored);
                int queued=0;for(int handle:card)if(queue.add(handle,report.now(),"card"))queued++;
                skippedHandles=queue.omitFinished(finishedCardHandles(priorPath));
                if(resumeCard&&skippedHandles==0)queue.newestFirst();
                report.log("CARD_IMPORT queued="+queued+" skip="+skippedHandles+" already="+cardSeen.size()+" resume="+resumeCard);
                status=skippedHandles>0?"已略過 "+skippedHandles+" 張已傳檔，正在傳剩下的":resumeCard?"正在繼續未傳完的卡內 JPG，請保持連線":"正在接收卡內 JPG，請保持連線";
                getSharedPreferences("state",MODE_PRIVATE).edit().putBoolean("card_import_open",true).commit();
            }else if(prior==null)queue.baseline(card);
            else {
                ReceiveQueue.Gap gap=queue.reopen(readHandles(new File(prior,"baseline.txt")),finishedHandles(new File(prior,"files.csv")),card,report.now());
                if(gap.renumbered){
                    queue.baseline(card);
                    detail="相機已重新編號卡檔，未能對上上一場。這輪只收新拍的 JPG，掉線期間的照片請從卡複製。";
                    report.log("RECONNECT_HANDLES_CHANGED prior="+prior.getName());
                }else{
                    report.log("RECONNECT_RECOVER prior="+prior.getName()+" count="+gap.recover);
                    if(gap.recover>0)status="正在補收上一場未收到的 "+gap.recover+" 張";
                }
            }
            baseline=queue.baselineCount();report.log("BASELINE_READY objects="+baseline);rememberBaseline();
            validator=new ThreadPoolExecutor(1,1,0,TimeUnit.MILLISECONDS,new ArrayBlockingQueue<>(8),r->new Thread(r,"jpg-validator"),new ThreadPoolExecutor.CallerRunsPolicy());
            ready=true;if(!importCard||skippedHandles==0)status=importCard?(resumeCard?"正在繼續未傳完的卡內 JPG，請保持連線":"正在接收卡內 JPG，請保持連線"):"可以拍攝 · 等待新 JPG";
            startEvents();long nextScan=report.now()+pollMs,lastNew=report.now();int quietScans=0;
            while(!abort) {
                if(report.now()>=4*60*60*1000L-10000)throw new IOException("已達本版 4 小時測試上限，請停拍並重新開始測試");
                if(importCard&&haltImport){
                    if(validationCount.get()==0){
                        importLeft=queue.dropPending();
                        report.log("CARD_IMPORT_PAUSED left="+importLeft);
                        detail="已停止。下次連接後按「繼續上傳卡內 JPG」會接著傳。";
                        clean=true;break;
                    }
                }else if(validationCount.get()<8) {
                    ReceiveQueue.Item item=queue.next(report.now());
                    if(item!=null){importFinished=false;download(item);lastNew=report.now();quietScans=0;}
                }
                long now=report.now();
                if(vendorPoll!=0&&now>=nextVendorPoll&&pending==0){
                    try{
                        byte[] packet=ptp.command(vendorPoll,null,4*1024*1024).data;
                        if(profile.cardChanged(packet))eventScan.set(true);
                    }catch(IOException e){
                        if(!ptp.healthy())throw e;
                        report.log("EVENT_POLL_FALLBACK "+e.getMessage());vendorPoll=0;
                    }
                    nextVendorPoll=now+750;
                }
                // A full-card inventory blocks the next download. Cameras with interrupt events can wait
                // until the queue is idle; cameras without one still depend on this scan to discover files.
                boolean inventoryDue=!haltImport&&(scanNow||now>=nextScan||eventScan.get());
                if(inventoryDue&&(scanNow||queue.pending()==0||!wire.hasEvents())) {
                    if(scanNow){queue.retryFailed();scanNow=false;}
                    eventScan.set(false);
                    try {
                        int added=scan(false);
                        if(added>0){lastNew=now;quietScans=0;}else if(now-lastNew>=2000)quietScans++;
                    }catch(Ptp.ResponseException e){detail="補掃尚未成功："+e.getMessage();report.log("SCAN_RESPONSE "+e.getMessage());quietScans=0;}
                    nextScan=report.now()+Math.max(finish?2000:pollMs,500);
                }
                pending=queue.pending();bad=queue.failed();validating=validationCount.get();found=queue.discovered();elapsedMs=report.now();
                if(importCard)importFinished=pending==0&&validating==0&&quietScans>=2;
                if(finish&&quietScans>=2&&pending==0&&validating==0){clean=true;break;}
                if(!finish)status=pending>0||validating>0?(importCard?(resumeCard?"正在繼續未傳完的卡內 JPG":"正在接收卡內 JPG"):"正在接收／驗證 JPG"):(importCard?"卡內 JPG 已排入上傳":"可以拍攝 · 等待新 JPG");
                Thread.sleep(20);
            }
        }catch(Exception e){detail=e.getMessage()==null?e.toString():e.getMessage();if(report!=null)try{report.log("FATAL "+e);}catch(Exception ignored){}
        }finally{
            ready=false;abort=true;
            if(eventThread!=null)try{eventThread.join(700);}catch(InterruptedException ignored){}
            if(ptp!=null&&ptp.healthy()&&wire!=null)ptp.closeSession();
            if(wire!=null){wire.close();wire=null;}
            if(validator!=null){validator.shutdown();try{if(!validator.awaitTermination(120,TimeUnit.SECONDS)){detail="驗證仍未結束，請保留資料並檢查報告";validator.shutdownNow();clean=false;}}catch(InterruptedException e){clean=false;}}
            pending=queue.pending();bad=queue.failed();validating=validationCount.get();found=queue.discovered();
            if(report!=null){
                try {
                    elapsedMs=report.now();JSONObject summary=new JSONObject().put("clean_stop",clean).put("valid_jpg",good).put("failed",bad).put("pending",pending).put("validating",validating)
                        .put("ignored_non_jpg",skipped).put("baseline_objects",baseline).put("new_objects",found).put("events",events)
                        .put("verified_bytes",bytes).put("get_object_ms",usbMs).put("last_error",detail).put("unresolved_handles",new JSONArray(queue.unresolved()))
                        .put("completeness","UNVERIFIED_UNTIL_CARD_HASH_COMPARISON").put("shooting_impact","NOT_MEASURED");
                    report.summary(summary);report.log("SESSION_END clean="+clean);report.close();
                }catch(Exception e){detail="報告寫入失敗："+e;clean=false;}
            }
            if(importCard){
                boolean more=!importFinished||pending>0||validating>0;
                getSharedPreferences("state",MODE_PRIVATE).edit().putBoolean("card_import_open",more).commit();
                if(more){status="卡內 JPG 已停止 · 下次連接會接著傳";if(detail.isEmpty())detail="已傳完的 JPG 會跳過。接回相機後按「繼續接收」。";}
                else status=clean?"卡內 JPG 已排入上傳":"接收已停止 · 尚未完成驗證";
            }else status=clean?(bad==0&&pending==0?"接收已結束 · 請用卡檔核對漏圖":"已結束，仍有未完成項目"):"接收已停止 · 尚未完成驗證";
            if(clean&&good>0)DeliveryNotify.finished(this,good,bad);
            else if(bad>0)DeliveryNotify.issue(this,"有 "+bad+" 張驗證失敗");
            if(receiverRegistered){unregisterReceiver(detach);receiverRegistered=false;}
            if(wake!=null&&wake.isHeld())wake.release();
            running=false;active=null;stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();
        }
    }
    private void openReport(String description,String notes)throws Exception{
            report=new SessionReport(new File(getExternalFilesDir(null),"sessions"),description,pollMs,notes);
            if(eventName!=null&&!eventName.isEmpty()&&!SessionNames.save(this,report.dir,eventName))
                throw new IOException("未能儲存活動名稱，請重新開始接收");
            davProfile=DavBackup.active(this);pcProfile=DavBackup.pcPaired(this)?"pc":"";
            try{cloudDestination=CloudStore.get(this).bindSession(report.dir,eventName);}catch(Exception e){cloudDestination=null;UploadService.status="無法保存雲端目的地，本輪先本機接收；結束後請手動加入上傳";}
            try{onedriveDestination=OneDriveAuth.bind(this,eventName);}catch(Exception e){onedriveDestination=null;}
            driveEventName=cloudDestination==null?"":cloudDestination.optString("eventName");
            getSharedPreferences("state",MODE_PRIVATE).edit().putString("last_session",report.dir.getAbsolutePath()).apply();
    }
    private void publish(ReceiveQueue.Item item,Ptp.Info object,File temp,String name,long began,long ended)throws Exception{
        JpegCheck check=JpegCheck.check(temp,object.size);
        if(object.width>0&&object.height>0&&(check.width!=object.width||check.height!=object.height))throw new IOException("JPEG dimensions differ from ObjectInfo");
        File dest=new File(report.photos,name);if(!temp.renameTo(dest))throw new IOException("Cannot finalize JPG");
        try{Gallery.move(this,dest,object.name,check.bytes,check.sha256);}
        catch(Exception e){detail="未完成移至 DCIM/CAM LINK，原圖已保留："+e.getMessage();report.log("GALLERY_PENDING");}
        report.row("OK",item,object,name,check.bytes,check,began,ended,"");
        if(importCard){rememberCardDone(object.name,dest);markCardHandle(item.handle);}
        bytes+=check.bytes;usbMs+=Math.max(1,ended-began);latestLatency=report.now()-item.discovered;lastFile=object.name;good++;
        if(good==1)DeliveryNotify.first(this,object.name);
        // Cloud failure must never reclassify a verified USB original as a failed download.
        try{
            CloudStore.get(this).enqueue(dest,object.name,report.dir.getName(),check.bytes,check.sha256,check.md5,cloudDestination);
            if(cloudDestination!=null&&!CloudStore.prefs(this).getBoolean("paused",false))UploadService.start(this);
        }
        catch(Exception cloudError){UploadService.status="上傳排隊待恢復；JPG 已保留";report.log("CLOUD_QUEUE_RECOVERY_REQUIRED");}
        try{OneDriveStore.get(this).enqueue(dest,object.name,report.dir.getName(),check.bytes,check.sha256,onedriveDestination);if(onedriveDestination!=null&&!OneDriveAuth.prefs(this).getBoolean("paused",false))OneDriveService.start(this);}
        catch(Exception oneDriveError){report.log("ONEDRIVE_QUEUE");}
        try{DavBackup.enqueueAllPc(this,dest,object.name,check.bytes,check.sha256);}
        catch(Exception failure){detail="電腦傳送未能排隊，原圖已保留";report.log("PC_ENQUEUE_FAILED");}
        try{DavBackup.enqueue(this,davProfile,dest,object.name,check.bytes,check.sha256);}
        catch(Exception failure){detail="WebDAV 未能排隊，原圖已保留";report.log("DAV_ENQUEUE_FAILED");}
    }
    private File interruptedSession(String path){
        if(path==null||path.isEmpty())return null;
        File dir=new File(path);
        if(!dir.isDirectory()||dir.equals(report.dir)||!new File(dir,"baseline.txt").isFile())return null;
        File summary=new File(dir,"summary.json");
        if(!summary.isFile())return dir;
        try{if(new JSONObject(new String(java.nio.file.Files.readAllBytes(summary.toPath()),java.nio.charset.StandardCharsets.UTF_8)).optBoolean("clean_stop",true))return null;}
        catch(Exception e){return null;}
        return dir;
    }
    private static int[] readHandles(File file)throws IOException{
        ArrayList<Integer> ids=new ArrayList<>();
        for(String line:java.nio.file.Files.readAllLines(file.toPath())){line=line.trim();if(!line.isEmpty())ids.add(Integer.parseUnsignedInt(line));}
        int[] out=new int[ids.size()];for(int i=0;i<ids.size();i++)out[i]=ids.get(i);return out;
    }
    private static int[] finishedHandles(File csv)throws IOException{
        if(!csv.isFile())return new int[0];
        ArrayList<Integer> ids=new ArrayList<>();
        for(String line:java.nio.file.Files.readAllLines(csv.toPath())){
            if(!line.startsWith("\"OK\",")&&!line.startsWith("\"IGNORED\","))continue;
            int comma=line.indexOf(',');int start=line.indexOf('"',comma)+1;int end=line.indexOf('"',start);
            if(start>0&&end>start)ids.add(Integer.parseUnsignedInt(line.substring(start,end)));
        }
        int[] out=new int[ids.size()];for(int i=0;i<ids.size();i++)out[i]=ids.get(i);return out;
    }
    private File cardDoneFile(){return new File(getExternalFilesDir(null),"card-import-done.txt");}
    private void loadCardDone(){
        File file=cardDoneFile();if(!file.isFile())return;
        try{
            for(String line:java.nio.file.Files.readAllLines(file.toPath())){
                int tab=line.indexOf('\t');if(tab<=0)continue;
                String name=line.substring(0,tab);cardDone.put(name,line.substring(tab+1));cardSeen.add(name);
            }
        }catch(IOException e){report.log("CARD_DONE_READ "+e.getMessage());}
    }
    private synchronized void rememberCardDone(String name,File dest){
        String safe=name.replace('\t',' ').replace('\r',' ').replace('\n',' ');
        cardSeen.add(safe);cardDone.put(safe,dest.getAbsolutePath());
        try{
            java.nio.file.Files.write(cardDoneFile().toPath(),(safe+"\t"+dest.getAbsolutePath()+"\n").getBytes(java.nio.charset.StandardCharsets.UTF_8),java.nio.file.StandardOpenOption.CREATE,java.nio.file.StandardOpenOption.APPEND);
        }catch(IOException e){report.log("CARD_DONE_WRITE "+e.getMessage());}
    }
    private void deferRequeue(Runnable work){
        ThreadPoolExecutor pool=validator;
        if(pool==null||pool.isShutdown()){work.run();return;}
        pool.execute(work);
    }
    private void queueSaved(String name){
        if(cloudDestination==null||cardStored.contains(name))return;
        String path=cardDone.get(name);if(path==null)return;
        try{
            File file=new File(path);File marker=Gallery.marker(file);
            if(marker.isFile()){
                JSONObject ref=Gallery.record(marker);
                if(CloudStore.get(this).enqueue(file,ref.getString("name"),file.getParentFile().getParentFile().getName(),ref.getLong("size"),ref.getString("sha"),"",cloudDestination)){
                    cardStored.add(name);if(!CloudStore.prefs(this).getBoolean("paused",false))UploadService.start(this);
                }
            }else if(file.isFile())deferRequeue(()->{
                if(cloudDestination==null||cardStored.contains(name))return;
                try{
                    JpegCheck checked=JpegCheck.check(file,file.length());
                    if(CloudStore.get(this).enqueue(file,name,file.getParentFile().getParentFile().getName(),checked.bytes,checked.sha256,checked.md5,cloudDestination)){
                        cardStored.add(name);if(!CloudStore.prefs(this).getBoolean("paused",false))UploadService.start(this);
                    }
                }catch(Exception e){report.log("CARD_REQUEUE "+name+" "+e.getMessage());}
            });
        }catch(Exception e){report.log("CARD_REQUEUE "+name+" "+e.getMessage());}
    }
    private boolean queueComputer(String name){
        if(!DavBackup.pcPaired(this)||pcStored.contains(name))return true;
        String path=cardDone.get(name);if(path==null)return false;
        try{
            File file=new File(path);File marker=Gallery.marker(file);
            if(marker.isFile()){
                JSONObject ref=Gallery.record(marker);
                DavBackup.enqueueAllPc(this,file,ref.optString("name",name),ref.getLong("size"),ref.getString("sha"));
                pcStored.add(name);return true;
            }
            if(file.isFile()){
                deferRequeue(()->{
                    if(!DavBackup.pcPaired(this)||pcStored.contains(name))return;
                    try{
                        JpegCheck checked=JpegCheck.check(file,file.length());
                        DavBackup.enqueueAllPc(this,file,name,checked.bytes,checked.sha256);
                        pcStored.add(name);
                    }catch(Exception e){report.log("PC_REQUEUE "+name);}
                });
                return true;
            }
            return false;
        }catch(Exception e){report.log("PC_REQUEUE "+name);return false;}
    }
    private void queueOneDrive(String name){
        if(onedriveDestination==null||oneDriveStored.contains(name))return;
        String path=cardDone.get(name);if(path==null)return;
        try{
            File file=new File(path);File marker=Gallery.marker(file);
            if(marker.isFile()){
                JSONObject ref=Gallery.record(marker);
                if(OneDriveStore.get(this).enqueue(file,ref.getString("name"),file.getParentFile().getParentFile().getName(),ref.getLong("size"),ref.getString("sha"),onedriveDestination)){
                    oneDriveStored.add(name);if(!OneDriveAuth.prefs(this).getBoolean("paused",false))OneDriveService.start(this);
                }
            }else if(file.isFile())deferRequeue(()->{
                if(onedriveDestination==null||oneDriveStored.contains(name))return;
                try{
                    JpegCheck checked=JpegCheck.check(file,file.length());
                    if(OneDriveStore.get(this).enqueue(file,name,file.getParentFile().getParentFile().getName(),checked.bytes,checked.sha256,onedriveDestination)){
                        oneDriveStored.add(name);if(!OneDriveAuth.prefs(this).getBoolean("paused",false))OneDriveService.start(this);
                    }
                }catch(Exception e){report.log("ONEDRIVE_REQUEUE "+name);}
            });
        }catch(Exception e){report.log("ONEDRIVE_REQUEUE "+name);}
    }
    private int[] finishedCardHandles(String path){
        if(path==null||path.isEmpty())return new int[0];
        File dir=new File(path);if(!dir.isDirectory())return new int[0];
        if(!new File(dir,"card-import").isFile()&&!logHas(new File(dir,"events.log"),"CARD_IMPORT"))return new int[0];
        try{return finishedHandles(new File(dir,"files.csv"));}catch(IOException e){return new int[0];}
    }
    private boolean unfinishedCardImport(String path){
        if(path==null||path.isEmpty())return false;
        File dir=new File(path);if(!dir.isDirectory())return false;
        if(!new File(dir,"card-import").isFile()&&!logHas(new File(dir,"events.log"),"CARD_IMPORT"))return false;
        File summary=new File(dir,"summary.json");if(!summary.isFile())return true;
        try{return !new JSONObject(new String(java.nio.file.Files.readAllBytes(summary.toPath()),java.nio.charset.StandardCharsets.UTF_8)).optBoolean("clean_stop",true);}
        catch(Exception e){return true;}
    }
    private static boolean logHas(File file,String token){
        if(!file.isFile())return false;
        try(java.io.BufferedReader reader=java.nio.file.Files.newBufferedReader(file.toPath())){
            String line;while((line=reader.readLine())!=null)if(line.contains(token))return true;
        }catch(IOException ignored){}
        return false;
    }
    private void markCardHandle(int handle){if(!importCard)return;queue.baseline(new int[]{handle});rememberBaseline();}
    private synchronized void rememberBaseline(){
        try{
            StringBuilder text=new StringBuilder();
            for(int handle:queue.baselineHandles())text.append(Integer.toUnsignedString(handle)).append('\n');
            java.nio.file.Files.write(new File(report.dir,"baseline.txt").toPath(),text.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        }catch(IOException e){report.log("BASELINE_SAVE_FAILED "+e.getMessage());}
    }
    private int scan(boolean isBaseline)throws IOException {
        int added=0;int[] handles=ptp.inventory();
        if(isBaseline)queue.baseline(handles);else for(int h:handles)if(queue.add(h,report.now(),"inventory"))added++;
        return added;
    }
    private void startEvents() {
        if(!wire.hasEvents()){report.log("NO_INTERRUPT_ENDPOINT; using inventory");return;}
        eventThread=new Thread(()->{
            try{while(!abort){byte[] b=wire.event();if(b==null)continue;
                if(b.length<12||Ptp.u16(b,4)!=4||Ptp.u32(b,0)!=b.length){report.log("UNPARSED_EVENT length="+b.length);eventScan.set(true);continue;}
                int code=Ptp.u16(b,6);events++;report.log(String.format(Locale.US,"EVENT code=%04X bytes=%d",code,b.length));
                if(profile!=CameraProfile.LUMIX&&(code==0x4002||profile.inventoryNotice(code)))eventScan.set(true);
                else if(code==0x4002&&b.length>=16)queue.add((int)Ptp.u32(b,12),report.now(),"ObjectAdded");
                else if(code==0x4004||code==0x4005||code==0x400b||code==0x400d)eventScan.set(true);
                // Vendor events remain logged; inventory is still the authoritative reconciliation path.
            }}catch(Exception e){if(!abort){detail="事件讀取中斷，改用補掃："+e.getMessage();try{report.log("EVENT_READER_STOP "+e);}catch(Exception logError){emergency("事件紀錄無法寫入："+logError.getMessage());}}}
        },"usb-events");eventThread.start();
    }
    private void download(ReceiveQueue.Item item)throws Exception {
        Ptp.Info info=null;File part=null;long from=report.now(),to=from;
        try {
            info=ptp.info(item.handle);
            if(!info.jpeg()){skipped++;report.row("IGNORED",item,info,"",0,null,from,from,"non-JPG");markCardHandle(item.handle);return;}
            if(importCard&&cardSeen.contains(info.name)){queueSaved(info.name);queueOneDrive(info.name);if(queueComputer(info.name)){report.row("IGNORED",item,info,"",0,null,from,from,"already stored");report.log("CARD_ALREADY "+info.name);markCardHandle(item.handle);return;}}
            long budget=Ptp.objectBudget(info.size,item.attempts);
            if(budget<0){queue.retry(item,report.now());report.log("RETRY handle="+Integer.toUnsignedString(item.handle)+" size_not_ready");return;}
            boolean unknown=info.size==Ptp.UNKNOWN_SIZE;
            long needed=unknown?512L*1024*1024:info.size+512L*1024*1024;
            if(report.dir.getUsableSpace()<needed)throw new IOException("儲存空間不足：至少需保留 512 MB，請停拍");
            String local=Integer.toUnsignedString(item.handle)+"_"+safeName(info.name);part=new File(report.photos,local+".part");
            from=report.now();boolean sizeNotReady=false;
            try(FileOutputStream out=new FileOutputStream(part)){
                long actual=ptp.object(item.handle,out,budget);to=report.now();
                if(unknown){
                    if(actual<=0||actual>Ptp.MAX_OBJECT){if(item.attempts<6)sizeNotReady=true;else throw new IOException("JPG 大小尚未就緒");}
                    else info=info.withSize(actual);
                }else if(actual!=info.size)throw new IOException("PTP byte count differs from ObjectInfo");
                if(!sizeNotReady)out.getFD().sync();
            }
            if(sizeNotReady){java.nio.file.Files.deleteIfExists(part.toPath());queue.retry(item,report.now());report.log("RETRY handle="+Integer.toUnsignedString(item.handle)+" size_not_ready");return;}
            final Ptp.Info object=info;final File temp=part;final long began=from,ended=to;final String name=local;
            validationCount.incrementAndGet();
            validator.execute(()->{
                try{
                    publish(item,object,temp,name,began,ended);
                }catch(Exception e){
                    boolean incomplete=temp.isFile()&&item.attempts<6&&e instanceof IOException&&(e.getMessage()==null||!e.getMessage().contains("dimensions"));
                    if(incomplete){
                        try{java.nio.file.Files.deleteIfExists(temp.toPath());}catch(IOException ignored){}
                        queue.retry(item,report.now());
                        try{report.log("RETRY handle="+Integer.toUnsignedString(item.handle)+" incomplete_jpg "+e);}catch(UncheckedIOException fatal){emergency("報告無法寫入："+fatal.getMessage());}
                    }else{
                        queue.fail(item);detail="驗證失敗："+e.getMessage();
                        try{report.row("FAILED",item,object,name,temp.length(),null,began,ended,e.toString());}catch(IOException fatal){emergency("報告無法寫入："+fatal);}
                        try{java.nio.file.Files.deleteIfExists(temp.toPath());}catch(IOException ignored){}
                    }
                }
                finally{validationCount.decrementAndGet();}
            });
        }catch(Exception e){
            if(e instanceof Ptp.ResponseException&&(((Ptp.ResponseException)e).code==Ptp.BUSY||((Ptp.ResponseException)e).code==0x2009)&&item.attempts<6){queue.retry(item,report.now());report.log("RETRY handle="+Integer.toUnsignedString(item.handle)+" "+e);return;}
            queue.fail(item);report.row("FAILED",item,info,part==null?"":part.getName(),part==null?0:part.length(),null,from,to,e.toString());detail=e.getMessage();
            if(part!=null)try{java.nio.file.Files.deleteIfExists(part.toPath());}catch(IOException ignored){}
            if(!ptp.healthy()||e.getMessage()!=null&&e.getMessage().contains("儲存空間不足"))throw e;
        }
    }
    static String safeName(String name){String s=name.replaceAll("[^a-zA-Z0-9._-]","_");return s.length()>100?s.substring(s.length()-100):s;}
    @Override public void onTimeout(int startId,int type){emergency("Android 已結束背景接收時段");stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
    @Override public void onDestroy(){if(running&&!abort)emergency("Android 終止接收服務，請檢查未完成項目");super.onDestroy();}
}
