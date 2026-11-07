package hk.camlink.usb;

import android.app.*;
import android.graphics.Bitmap;
import android.os.Bundle;
import java.io.*;
import java.net.*;
import java.nio.file.Files;
import java.security.cert.Certificate;
import java.util.Arrays;
import java.util.concurrent.*;
import javax.net.ssl.HttpsURLConnection;

/** Test private temporary files only. No account, real endpoint, album, or capture settings. */
final class WirelessChecks {
    static void pc(Instrumentation test){
        Bundle result=new Bundle();android.content.Context ctx=test.getTargetContext();
        File pair=new File(ctx.getExternalFilesDir(null),"pc-fixture.tmp"),jpg=null;
        try{
            java.util.List<String> args=Files.readAllLines(pair.toPath());if(args.size()<3)throw new IOException("Fixture missing");
            String pin=args.get(0),pass=args.get(1),ip=args.get(2);
            boolean lan=!"127.0.0.1".equals(ip);String base=PcLink.base(ip);
            android.net.Network net=lan?PcLink.wifi(ctx):null;
            if(lan){if(net==null)throw new IOException("No Wi-Fi");if(!pin.equals(PcLink.probe(ctx,base)))throw new IOException("Wrong fingerprint");PcLink.authenticate(ctx,base,pass,pin);}
            jpg=File.createTempFile("pc-test",".jpg",ctx.getCacheDir());
            Bitmap bmp=Bitmap.createBitmap(48,32,Bitmap.Config.ARGB_8888);bmp.eraseColor(0xffe39b37);
            try(OutputStream out=new FileOutputStream(jpg)){bmp.compress(Bitmap.CompressFormat.JPEG,92,out);}finally{bmp.recycle();}
            File source=jpg;String sha=JpegCheck.check(jpg,jpg.length()).sha256;
            String auth="Basic "+android.util.Base64.encodeToString(("camlink:"+pass).getBytes("UTF-8"),android.util.Base64.NO_WRAP);
            URL target=new URL(base+"receipt.JPG");
            for(int i=0;i<2;i++)DavBackup.transfer(target,auth,()->new FileInputStream(source),source.length(),sha,pin,net,()->false);
            boolean rejected=false;try{DavBackup.transfer(target,auth,()->new FileInputStream(source),source.length(),sha.replaceAll(".","0"),pin,net,()->false);}catch(IOException expected){rejected=true;}
            if(!rejected)throw new AssertionError("bad hash accepted");
            result.putString("stream","PASS Flip6 to Windows "+(lan?"Wi-Fi":"USB port relay")+" receipt, retry, mismatch rejection; SHA256 "+sha+"\n");
            test.finish(Activity.RESULT_OK,result);
        }catch(Throwable e){result.putString("stream","FAIL "+e.getClass().getSimpleName()+" "+e.getMessage()+"\n");test.finish(Activity.RESULT_CANCELED,result);}
        finally{pair.delete();if(jpg!=null)jpg.delete();}
    }
    static void run(Instrumentation test){
        StringBuilder log=new StringBuilder();Bundle result=new Bundle();File file=null;
        try{
            file=File.createTempFile("wireless-test",".jpg",test.getTargetContext().getCacheDir());
            Bitmap bmp=Bitmap.createBitmap(64,48,Bitmap.Config.ARGB_8888);
            try(FileOutputStream out=new FileOutputStream(file)){bmp.compress(Bitmap.CompressFormat.JPEG,96,out);}finally{bmp.recycle();}
            byte[] original=Files.readAllBytes(file.toPath());
            String sha=JpegCheck.check(file,file.length()).sha256;
            final File source=file;
            for(int code:new int[]{201,412,302,401}){
                for(boolean corrupt:new boolean[]{false,true}){
                    boolean shouldPass=(code==201||code==412)&&!corrupt;
                    byte[] remote=original.clone();if(corrupt)remote[5]^=1;
                    URL url=new URL(null,"https://test.invalid/dav/file",new URLStreamHandler(){
                        protected URLConnection openConnection(URL u){return new Endpoint(u,code,remote,original);}
                    });
                    boolean pass=false;
                    try{DavBackup.transfer(url,"Basic fixture",()->new FileInputStream(source),source.length(),sha,()->false);pass=true;}
                    catch(IOException expected){}
                    if(pass!=shouldPass)throw new AssertionError("WebDAV response "+code+" / corrupt "+corrupt);
                }
            }
            log.append("PASS WebDAV simulated PUT/readback, existing file, corruption, redirect, auth rejection\n");
        }catch(Throwable e){log.append("FAIL ").append(e).append('\n');}
        finally{if(file!=null)file.delete();}
        result.putString("stream",log.toString());test.finish(log.indexOf("FAIL")<0?Activity.RESULT_OK:Activity.RESULT_CANCELED,result);
    }
    private static final class Endpoint extends HttpsURLConnection{
        final byte[] remote,expected;final int code;
        final ByteArrayOutputStream sent=new ByteArrayOutputStream();
        Endpoint(URL url,int code,byte[] remote,byte[] expected){super(url);this.code=code;this.remote=remote;this.expected=expected;}
        public int getResponseCode(){
            if(getInstanceFollowRedirects())throw new AssertionError("credential redirect enabled");
            if("PUT".equals(method)){
                if(!"*".equals(getRequestProperty("If-None-Match"))||!Arrays.equals(sent.toByteArray(),expected))throw new AssertionError("unsafe PUT");
                return code;
            }
            return 200;
        }
        public InputStream getInputStream(){return new ByteArrayInputStream(remote);}
        public OutputStream getOutputStream(){return sent;}
        public String getCipherSuite(){return "fixture";}
        public Certificate[] getLocalCertificates(){return null;}
        public Certificate[] getServerCertificates(){return null;}
        public void connect(){} public void disconnect(){} public boolean usingProxy(){return false;}
    }
}
