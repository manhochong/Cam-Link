package hk.camlink.usb;

import android.content.Context;
import android.net.*;
import java.io.*;
import java.net.*;
import java.util.Map;

/** Drive requests use a validated Internet network, independently of camera Wi-Fi. */
final class CloudNetwork implements DriveApi.Transport,AutoCloseable {
    static final class Waiting extends IOException {Waiting(String message){super(message);}}
    private final Context context;private final ConnectivityManager cm;
    private ConnectivityManager.NetworkCallback cellular;
    private boolean closed;private long nextRequest;
    private Network cached;private long selectedAt=-1000;private boolean selectedWifiOnly;
    private volatile String label="等待可上網的網絡";
    CloudNetwork(Context context){this.context=context.getApplicationContext();cm=context.getSystemService(ConnectivityManager.class);}
    private boolean wifiOnly(){return CloudStore.prefs(context).getBoolean("wifi",false);}
    private int score(Network n,Network active,boolean vpn,boolean wifiOnly){
        NetworkCapabilities c=cm.getNetworkCapabilities(n);if(c==null)return -1;
        return InternetRoute.score(c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            !c.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED),c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
            c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),c.hasTransport(NetworkCapabilities.TRANSPORT_VPN),n.equals(active),vpn,wifiOnly);
    }
    synchronized Network selected(){
        if(closed)return null;
        boolean wifiOnly=wifiOnly();long now=android.os.SystemClock.elapsedRealtime();
        if(wifiOnly==selectedWifiOnly&&now-selectedAt<250)return cached;
        Network active=cm.getActiveNetwork();NetworkCapabilities ac=active==null?null:cm.getNetworkCapabilities(active);
        boolean vpn=ac!=null&&ac.hasTransport(NetworkCapabilities.TRANSPORT_VPN);
        Network best=null;int bestScore=-1;
        for(Network n:cm.getAllNetworks()){int score=score(n,active,vpn,wifiOnly);if(score>bestScore){best=n;bestScore=score;}}
        boolean needCell=!wifiOnly&&!vpn&&bestScore<70;
        if(!needCell)releaseCell();
        else if(cellular==null&&android.os.SystemClock.elapsedRealtime()>=nextRequest){
            ConnectivityManager.NetworkCallback callback=new ConnectivityManager.NetworkCallback();
            try{cm.requestNetwork(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),callback);cellular=callback;}
            catch(SecurityException|IllegalArgumentException e){nextRequest=android.os.SystemClock.elapsedRealtime()+60000;}
        }
        if(best==null)label=wifiOnly?"等待可上網的 Wi-Fi；相機 Wi-Fi 無法上傳，可關閉「只用 Wi-Fi」":vpn?"等待 VPN 網絡恢復":"等待 4G／5G 或可上網的 Wi-Fi；請開啟流動數據";
        else {NetworkCapabilities c=cm.getNetworkCapabilities(best);label=c!=null&&c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)?"VPN":c!=null&&c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)?"4G／5G":c!=null&&c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)?"Wi-Fi":"網際網路";}
        cached=best;selectedAt=now;selectedWifiOnly=wifiOnly;return best;
    }
    /** Play services uses the process default when refreshing a token. Camera sockets bind themselves and are unaffected once this is closed. */
    AutoCloseable pinProcess()throws InterruptedException,Waiting{
        Network network=awaitReady();Network previous=cm.getBoundNetworkForProcess();
        try{if(!cm.bindProcessToNetwork(network))throw new Waiting("無法把登入要求送到可上網的網絡");}
        catch(SecurityException e){throw new Waiting("無法把登入要求送到可上網的網絡");}
        return ()->{try{cm.bindProcessToNetwork(previous);}catch(RuntimeException ignored){}};
    }
    String label(){return label;}
    boolean available(){return selected()!=null;}
    boolean wifi(){Network n=selected();NetworkCapabilities c=n==null?null:cm.getNetworkCapabilities(n);return c!=null&&c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)&&!c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);}
    private synchronized boolean usable(Network n){
        if(closed)return false;Network active=cm.getActiveNetwork();NetworkCapabilities c=active==null?null:cm.getNetworkCapabilities(active);
        return score(n,active,c!=null&&c.hasTransport(NetworkCapabilities.TRANSPORT_VPN),wifiOnly())>=0;
    }
    Network awaitReady()throws InterruptedException,Waiting{
        for(int i=0;i<40;i++){Network n=selected();if(n!=null)return n;synchronized(this){if(closed)break;}Thread.sleep(250);}
        throw new Waiting(label);
    }
    @Override public DriveApi.Reply send(String method,String url,Map<String,String> headers,DriveApi.Body body)throws Exception{
        DriveApi.validateUrl(url);Network network=awaitReady();
        DriveApi.Body guarded=body==null?null:new DriveApi.Body(){
            public long length(){return body.length();}
            public void write(OutputStream output)throws Exception{body.write(new FilterOutputStream(output){
                private long checkedAt=-1000;private boolean checkedWifiOnly;
                private void check()throws Waiting{long now=android.os.SystemClock.elapsedRealtime();boolean only=wifiOnly();if(only!=checkedWifiOnly||now-checkedAt>=250){if(!usable(network))throw new Waiting("上傳網絡已切換，保留進度等待恢復");checkedAt=now;checkedWifiOnly=only;}}
                @Override public void write(byte[] b,int off,int len)throws IOException{check();out.write(b,off,len);}
                @Override public void write(int b)throws IOException{check();out.write(b);}
            });}
        };
        try{return new DriveApi.Http(u->{if(!usable(network))throw new Waiting("等待上傳網絡恢復");return (HttpURLConnection)network.openConnection(u);}).send(method,url,headers,guarded);}
        catch(IOException e){if(!usable(network))throw new Waiting("上傳網絡已切換，保留進度等待恢復");throw e;}
    }
    private void releaseCell(){if(cellular!=null){try{cm.unregisterNetworkCallback(cellular);}catch(IllegalArgumentException ignored){}cellular=null;}}
    @Override public synchronized void close(){closed=true;releaseCell();}
}
