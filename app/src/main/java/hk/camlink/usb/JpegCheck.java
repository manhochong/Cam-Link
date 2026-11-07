package hk.camlink.usb;

import java.io.*;
import java.security.*;
import java.util.Locale;

/** Streaming structure + digest check, not an entropy decoder. Card hash comparison is authoritative. */
public final class JpegCheck {
    public final long bytes,trailingBytes;public final int width,height;public final String sha256,md5;
    private JpegCheck(long b,int w,int h,String hash,String md5,long tail){bytes=b;width=w;height=h;sha256=hash;this.md5=md5;trailingBytes=tail;}
    private static int get(InputStream in)throws IOException{int n=in.read();if(n<0)throw new EOFException("JPEG truncated");return n;}
    public static JpegCheck check(File f,long expected)throws IOException {
        if(expected<=0||f.length()!=expected)throw new IOException("Size mismatch: expected="+expected+" actual="+f.length());
        MessageDigest sha,md5;try{sha=MessageDigest.getInstance("SHA-256");md5=MessageDigest.getInstance("MD5");}catch(NoSuchAlgorithmException e){throw new IOException(e);}
        int w=0,h=0;long trailing=0;boolean scan=false,entropy=false,ended=false;
        InputStream hashed=new FilterInputStream(new FileInputStream(f)){
            @Override public int read()throws IOException{int b=in.read();if(b>=0){sha.update((byte)b);md5.update((byte)b);}return b;}
            @Override public int read(byte[] buffer,int offset,int length)throws IOException{int n=in.read(buffer,offset,length);if(n>0){sha.update(buffer,offset,n);md5.update(buffer,offset,n);}return n;}
        };
        try(InputStream in=new BufferedInputStream(hashed,256*1024)) {
            if(get(in)!=255||get(in)!=216)throw new IOException("Not a full JPEG (SOI missing)");
            while(!ended) {
                int marker;
                if(entropy) {
                    do { while(get(in)!=255){} do{marker=get(in);}while(marker==255); }while(marker==0||(marker>=0xd0&&marker<=0xd7));
                    entropy=false;
                } else {if(get(in)!=255)throw new IOException("Invalid JPEG marker");do{marker=get(in);}while(marker==255);}
                if(marker==0xd9){ended=true;break;}
                if(marker==0xd8||marker==0||marker==1||(marker>=0xd0&&marker<=0xd7))throw new IOException("Unexpected JPEG marker");
                int length=(get(in)<<8)|get(in);if(length<2)throw new IOException("Invalid JPEG segment length");
                byte[] segment=new byte[length-2];int n=0;while(n<segment.length){int c=in.read(segment,n,segment.length-n);if(c<0)throw new EOFException("JPEG segment truncated");n+=c;}
                boolean sof=(marker>=0xc0&&marker<=0xcf&&marker!=0xc4&&marker!=0xc8&&marker!=0xcc);
                if(sof){if(segment.length<6)throw new IOException("JPEG SOF truncated");h=((segment[1]&255)<<8)|(segment[2]&255);w=((segment[3]&255)<<8)|(segment[4]&255);}
                if(marker==0xda){if(w<=0||h<=0||segment.length<4)throw new IOException("JPEG SOS without frame");scan=true;entropy=true;}
            }
            if(!scan||w<=0||h<=0)throw new IOException("JPEG has no image scan");
            // EOI terminates the codestream, not necessarily the containing camera file.
            // Preserve and hash every trailing byte (including nonzero alignment/auxiliary data).
            // Never trim/rewrite the original. Card SHA-256 comparison remains authoritative.
            byte[] tail=new byte[65536];int count;
            while((count=in.read(tail))!=-1)trailing+=count;
        }
        return new JpegCheck(expected,w,h,hex(sha),hex(md5),trailing);
    }
    private static String hex(MessageDigest digest){StringBuilder hex=new StringBuilder();for(byte b:digest.digest())hex.append(String.format(Locale.US,"%02x",b&255));return hex.toString();}
}
