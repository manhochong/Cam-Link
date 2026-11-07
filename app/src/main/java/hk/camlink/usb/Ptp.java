package hk.camlink.usb;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Small read-only PTP initiator. No capture, delete or property mutation commands. */
public final class Ptp {
    public static final int OK=0x2001, BUSY=0x2019;
    public interface Wire extends Closeable {
        int read(byte[] b) throws IOException;
        void write(byte[] b) throws IOException;
    }
    public interface Trace { void line(String s); }
    public static final class ResponseException extends IOException {
        public final int code;
        ResponseException(int op, int code) { super(String.format(Locale.US,"PTP %04X → %04X",op,code)); this.code=code; }
    }
    public static final class Result {
        public final byte[] data;
        public final long bytes;
        Result(byte[] data,long bytes) { this.data=data;this.bytes=bytes; }
    }
    private final Wire wire;
    private final Trace trace;
    private final byte[] buffer=new byte[256*1024];
    private int pos,limit,transaction;
    private long readCalls,wireBytes;
    private boolean healthy=true;
    private boolean unfilteredInventory;
    public Ptp(Wire wire,Trace trace) { this.wire=wire;this.trace=trace; }
    public boolean healthy() { return healthy; }
    /** Positive byte count, or -1 when an unknown-length data phase has ended. */
    private int readSome(byte[] out,int offset,int length) throws IOException {
        if(pos==limit) {
            int zeros=0;
            do { readCalls++;limit=wire.read(buffer);if(limit>0)wireBytes+=limit; } while(limit==0 && ++zeros<8);
            pos=0;
            if(limit<0){limit=0;return -1;}
            if(limit==0) throw new EOFException("USB read timeout/disconnected");
        }
        int count=Math.min(length,limit-pos);
        System.arraycopy(buffer,pos,out,offset,count);pos+=count;return count;
    }
    private byte[] exact(int n) throws IOException {
        byte[] b=new byte[n];int done=0;
        while(done<n){int count=readSome(b,done,n-done);if(count<0)throw new EOFException("USB read timeout/disconnected");done+=count;}
        return b;
    }
    public synchronized Result command(int op,OutputStream sink,long maxBytes,int...args) throws IOException {
        if(!healthy) throw new IOException("PTP stream invalid; reconnect required");
        if(args.length>5) throw new IllegalArgumentException("PTP params");
        int id=transaction++;
        byte[] cmd=new byte[12+4*args.length];
        put32(cmd,0,cmd.length);put16(cmd,4,1);put16(cmd,6,op);put32(cmd,8,id);
        for(int i=0;i<args.length;i++)put32(cmd,12+i*4,args[i]);
        long started=System.nanoTime();
        ByteArrayOutputStream memory=sink==null?new ByteArrayOutputStream():null;
        OutputStream target=sink==null?memory:sink;
        long total=0;boolean dataSeen=false;
        long initialReads=readCalls,initialBytes=wireBytes;
        String lastHeader="none";
        try {
            StringBuilder params=new StringBuilder();for(int arg:args)params.append(String.format(Locale.US," %08X",arg));
            trace.line(String.format(Locale.US,"BEGIN op=%04X tx=%d command_bytes=%d params=%s",op,id,cmd.length,params));
            wire.write(cmd);
            while(true) {
                byte[] h=exact(12);long len=u32(h,0);int type=u16(h,4),code=u16(h,6);
                lastHeader=String.format(Locale.US,"len=%d type=%04X code=%04X rx_tx=%d expected_tx=%d header=%s buffered=%d reads=%d wire_bytes=%d",len,type,code,u32(h,8),Integer.toUnsignedLong(id),hexHeader(h),limit-pos,readCalls-initialReads,wireBytes-initialBytes);
                trace.line("CONTAINER op="+String.format(Locale.US,"%04X ",op)+lastHeader);
                if(len<12 || u32(h,8)!=Integer.toUnsignedLong(id)) throw new IOException("PTP invalid length/transaction: "+lastHeader);
                if(type==2) {
                    boolean unknown=len==UNKNOWN_SIZE;
                    if(dataSeen||code!=op||(!unknown&&len-12>maxBytes))throw new IOException("PTP invalid data container/size");
                    dataSeen=true;byte[] copy=new byte[256*1024];
                    if(unknown){
                        while(true){
                            int room=total>=maxBytes?0:(int)Math.min(copy.length,maxBytes-total);
                            int n=readSome(copy,0,room==0?1:room);
                            if(n<0)break;
                            if(room==0)throw new IOException("PTP invalid data container/size");
                            target.write(copy,0,n);total+=n;
                        }
                    }else{
                        long remaining=len-12;
                        while(remaining>0) { int n=readSome(copy,0,(int)Math.min(copy.length,remaining));if(n<0)throw new EOFException("USB read timeout/disconnected");target.write(copy,0,n);remaining-=n;total+=n; }
                    }
                } else if(type==3) {
                    if(len>32 || (len-12)%4!=0)throw new IOException("PTP invalid response length");
                    exact((int)len-12);
                    trace.line(String.format(Locale.US,"op=%04X tx=%d rc=%04X bytes=%d ms=%.1f",op,id,code,total,(System.nanoTime()-started)/1e6));
                    if(code!=OK)throw new ResponseException(op,code);
                    return new Result(memory==null?null:memory.toByteArray(),total);
                } else throw new IOException("Unexpected PTP container "+type);
            }
        } catch(ResponseException e) { throw e;
        } catch(IOException|RuntimeException e) {
            healthy=false;
            trace.line(String.format(Locale.US,"IO_FAILURE op=%04X tx=%d data_bytes=%d reads=%d wire_bytes=%d buffered=%d last_header=[%s] error=%s",op,id,total,readCalls-initialReads,wireBytes-initialBytes,Math.max(0,limit-pos),lastHeader,e));
            throw e;
        }
    }
    private static String hexHeader(byte[] h){StringBuilder s=new StringBuilder();for(byte b:h)s.append(String.format(Locale.US,"%02X",b&255));return s.toString();}
    public byte[] data(int op,int...args)throws IOException{return command(op,null,32L*1024*1024,args).data;}
    // OpenSession uses transaction zero; subsequent in-session transactions begin at one.
    public synchronized void open()throws IOException{transaction=0;command(0x1002,null,0,1);}
    public synchronized DeviceInfo initialize()throws IOException{open();return deviceInfo();}
    public void closeSession() { if(healthy)try{command(0x1003,null,0);}catch(IOException|RuntimeException ignored){} }
    public int[] storages()throws IOException{return new Reader(data(0x1004)).array32();}
    public int[] handles(int storage)throws IOException{return new Reader(data(0x1007,storage,0,0)).array32();}
    /** Some cameras expose storage IDs but reject the storage filter on GetObjectHandles. */
    public synchronized int[] inventory()throws IOException {
        if(unfilteredInventory)return unique(handles(-1));
        int[] stores=storages();
        if(stores.length==0)throw new IOException("相機沒有可讀取儲存區；確認已插卡並選用可拍攝及讀取卡檔的 USB 模式");
        LinkedHashSet<Integer> found=new LinkedHashSet<>();
        for(int store:stores){
            try{for(int handle:handles(store))found.add(handle);}
            catch(ResponseException e){
                if(e.code!=0x2006)throw e;
                trace.line("INVENTORY_FALLBACK ParameterNotSupported: storage=FFFFFFFF format=0 association=0");
                int[] all=unique(handles(-1));
                // Cache only after a complete successful response. Discard partial per-storage results.
                unfilteredInventory=true;return all;
            }
        }
        return found.stream().mapToInt(Integer::intValue).toArray();
    }
    private static int[] unique(int[] handles){return Arrays.stream(handles).distinct().toArray();}
    public Info info(int handle)throws IOException{return new Info(handle,data(0x1008,handle));}
    public static final long UNKNOWN_SIZE=0xFFFFFFFFL,MAX_OBJECT=512L*1024*1024;
    /** Bytes to read. -1 means the camera has not reported a size yet and the caller should retry. */
    public static long objectBudget(long declared,int attempts)throws IOException{
        if(declared==UNKNOWN_SIZE)return MAX_OBJECT;
        if(declared<=0){if(attempts<6)return -1;throw new IOException("JPG 大小尚未就緒");}
        if(declared>MAX_OBJECT)throw new IOException("JPG 超出本版 512 MB 上限");
        return declared;
    }
    public long object(int handle,OutputStream out,long max)throws IOException{return command(0x1009,out,max,handle).bytes;}
    public static final class DeviceInfo {
        public final String manufacturer,model,version,serial,extension;
        public final int[] operations,events;
        DeviceInfo(byte[] b)throws IOException {
            Reader r=new Reader(b);r.u16();r.u32();r.u16();extension=r.string();r.u16();
            operations=r.array16();events=r.array16();r.array16();r.array16();r.array16();
            manufacturer=r.string();model=r.string();version=r.string();serial=r.string();
        }
        public boolean supports(int code){for(int op:operations)if(op==code)return true;return false;}
    }
    public DeviceInfo deviceInfo()throws IOException{return new DeviceInfo(data(0x1001));}
    public static final class Info {
        public final int handle,storage,format,width,height;
        public final long size;
        public final String name,captureDate;
        Info(int handle,String name,long size){
            this.handle=handle;this.name=name;this.size=size;
            storage=0;format=0x3801;width=height=0;captureDate="";
        }
        public Info(int handle,byte[] b)throws IOException {
            this.handle=handle;Reader r=new Reader(b);
            storage=(int)r.u32();format=r.u16();r.u16();size=r.u32();r.u16();
            r.u32();r.u32();r.u32();width=(int)r.u32();height=(int)r.u32();r.u32();r.u32();r.u16();r.u32();r.u32();
            name=r.string();captureDate=r.string();
        }
        public boolean jpeg(){return format==0x3801||name.toLowerCase(Locale.ROOT).endsWith(".jpg")||name.toLowerCase(Locale.ROOT).endsWith(".jpeg");}
        Info withSize(long bytes){return new Info(this,bytes);}
        private Info(Info src,long bytes){handle=src.handle;storage=src.storage;format=src.format;width=src.width;height=src.height;size=bytes;name=src.name;captureDate=src.captureDate;}
    }
    public static final class Reader {
        private final byte[] b;private int p;
        public Reader(byte[] b){this.b=b;}
        private void require(int n)throws IOException{if(n<0||n>b.length-p)throw new EOFException("Truncated PTP dataset");}
        public int u16()throws IOException{require(2);int v=Ptp.u16(b,p);p+=2;return v;}
        public long u32()throws IOException{require(4);long v=Ptp.u32(b,p);p+=4;return v;}
        public String string()throws IOException{require(1);int n=b[p++]&255;require(n*2);if(n==0)return "";String s=new String(b,p,(n-1)*2,StandardCharsets.UTF_16LE);p+=n*2;return s;}
        public int[] array16()throws IOException{long n=u32();if(n>(b.length-p)/2)throw new IOException("Invalid PTP array");int[] a=new int[(int)n];for(int i=0;i<a.length;i++)a[i]=u16();return a;}
        public int[] array32()throws IOException{long n=u32();if(n>(b.length-p)/4)throw new IOException("Invalid PTP array");int[] a=new int[(int)n];for(int i=0;i<a.length;i++)a[i]=(int)u32();return a;}
    }
    public static int u16(byte[] b,int p){return (b[p]&255)|((b[p+1]&255)<<8);}
    public static long u32(byte[] b,int p){return (b[p]&255L)|((b[p+1]&255L)<<8)|((b[p+2]&255L)<<16)|((b[p+3]&255L)<<24);}
    public static void put16(byte[] b,int p,int v){b[p]=(byte)v;b[p+1]=(byte)(v>>>8);}
    public static void put32(byte[] b,int p,long v){for(int i=0;i<4;i++)b[p+i]=(byte)(v>>>(i*8));}
    public static String codes(int[] a){StringBuilder s=new StringBuilder();for(int c:a)s.append(String.format(Locale.US,"%04X ",c));return s.toString().trim();}
}
