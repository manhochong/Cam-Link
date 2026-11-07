package hk.camlink.usb;

import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import android.util.AtomicFile;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Keep the original queue identity while moving its bytes into the shared photo album. */
final class Gallery {
    static final String ALBUM="DCIM/CAM LINK/";
    static File index(File session){return new File(session,"gallery");}
    static File marker(File staged){return new File(index(staged.getParentFile().getParentFile()),staged.getName()+".json");}
    static JSONObject record(File marker)throws Exception{
        return new JSONObject(new String(new AtomicFile(marker).readFully(),StandardCharsets.UTF_8));
    }
    private static void save(File marker,JSONObject record)throws Exception{
        AtomicFile atomic=new AtomicFile(marker);
        FileOutputStream out=atomic.startWrite();
        try{out.write(record.toString().getBytes(StandardCharsets.UTF_8));atomic.finishWrite(out);}
        catch(Exception e){atomic.failWrite(out);throw e;}
    }
    private static FileInputStream open(ContentResolver resolver,Uri uri)throws IOException{
        ParcelFileDescriptor descriptor=resolver.openFileDescriptor(uri,"r");
        if(descriptor==null)throw new IOException("無法讀取相簿原圖");
        return new ParcelFileDescriptor.AutoCloseInputStream(descriptor);
    }
    static DriveApi.Input source(Context context,File staged){
        return ()->{
            try{return new FileInputStream(staged);}
            catch(FileNotFoundException missing){
                try{
                    JSONObject ref=record(marker(staged));
                    if(!ref.optBoolean("published"))throw missing;
                    return open(context.getContentResolver(),Uri.parse(ref.getString("uri")));
                }catch(IOException e){throw e;}catch(Exception e){throw new IOException("無法讀取相簿紀錄",e);}
            }
        };
    }
    static void move(Context context,File staged,String original,long size,String sha)throws Exception{
        File marker=marker(staged);
        if(!marker.getParentFile().isDirectory()&&!marker.getParentFile().mkdirs())throw new IOException("無法建立相簿紀錄");
        ContentResolver resolver=context.getContentResolver();
        JSONObject ref;
        if(marker.exists()){
            ref=record(marker);
            if(ref.getLong("size")!=size||!sha.equals(ref.getString("sha")))throw new IOException("相簿紀錄與原檔不符");
        }else{
            ContentValues values=new ContentValues();
            values.put(MediaStore.Images.Media.DISPLAY_NAME,CaptureService.safeName(original));
            values.put(MediaStore.Images.Media.MIME_TYPE,"image/jpeg");
            values.put(MediaStore.Images.Media.RELATIVE_PATH,ALBUM);
            values.put(MediaStore.Images.Media.IS_PENDING,1);
            Uri uri=resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),values);
            if(uri==null)throw new IOException("無法建立相簿項目");
            ref=new JSONObject().put("uri",uri.toString()).put("size",size).put("sha",sha).put("name",original);
            save(marker,ref);
        }
        Uri uri=Uri.parse(ref.getString("uri"));
        boolean pending;
        try(Cursor row=resolver.query(uri,new String[]{"is_pending","relative_path"},null,null,null)){
            if(row==null||!row.moveToFirst()||!ALBUM.equals(row.getString(1)))throw new IOException("找不到指定相簿項目，已保留手機原檔");
            pending=row.getInt(0)!=0;
        }
        if(pending){
            try(FileInputStream in=new FileInputStream(staged);OutputStream out=resolver.openOutputStream(uri,"wt")){
                if(out==null)throw new IOException("無法寫入相簿");
                byte[] buffer=new byte[262144];int n;
                while((n=in.read(buffer))!=-1)out.write(buffer,0,n);
            }
        }
        if(!sha.equals(DriveApi.hashes(()->open(resolver,uri),size,()->false)[0]))throw new IOException("相簿原圖校驗失敗，已保留手機原檔");
        if(pending){
            ContentValues ready=new ContentValues();ready.put(MediaStore.Images.Media.IS_PENDING,0);
            if(resolver.update(uri,ready,null,null)!=1)throw new IOException("未能發佈相簿照片");
        }
        save(marker,ref.put("published",true));
        if(!staged.delete())throw new IOException("相簿原圖已校驗，舊副本仍在");
    }
}
