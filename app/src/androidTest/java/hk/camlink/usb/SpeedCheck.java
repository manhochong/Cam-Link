package hk.camlink.usb;

import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.SystemClock;
import java.io.File;
import java.util.*;
import java.util.concurrent.*;

/** Explicit real-Drive benchmark. Writes only labelled benchmark copies in a separate folder. */
final class SpeedCheck {
    private static boolean wifi(Context c){
        ConnectivityManager manager=c.getSystemService(ConnectivityManager.class);
        NetworkCapabilities caps=manager.getNetworkCapabilities(manager.getActiveNetwork());
        return caps!=null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
    }
    static void run(Instrumentation test,Bundle args){
        Bundle result=new Bundle();
        try{
            Context c=test.getTargetContext();
            SharedPreferences prefs=CloudStore.prefs(c);
            String email=prefs.getString("email","");
            if(!email.equalsIgnoreCase(args.getString("account",""))||email.isEmpty()||!wifi(c))
                throw new IllegalStateException("需已選帳戶及 Wi-Fi");
            String token=CloudAuth.token(c,prefs.getString("account",""),email);
            DriveApi api=new DriveApi(()->token);
            File source=new File(c.getExternalFilesDir(null),"sessions/"+args.getString("source",""));
            File root=new File(c.getExternalFilesDir(null),"sessions");
            if(!source.getCanonicalPath().startsWith(root.getCanonicalPath()+File.separator)||(!source.isFile()&&!Gallery.marker(source).isFile()))
                throw new IllegalArgumentException("需指定已接收的原圖");
            String folder=args.getString("bench_folder","");
            if(folder.isEmpty()){
                folder=api.generateId();api.createFolder("Cam Link 上傳速度比較 "+System.currentTimeMillis(),folder);
            }
            api.checkFolder(folder);
            Bundle progress=new Bundle();progress.putString("stream","BENCH_FOLDER="+folder+"\n");test.sendStatus(0,progress);
            if(args.containsKey("ten")){
                if(prefs.getBoolean("paused",false))throw new IllegalStateException("Drive 已手動暫停");
                compareTen(test,c,source,folder,token,result);return;
            }
            if(args.containsKey("compare")){
                List<File> photos=new ArrayList<>();
                photos.add(source);
                for(String name:args.getString("compare","").split(",")){
                    if(!name.matches("[A-Za-z0-9_]+[.]JPG"))throw new IllegalArgumentException("Invalid test file");
                    File photo=new File(source.getParentFile(),name);
                    if(!photo.isFile()&&!Gallery.marker(photo).isFile())throw new IllegalArgumentException("Missing test file");
                    photos.add(photo);
                }
                if(photos.size()>4)throw new IllegalArgumentException("Maximum four files per batch");
                final String target=folder;
                if("yes".equals(args.getString("service_test",""))){
                    checkQueue(test,c,prefs,target,photos);
                    result.putString("stream","VERIFIED production queue and album uploads\n");
                    test.finish(-1,result);return;
                }
                for(int lanes:new int[]{1,2}){
                    ExecutorService pool=Executors.newFixedThreadPool(lanes);
                    try{
                        List<Callable<Long>> tasks=new ArrayList<>();
                        for(File photo:photos)tasks.add(()->upload(c,api,target,photo,"batch-"+lanes));
                        long start=SystemClock.elapsedRealtime(),bytes=0;
                        for(Future<Long> item:pool.invokeAll(tasks))bytes+=item.get();
                        long elapsed=SystemClock.elapsedRealtime()-start;
                        Bundle line=new Bundle();
                        line.putString("stream","VERIFIED lanes="+lanes+" photos="+photos.size()+" bytes="+bytes+" ms="+elapsed+"\n");
                        test.sendStatus(0,line);
                    }finally{pool.shutdownNow();}
                }
                result.putString("stream","BATCH COMPLETE\n");
            }else{
                long start=SystemClock.elapsedRealtime();
                long bytes=upload(c,api,folder,source,BuildConfig.VERSION_NAME);
                result.putString("stream","VERIFIED bytes="+bytes+" ms="+(SystemClock.elapsedRealtime()-start)+"\n");
            }
            test.finish(-1,result);
        }catch(Exception e){result.putString("stream","FAIL "+e.getClass().getSimpleName()+" "+UploadService.safeError(e)+"\n");test.finish(0,result);}
    }
    private static void compareTen(Instrumentation test,Context c,File source,String folder,String token,Bundle result)throws Exception{
        File session=source.getParentFile().getParentFile();
        List<String> names=ShootPanel.readPhotoNames(session);
        if(names.size()!=10||new HashSet<>(names).size()!=10)throw new IllegalStateException("需同一場十張不同來源的 JPG");
        java.util.concurrent.atomic.AtomicInteger ids=new java.util.concurrent.atomic.AtomicInteger(),reads=new java.util.concurrent.atomic.AtomicInteger();
        DriveApi.Http http=new DriveApi.Http();
        DriveApi measured=new DriveApi(()->token,(method,url,headers,body)->{
            if(url.contains("generateIds?"))ids.incrementAndGet();
            else if(method.equals("GET"))reads.incrementAndGet();
            return http.send(method,url,headers,body);
        });
        List<Callable<Long>> tasks=new ArrayList<>();
        String version=c.getPackageManager().getPackageInfo(c.getPackageName(),0).versionName;
        long bytes=0;
        for(String name:names){
            File photo=new File(source.getParentFile(),name);
            CloudStore.Job job=new CloudStore.Job();job.remote="";job.uri="";job.key=UUID.randomUUID().toString();
            job.folder=folder;job.name="speed-"+version+"-"+name;job.size=photo.isFile()?photo.length():Gallery.record(Gallery.marker(photo)).getLong("size");
            DriveApi.Input input=Gallery.source(c,photo);job.sha=DriveApi.hashes(input,job.size,()->false)[0];
            bytes+=job.size;
            tasks.add(()->{
                new UploadEngine(measured,j->{},()->!wifi(c),n->{}).run(job,input);
                if(!"DONE".equals(job.state))throw new IllegalStateException("未核對");
                return SystemClock.elapsedRealtime();
            });
        }
        ExecutorService pool=Executors.newFixedThreadPool(2);
        try{
            long start=SystemClock.elapsedRealtime(),first=Long.MAX_VALUE,last=0;
            for(Future<Long> item:pool.invokeAll(tasks)){long t=item.get();first=Math.min(first,t);last=Math.max(last,t);}
            result.putString("stream","VERIFIED version="+version+" photos=10 bytes="+bytes+" first_ms="+(first-start)+" batch_ms="+(last-start)+" id_requests="+ids+" metadata_reads="+reads+"\n");
            test.finish(-1,result);
        }finally{pool.shutdownNow();}
    }
    private static long upload(Context c,DriveApi api,String folder,File source,String label)throws Exception{
        CloudStore.Job job=new CloudStore.Job();
        job.remote="";job.uri="";job.key=UUID.randomUUID().toString();job.folder=folder;
        job.path=source.getPath();job.name=label+"-"+source.getName();job.size=source.length();
        DriveApi.Input input=Gallery.source(c,source);
        if(!source.exists())job.size=Gallery.record(Gallery.marker(source)).getLong("size");
        job.sha=DriveApi.hashes(input,job.size,()->false)[0];
        new UploadEngine(api,j->{},()->!wifi(c),n->{}).run(job,input);
        if(!"DONE".equals(job.state))throw new IllegalStateException("Upload incomplete");
        return job.size;
    }
    private static void checkQueue(Instrumentation test,Context c,SharedPreferences prefs,String folder,List<File> photos)throws Exception{
        if(prefs.getBoolean("paused",false))throw new IllegalStateException("上傳已由使用者暫停");
        String account=prefs.getString("account","");
        org.json.JSONObject target=new org.json.JSONObject().put("account",account).put("email",prefs.getString("email","")).put("folder",folder);
        CloudStore db=CloudStore.get(c);
        for(File f:photos){
            org.json.JSONObject ref=Gallery.record(Gallery.marker(f));
            db.enqueue(f,"queue-"+ref.getString("name"),f.getParentFile().getParentFile().getName(),ref.getLong("size"),ref.getString("sha"),target);
        }
        android.app.Activity screen=test.startActivitySync(new android.content.Intent(c,MainActivity.class).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK));
        test.runOnMainSync(()->UploadService.start(screen));
        long deadline=SystemClock.elapsedRealtime()+120000;
        int peak=0;
        while(SystemClock.elapsedRealtime()<deadline){
            int done=0,active=0;
            for(File f:photos)try(android.database.Cursor row=db.getReadableDatabase().rawQuery("SELECT state FROM uploads WHERE path=? AND folder=? AND account=?",new String[]{f.getCanonicalPath(),folder,account})){
                if(!row.moveToFirst())throw new IllegalStateException("缺少上傳項目");
                String state=row.getString(0);if(state.equals("DONE"))done++;if(state.equals("UPLOADING"))active++;
                if(state.equals("ERROR")||state.equals("AUTH"))throw new IllegalStateException(state);
            }
            peak=Math.max(peak,active);
            if(done==photos.size()){
                Bundle line=new Bundle();line.putString("stream","SERVICE verified="+done+" peak="+peak+"\n");test.sendStatus(0,line);return;
            }
            Thread.sleep(150);
        }
        throw new IllegalStateException("上傳仍在等待");
    }
}
