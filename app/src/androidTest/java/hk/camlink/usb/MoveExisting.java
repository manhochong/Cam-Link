package hk.camlink.usb;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import java.io.*;
import java.util.Locale;
import org.json.JSONObject;

/** Explicit one-device migration. Only finalized session JPGs are eligible. */
final class MoveExisting {
    static void run(Instrumentation test){
        Context c=test.getTargetContext();
        Bundle result=new Bundle();
        int moved=0,failed=0;
        long bytes=0;
        try{
            File root=new File(c.getExternalFilesDir(null),"sessions");
            File[] dirs=root.listFiles(f->f.isDirectory()&&f.getName().matches("[0-9]{8}-[0-9]{6}-[0-9a-f]{6}"));
            if(dirs==null)throw new IOException("無法讀取接收紀錄");
            for(File dir:dirs){
                File[] photos=new File(dir,"jpg").listFiles(f->f.isFile()&&f.getName().toLowerCase(Locale.ROOT).endsWith(".jpg"));
                if(photos==null)continue;
                for(File photo:photos){
                    try{
                        JpegCheck checked=JpegCheck.check(photo,photo.length());
                        Gallery.move(c,photo,photo.getName().replaceFirst("^[0-9]+_",""),checked.bytes,checked.sha256);
                        // Verify the exact source the uploader will reopen after removal of the staging file.
                        if(!checked.sha256.equals(DriveApi.hashes(Gallery.source(c,photo),checked.bytes,()->false)[0]))
                            throw new IOException("讀回不符");
                        bytes+=checked.bytes;moved++;
                    }catch(Exception e){
                        failed++;Bundle line=new Bundle();
                        line.putString("stream","FAILED "+dir.getName()+"/"+photo.getName()+" "+e.getClass().getSimpleName()+"\n");
                        test.sendStatus(0,line);
                    }
                }
            }
            result.putString("stream","GALLERY moved="+moved+" verified_bytes="+bytes+" failed="+failed+"\n");
            test.finish(failed==0?-1:0,result);
        }catch(Exception e){result.putString("stream","FAIL "+e.getClass().getSimpleName()+"\n");test.finish(0,result);}
    }
}
