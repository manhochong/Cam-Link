package hk.camlink.usb;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.awt.image.BufferedImage;
import javax.imageio.*;
import javax.imageio.stream.ImageInputStream;

/** Recheck actual received originals on the workstation; does not modify source files. */
public final class CameraFilesCheck {
    public static void main(String[] args)throws Exception {
        File[] files=Path.of(args[0]).toFile().listFiles((d,n)->n.endsWith(".part")||n.toLowerCase(Locale.ROOT).endsWith(".jpg"));
        if(files==null||files.length==0)throw new IOException("No camera files");Arrays.sort(files);
        System.out.println("file,bytes,width,height,trailing_bytes,sha256,decode_warnings");
        for(File file:files){
            JpegCheck check=JpegCheck.check(file,file.length());List<String> warnings=new ArrayList<>();
            try(ImageInputStream in=ImageIO.createImageInputStream(file)){
                Iterator<ImageReader> readers=ImageIO.getImageReaders(in);if(!readers.hasNext())throw new IOException("No decoder: "+file);
                ImageReader reader=readers.next();
                try{reader.addIIOReadWarningListener((source,warning)->warnings.add(warning));reader.setInput(in);BufferedImage decoded=reader.read(0);
                    if(decoded==null||decoded.getWidth()!=check.width||decoded.getHeight()!=check.height)throw new IOException("Decode dimensions mismatch: "+file);
                    decoded.flush();
                }finally{reader.dispose();}
            }
            System.out.printf(Locale.US,"%s,%d,%d,%d,%d,%s,%d%n",file.getName(),check.bytes,check.width,check.height,check.trailingBytes,check.sha256,warnings.size());
            if(!warnings.isEmpty())throw new IOException("Decoder warning: "+warnings);
        }
    }
}
