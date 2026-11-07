package hk.camlink.usb;

import android.content.*;
import android.net.*;
import android.util.Base64;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.*;
import javax.net.ssl.*;

final class PcLink {
    static final int PORT=9443;
    static String base(String input)throws IOException{
        String ip=input.trim().replaceFirst(":9443$","");
        if(!ip.matches("(\\d{1,3}\\.){3}\\d{1,3}"))throw new IOException("請輸入電腦顯示的 IPv4 地址");
        for(String part:ip.split("\\."))if(Integer.parseInt(part)>255)throw new IOException("IP 地址無效");
        return "https://"+ip+":"+PORT+"/inbox/";
    }
    static Network wifi(Context ctx){
        ConnectivityManager cm=ctx.getSystemService(ConnectivityManager.class);
        for(Network n:cm.getAllNetworks()){
            NetworkCapabilities cap=cm.getNetworkCapabilities(n);
            if(cap!=null&&cap.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))return n;
        }
        return null;
    }
    private static SSLContext context(String pin,String[] observed)throws GeneralSecurityException{
        X509TrustManager trust=new X509TrustManager(){
            public X509Certificate[] getAcceptedIssuers(){return new X509Certificate[0];}
            public void checkClientTrusted(X509Certificate[] c,String a)throws CertificateException{throw new CertificateException();}
            public void checkServerTrusted(X509Certificate[] chain,String a)throws CertificateException{
                if(chain==null||chain.length==0)throw new CertificateException();
                chain[0].checkValidity();
                try{
                    String hash=DriveApi.hex(MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded()));
                    if(observed!=null)observed[0]=hash;
                    if(pin==null||!hash.equals(pin))throw new CertificateException("請核對電腦指紋");
                }catch(NoSuchAlgorithmException e){throw new CertificateException(e);}
            }
        };
        SSLContext ssl=SSLContext.getInstance("TLS");ssl.init(null,new TrustManager[]{trust},null);return ssl;
    }
    static String probe(Context ctx,String base)throws Exception{
        URL address=new URL(base);String[] seen={null};Network network=wifi(ctx);
        if(network==null)throw new IOException("請先把手機接上電腦所在的 Wi-Fi");
        try(Socket plain=network.getSocketFactory().createSocket()){
            plain.connect(new InetSocketAddress(address.getHost(),PORT),6000);plain.setSoTimeout(6000);
            try(SSLSocket tls=(SSLSocket)context(null,seen).getSocketFactory().createSocket(plain,address.getHost(),PORT,true)){
                try{tls.startHandshake();}catch(SSLException e){if(seen[0]==null)throw e;}
            }
        }
        if(seen[0]==null)throw new IOException("電腦未提供憑證");return seen[0];
    }
    static HttpsURLConnection connection(URL url,String pin,Network network)throws Exception{
        HttpsURLConnection c=(HttpsURLConnection)(network==null?url.openConnection():network.openConnection(url));
        c.setSSLSocketFactory(context(pin,null).getSocketFactory());
        // The operator confirmed this computer's exact certificate, independently of its LAN IP.
        c.setHostnameVerifier((host,session)->host.equals(url.getHost()));return c;
    }
    static void authenticate(Context ctx,String base,String password,String pin)throws Exception{
        Network network=wifi(ctx);if(network==null)throw new IOException("請連接 Wi-Fi");
        HttpsURLConnection c=connection(new URL(base),pin,network);
        try{
            c.setConnectTimeout(6000);c.setReadTimeout(6000);c.setInstanceFollowRedirects(false);c.setRequestMethod("HEAD");
            c.setRequestProperty("Authorization","Basic "+Base64.encodeToString(("camlink:"+password).getBytes(StandardCharsets.UTF_8),Base64.NO_WRAP));
            if(c.getResponseCode()!=200||!"1".equals(c.getHeaderField("X-CamLink-Receiver")))throw new IOException("配對碼或接收器不符");
        }finally{c.disconnect();}
    }
}
