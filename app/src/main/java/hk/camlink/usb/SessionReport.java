package hk.camlink.usb;

import android.os.Build;
import android.os.SystemClock;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.*;

public final class SessionReport implements Closeable {
    public final File dir,photos;
    private final List<String> verifiedPhotos=new ArrayList<>();
    int photoCount(){synchronized(verifiedPhotos){return verifiedPhotos.size();}}
    String photoAt(int index){synchronized(verifiedPhotos){return verifiedPhotos.get(index);}}
    private final Writer log,rows;
    private final long start=SystemClock.elapsedRealtime();
    private final JSONObject meta=new JSONObject();
    public SessionReport(File root,String description,int poll,String note)throws Exception {
        this(root,description,poll,note,false);
    }
    SessionReport(File root,String description,int poll,String note,boolean wifi)throws Exception {
        dir=new File(root,new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.US).format(new Date())+"-"+UUID.randomUUID().toString().substring(0,6));
        photos=new File(dir,"jpg");if(!photos.mkdirs())throw new IOException("無法建立儲存目錄");
        log=new BufferedWriter(new OutputStreamWriter(new FileOutputStream(new File(dir,"events.log")),StandardCharsets.UTF_8));
        rows=new BufferedWriter(new OutputStreamWriter(new FileOutputStream(new File(dir,"files.csv")),StandardCharsets.UTF_8));
        rows.write("status,handle,storage,original_name,local_name,expected_bytes,actual_bytes,sha256,width,height,discovered_ms,download_start_ms,download_end_ms,verified_ms,attempts,source,error,trailing_bytes\n");rows.flush();
        meta.put("schema",1).put("app_version",BuildConfig.VERSION_NAME).put("usb_transport","native_usbfs_64KiB").put("ptp_init","OpenSession_then_GetDeviceInfo").put("started_at",new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX",Locale.US).format(new Date()))
            .put("phone",Build.MANUFACTURER+" "+Build.MODEL).put("android",Build.VERSION.RELEASE).put("sdk",Build.VERSION.SDK_INT)
            .put("usb",description).put("poll_ms",poll).put("operator_notes",note)
            .put("validation_scope","PTP bytes + JPEG structure + SHA-256; independent card comparison required")
            .put("shooting_impact","NOT_MEASURED").put("camera_card_comparison","NOT_MEASURED");
        if(wifi){meta.remove("usb");meta.remove("ptp_init");meta.remove("usb_transport");
            meta.put("transport",description.startsWith("LUMIX direct")?"wifi_lumix_ptpip_experimental":description.startsWith("Camera FTP")?"wifi_ftp":"wifi_companion_folder").put("validation_scope","Source bytes + JPEG structure + SHA-256");}
        writeJson(new File(dir,"device.json"),meta);
    }
    public long now(){return SystemClock.elapsedRealtime()-start;}
    public synchronized void log(String s){try{log.write(now()+" "+s.replace('\n',' ') +"\n");log.flush();}catch(IOException e){throw new UncheckedIOException(e);}}
    public synchronized void camera(Ptp.DeviceInfo d)throws Exception {
        meta.put("camera_manufacturer",d.manufacturer).put("camera_model",d.model).put("camera_firmware",d.version)
            .put("ptp_extension",d.extension).put("operations",Ptp.codes(d.operations)).put("events",Ptp.codes(d.events));
        writeJson(new File(dir,"device.json"),meta);
    }
    public static String csv(Object value) {String s=String.valueOf(value);return "\""+s.replace("\"","\"\"")+"\"";}
    public synchronized void row(String status,ReceiveQueue.Item item,Ptp.Info info,String local,long actual,JpegCheck check,long from,long to,String error)throws IOException {
        Object[] cells={status,Integer.toUnsignedString(item.handle),info==null?"":Integer.toUnsignedString(info.storage),info==null?"":info.name,local,info==null?0:info.size,actual,check==null?"":check.sha256,check==null?0:check.width,check==null?0:check.height,item.discovered,from,to,now(),item.attempts,item.source,error,check==null?"":check.trailingBytes};
        for(int i=0;i<cells.length;i++){if(i>0)rows.write(',');rows.write(csv(cells[i]));}rows.write('\n');rows.flush();
        if("OK".equals(status))synchronized(verifiedPhotos){verifiedPhotos.add(local);}
    }
    public synchronized void summary(JSONObject state)throws Exception{state.put("elapsed_ms",now());writeJson(new File(dir,"summary.json"),state);}
    public static void writeJson(File target,JSONObject value)throws Exception {
        File temp=new File(target.getParentFile(),target.getName()+".tmp");
        try(FileOutputStream out=new FileOutputStream(temp)){out.write(value.toString(2).getBytes(StandardCharsets.UTF_8));out.getFD().sync();}
        // Atomic replacement on the app's filesystem; no delete-first window.
        java.nio.file.Files.move(temp.toPath(),target.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING,java.nio.file.StandardCopyOption.ATOMIC_MOVE);
    }
    @Override public synchronized void close()throws IOException{try{rows.close();}finally{log.close();}}
}
