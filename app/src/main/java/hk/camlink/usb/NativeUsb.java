package hk.camlink.usb;

import android.system.Os;

public final class NativeUsb {
    private static final boolean LOADED;
    static {boolean loaded;try{System.loadLibrary("camlink_usb");loaded=true;}catch(UnsatisfiedLinkError e){loaded=false;}LOADED=loaded;}
    private NativeUsb(){}
    public static boolean available(){return LOADED;}
    /** Matches the usbfs buffer in usb_diag.c. Larger transfers need both sides changed together. */
    public static final int BULK_BYTES=65536;
    public static native int bulk(int fd,int endpoint,byte[] buffer,int length,int timeout);
    public static String error(int result){return result<0?"errno="+(-result)+" ("+Os.strerror(-result)+")":"result="+result;}
    public static String selfTest(){
        if(!LOADED)return "native USB diagnostics unavailable";
        byte[] b=new byte[1];
        int invalidFd=bulk(-1,0x81,b,1,1),invalidLength=bulk(-1,0x81,b,2,1);
        return invalidFd==-9&&invalidLength==-22?"PASS EBADF / EINVAL (no USB I/O)":"FAIL fd="+invalidFd+" length="+invalidLength;
    }
}
