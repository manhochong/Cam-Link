package hk.camlink.usb;

import android.hardware.usb.*;
import java.io.*;
import java.util.Locale;
import java.nio.ByteBuffer;
import java.util.concurrent.TimeoutException;

public final class UsbWire implements Ptp.Wire {
    private final UsbDeviceConnection connection;
    private final UsbInterface intf;
    private final UsbEndpoint input,output,event;
    private int bulkBytes=NativeUsb.BULK_BYTES;
    private volatile boolean closed;
    private UsbRequest eventRequest;
    private ByteBuffer eventBuffer;
    private boolean eventQueued;
    static boolean candidate(UsbDevice device){
        CameraProfile profile=CameraProfile.find(device.getVendorId());
        if(profile==null)return false;
        if(profile==CameraProfile.LUMIX)return true;
        for(int i=0;i<device.getInterfaceCount();i++)if(stillImage(device.getInterface(i)))return true;
        return false;
    }
    private static boolean stillImage(UsbInterface f){
        return f.getInterfaceClass()==6&&f.getInterfaceSubclass()==1&&f.getInterfaceProtocol()==1;
    }
    public UsbWire(UsbManager manager,UsbDevice device)throws IOException {
        if(!NativeUsb.available())throw new IOException("無法載入 USB 診斷元件，請重新安裝完整 APK");
        UsbInterface selected=null;UsbEndpoint in=null,out=null,evt=null;
        for(int i=0;i<device.getInterfaceCount();i++) {
            UsbInterface f=device.getInterface(i);
            // Only the documented Still Image PTP interface. Unknown vendor protocols are diagnostic-only.
            if(!stillImage(f))continue;
            UsbEndpoint a=null,b=null,c=null;
            for(int j=0;j<f.getEndpointCount();j++) {
                UsbEndpoint ep=f.getEndpoint(j);
                if(ep.getType()==UsbConstants.USB_ENDPOINT_XFER_BULK){if(ep.getDirection()==UsbConstants.USB_DIR_IN)a=ep;else b=ep;}
                if(ep.getType()==UsbConstants.USB_ENDPOINT_XFER_INT&&ep.getDirection()==UsbConstants.USB_DIR_IN)c=ep;
            }
            if(a!=null&&b!=null){selected=f;in=a;out=b;evt=c;break;}
        }
        if(selected==null)throw new IOException("找不到相機的 USB 相片傳輸介面。請檢查 USB 模式；LUMIX 請選 PC(Tether)。");
        connection=manager.openDevice(device);
        if(connection==null)throw new IOException("USB 開啟失敗，請重新授權／檢查線材");
        if(!connection.claimInterface(selected,true)){connection.close();throw new IOException("USB 介面被其他 App 使用");}
        intf=selected;input=in;output=out;event=evt;bulkBytes=NativeUsb.BULK_BYTES;
        if(event!=null){eventBuffer=ByteBuffer.allocate(Math.max(512,event.getMaxPacketSize()));eventRequest=new UsbRequest();if(!eventRequest.initialize(connection,event)){close();throw new IOException("USB event request initialization failed");}}
    }
    @Override public int read(byte[] b)throws IOException {
        if(closed)throw new IOException("USB disconnected");
        int request=Math.min(b.length,bulkBytes);long began=System.nanoTime();
        int n=NativeUsb.bulk(connection.getFileDescriptor(),input.getAddress(),b,request,5000);
        // Flip 6 returns ENOMEM for a 64 KB URB after the first large photo. Keep the session and use 16 KB.
        if(n==-12&&bulkBytes>16384){bulkBytes=16384;request=Math.min(b.length,bulkBytes);began=System.nanoTime();n=NativeUsb.bulk(connection.getFileDescriptor(),input.getAddress(),b,request,5000);}
        if(n<0)throw new IOException(String.format(Locale.US,"USB IN %02X %s requested=%d elapsed=%.0fms；已停止本輪，請拔線並重開相機後再測。",input.getAddress(),NativeUsb.error(n),request,(System.nanoTime()-began)/1e6));
        return n;
    }
    @Override public void write(byte[] b)throws IOException {
        if(closed)throw new IOException("USB disconnected");
        long began=System.nanoTime();
        int n=NativeUsb.bulk(connection.getFileDescriptor(),output.getAddress(),b,b.length,3000);
        if(n!=b.length)throw new IOException(String.format(Locale.US,
            "USB 命令傳送失敗：op=%04X tx=%d endpoint=%02X %s requested=%d elapsed=%.0fms；請拔線並重開相機後再測。",
            Ptp.u16(b,6),Ptp.u32(b,8),output.getAddress(),NativeUsb.error(n),b.length,(System.nanoTime()-began)/1e6));
    }
    public boolean hasEvents(){return event!=null;}
    public byte[] event()throws IOException {
        if(closed)throw new IOException("USB disconnected");
        if(event==null)return null;
        if(!eventQueued){eventBuffer.clear();if(!eventRequest.queue(eventBuffer))throw new IOException("USB interrupt queue failed");eventQueued=true;}
        try {
            UsbRequest completed=connection.requestWait(500);
            if(completed==null)throw new IOException("USB event connection closed");
            if(completed!=eventRequest)throw new IOException("Unexpected USB request completion");
            eventQueued=false;int n=eventBuffer.position();byte[] result=new byte[n];eventBuffer.flip();eventBuffer.get(result);return result;
        }catch(TimeoutException e){return null;}
    }
    @Override public synchronized void close(){if(closed)return;closed=true;if(eventRequest!=null){eventRequest.cancel();eventRequest.close();}connection.releaseInterface(intf);connection.close();}
    public static String describe(UsbDevice d) {
        StringBuilder s=new StringBuilder(String.format(Locale.US,"VID=%04X PID=%04X product=%s manufacturer=%s USB=%s\n",d.getVendorId(),d.getProductId(),d.getProductName(),d.getManufacturerName(),d.getVersion()));
        for(int i=0;i<d.getInterfaceCount();i++){
            UsbInterface f=d.getInterface(i);
            s.append(String.format(Locale.US,"interface=%d alt=%d class=%02X subclass=%02X protocol=%02X\n",f.getId(),f.getAlternateSetting(),f.getInterfaceClass(),f.getInterfaceSubclass(),f.getInterfaceProtocol()));
            for(int j=0;j<f.getEndpointCount();j++){UsbEndpoint e=f.getEndpoint(j);s.append(String.format(Locale.US,"  endpoint=%02X type=%d packet=%d interval=%d\n",e.getAddress(),e.getType(),e.getMaxPacketSize(),e.getInterval()));}
        }
        return s.toString();
    }
}
