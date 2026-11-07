package hk.camlink.usb;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.awt.image.BufferedImage;
import javax.imageio.ImageIO;

public final class CoreTests {
    private static int tests;
    private static void ok(boolean value,String label){if(!value)throw new AssertionError(label);tests++;System.out.println("PASS "+label);}
    interface Checked {void run()throws Exception;}
    private static void rejects(Checked fn,String label)throws Exception{try{fn.run();throw new AssertionError("accepted: "+label);}catch(IOException expected){tests++;System.out.println("PASS "+label);}}
    private static byte[] container(int type,int code,long id,byte[] data){byte[] b=new byte[12+data.length];Ptp.put32(b,0,b.length);Ptp.put16(b,4,type);Ptp.put16(b,6,code);Ptp.put32(b,8,id);System.arraycopy(data,0,b,12,data.length);return b;}
    private static byte[] concat(byte[]...arrays)throws IOException{ByteArrayOutputStream out=new ByteArrayOutputStream();for(byte[] b:arrays)out.write(b);return out.toByteArray();}
    private static final class Wire implements Ptp.Wire {
        final byte[] data;final int chunk;int pos;final List<byte[]> commands=new ArrayList<>();
        Wire(byte[] data,int chunk){this.data=data;this.chunk=chunk;}
        public int read(byte[] out){if(pos==data.length)return -1;int n=Math.min(out.length,Math.min(chunk,data.length-pos));System.arraycopy(data,pos,out,0,n);pos+=n;return n;}
        public void write(byte[] b){commands.add(b.clone());}
        public void close(){}
    }
    private static Ptp ptp(Wire wire){return new Ptp(wire,s->{});}
    private static byte[] response(int code,int id){return container(3,code,id,new byte[0]);}
    private static byte[] handlesData(int...values){byte[] b=new byte[4+4*values.length];Ptp.put32(b,0,values.length);for(int i=0;i<values.length;i++)Ptp.put32(b,4+i*4,values[i]);return b;}
    private static byte[] dataReply(int op,int tx,byte[] b)throws IOException{return concat(container(2,op,tx,b),response(Ptp.OK,tx));}
    private static void cameraNotices()throws Exception {
        ok(CameraProfile.find(0x1234)==null,"unknown vendor not matched");
        ok(CameraProfile.SONY.inventoryNotice(0xc201)&&!CameraProfile.FUJI.inventoryNotice(0xc201),"Sony notice isolated by vendor");
        ok(CameraProfile.FUJI.inventoryNotice(0xc004)&&!CameraProfile.LUMIX.inventoryNotice(0xc004),"Fuji card notice isolated by vendor");
        byte[] nikon={1,0,2,0x40,42,0,0,0};
        ok(CameraProfile.NIKON.cardChanged(nikon),"Nikon compact ObjectAdded prompts card rescan");
        rejects(()->CameraProfile.NIKON.cardChanged(Arrays.copyOf(nikon,6)),"truncated Nikon record rejected");
        byte[] eos=new byte[20];Ptp.put32(eos,0,12);Ptp.put32(eos,4,0xc181);Ptp.put32(eos,12,8);
        ok(CameraProfile.CANON.cardChanged(eos),"EOS card event followed by terminator");
        Ptp.put32(eos,12,0xffffffffL);
        rejects(()->CameraProfile.CANON.cardChanged(eos),"malformed trailing EOS record rejected");
    }
    private static void inventory()throws Exception {
        cameraNotices();
        Wire normal=new Wire(concat(dataReply(0x1004,0,handlesData(0x10001,0x20001)),dataReply(0x1007,1,handlesData(10,11)),dataReply(0x1007,2,handlesData(11,12))),16384);
        ok(Arrays.equals(ptp(normal).inventory(),new int[]{10,11,12}),"inventory combines cards without duplicate handles");
        Wire camera=new Wire(concat(dataReply(0x1004,0,handlesData(0x10001,0x20001)),response(0x2006,1),dataReply(0x1007,2,handlesData(10,11,11)),dataReply(0x1007,3,handlesData(10,11,12))),16384);
        Ptp p=ptp(camera);ok(Arrays.equals(p.inventory(),new int[]{10,11}),"ParameterNotSupported falls back to all storages");
        ok(Ptp.u32(camera.commands.get(2),12)==0xffffffffL&&Ptp.u32(camera.commands.get(2),16)==0&&Ptp.u32(camera.commands.get(2),20)==0,"fallback uses standard no-filter selectors");
        ok(Arrays.equals(p.inventory(),new int[]{10,11,12})&&camera.commands.size()==4&&Ptp.u32(camera.commands.get(3),12)==0xffffffffL,"subsequent scans cache successful fallback");
        Wire partial=new Wire(concat(dataReply(0x1004,0,handlesData(0x10001,0x20001)),dataReply(0x1007,1,handlesData(99)),response(0x2006,2),dataReply(0x1007,3,handlesData(10,11))),16384);
        ok(Arrays.equals(ptp(partial).inventory(),new int[]{10,11}),"fallback replaces partial per-card snapshot");
        Wire busy=new Wire(concat(dataReply(0x1004,0,handlesData(1)),response(Ptp.BUSY,1)),16384);
        rejects(()->ptp(busy).inventory(),"busy is not treated as unsupported filter");ok(busy.commands.size()==2,"busy does not trigger alternative query");
        Wire bothFail=new Wire(concat(dataReply(0x1004,0,handlesData(1)),response(0x2006,1),response(0x2006,2)),16384);
        rejects(()->ptp(bothFail).inventory(),"failed fallback does not create an empty successful baseline");
        Wire empty=new Wire(dataReply(0x1004,0,handlesData()),16384);
        rejects(()->ptp(empty).inventory(),"no storage does not arm capture");
    }
    private static byte[] ptpString(String s){byte[] b=new byte[1+(s.length()+1)*2];b[0]=(byte)(s.length()+1);byte[] u=s.getBytes(java.nio.charset.StandardCharsets.UTF_16LE);System.arraycopy(u,0,b,1,u.length);return b;}
    private static void datasets()throws Exception {
        byte[] fixed=new byte[52];Ptp.put32(fixed,0,0x00010001);Ptp.put16(fixed,4,0x3801);Ptp.put32(fixed,8,25000000);Ptp.put32(fixed,26,6000);Ptp.put32(fixed,30,4000);
        Ptp.Info info=new Ptp.Info(99,concat(fixed,ptpString("P1000123.JPG"),ptpString("20261031T123456"),ptpString(""),ptpString("")));
        ok(info.size==25000000&&info.width==6000&&info.height==4000&&info.storage==0x10001&&info.jpeg()&&info.name.equals("P1000123.JPG"),"ObjectInfo offsets and original dimensions");
        rejects(()->new Ptp.Info(1,Arrays.copyOf(fixed,51)),"truncated ObjectInfo rejected");
        byte[] prefix=new byte[8];Ptp.put16(prefix,0,100);Ptp.put32(prefix,2,6);Ptp.put16(prefix,6,100);
        byte[] functional=new byte[2],ops=new byte[8];Ptp.put32(ops,0,2);Ptp.put16(ops,4,0x1007);Ptp.put16(ops,6,0x1009);
        byte[] empty=new byte[4];
        byte[] deviceData=concat(prefix,ptpString("PTP"),functional,ops,empty,empty,empty,empty,ptpString("Panasonic"),ptpString("DC-S1M2"),ptpString("fixture-only"),ptpString("test"));
        Ptp.DeviceInfo d=new Ptp.DeviceInfo(deviceData);
        ok(d.model.equals("DC-S1M2")&&d.supports(0x1009)&&!d.supports(0x100e),"DeviceInfo capabilities parsed without assuming capture support");
        Wire initialized=new Wire(concat(response(Ptp.OK,0),container(2,0x1001,1,deviceData),response(Ptp.OK,1)),16384);
        ok(ptp(initialized).initialize().model.equals("DC-S1M2"),"initialize parses in-session camera info");
        ok(initialized.commands.size()==2&&Ptp.u16(initialized.commands.get(0),6)==0x1002&&Ptp.u32(initialized.commands.get(0),8)==0&&Ptp.u16(initialized.commands.get(1),6)==0x1001&&Ptp.u32(initialized.commands.get(1),8)==1,"initialize sends OpenSession before GetDeviceInfo");
        Wire rejected=new Wire(response(0x201e,0),64);
        rejects(()->ptp(rejected).initialize(),"failed OpenSession does not proceed to GetDeviceInfo");
        ok(rejected.commands.size()==1,"no blind command retry after rejected session");
    }
    private static void protocol()throws Exception {
        byte[] payload=new byte[1024*1024+17];new Random(7).nextBytes(payload);
        for(int chunk:new int[]{1,7,12,64,16384,262144}){
            Wire w=new Wire(concat(container(2,0x1009,0,payload),response(Ptp.OK,0)),chunk);ByteArrayOutputStream out=new ByteArrayOutputStream();Ptp p=ptp(w);
            long n=p.object(0x81234567,out,payload.length);ok(n==payload.length&&Arrays.equals(payload,out.toByteArray()),"fragmented/full-size stream chunk="+chunk);
            ok(w.commands.size()==1&&Ptp.u32(w.commands.get(0),12)==0x81234567L,"unsigned object handle chunk="+chunk);
        }
        Wire combined=new Wire(concat(container(2,0x1001,0,new byte[]{1,2}),response(Ptp.OK,0),response(Ptp.OK,0),response(Ptp.OK,1)),9999);
        Ptp p=ptp(combined);ok(Arrays.equals(p.data(0x1001),new byte[]{1,2}),"data and response share USB read");p.open();ok(Ptp.u32(combined.commands.get(1),8)==0,"OpenSession resets transaction to zero");p.data(0x1004);ok(Ptp.u32(combined.commands.get(2),8)==1,"in-session transaction starts at one");
        Ptp busy=ptp(new Wire(concat(response(Ptp.BUSY,0),response(Ptp.OK,1)),64));
        try{busy.data(0x1008,9);throw new AssertionError("busy");}catch(Ptp.ResponseException e){ok(e.code==Ptp.BUSY&&busy.healthy(),"busy preserves framed session");}busy.data(0x1004);
        Ptp wrong=ptp(new Wire(response(Ptp.OK,42),64));rejects(()->wrong.data(0x1001),"wrong transaction rejected");ok(!wrong.healthy(),"wrong transaction poisons stream");rejects(()->wrong.open(),"no retry on poisoned stream");
        List<String> diagnostics=new ArrayList<>();Wire mismatched=new Wire(response(Ptp.OK,42),7);Ptp diagnostic=new Ptp(mismatched,diagnostics::add);
        try{diagnostic.data(0x1007);throw new AssertionError("accepted mismatch");}catch(IOException e){ok(e.getMessage().contains("rx_tx=42 expected_tx=0")&&e.getMessage().contains("header=0C000000030001202A000000"),"mismatched transaction records exact header and expected ID");}
        ok(diagnostics.stream().anyMatch(s->s.contains("IO_FAILURE op=1007")&&s.contains("reads=2 wire_bytes=12")),"fragmented header failure retains transport counters");
        rejects(()->diagnostic.data(0x1007),"diagnostics do not enable resend on invalid stream");ok(mismatched.commands.size()==1,"diagnostics perform no recovery USB commands");
        byte[] badLength=response(Ptp.OK,0);Ptp.put32(badLength,0,11);Ptp shortHeader=ptp(new Wire(badLength,64));
        try{shortHeader.data(0x1007);throw new AssertionError("accepted bad length");}catch(IOException e){ok(e.getMessage().contains("len=11")&&e.getMessage().contains("rx_tx=0 expected_tx=0"),"invalid length distinguishable from transaction mismatch");}
        Ptp trunc=ptp(new Wire(Arrays.copyOf(container(2,0x1009,0,payload),100),64));rejects(()->trunc.object(1,new ByteArrayOutputStream(),payload.length),"truncated data rejected");
        Ptp large=ptp(new Wire(container(2,0x1009,0,payload),64));rejects(()->large.object(1,new ByteArrayOutputStream(),100),"oversized object rejected before allocation");
        rejects(()->ptp(new Wire(container(2,0x1008,0,new byte[0]),64)).data(0x1009),"wrong data opcode rejected");
        rejects(()->ptp(new Wire(container(4,0x4002,0,new byte[0]),64)).open(),"event on bulk transaction rejected");
        rejects(()->new Ptp.Reader(new byte[]{0,0,0,(byte)128}).array32(),"hostile array count rejected");
        rejects(()->new Ptp.Reader(new byte[]{4,65,0}).string(),"truncated Unicode dataset rejected");
        Ptp responseError=ptp(new Wire(concat(container(2,0x1009,0,payload),response(0x2002,0)),65536));
        rejects(()->responseError.object(1,new ByteArrayOutputStream(),payload.length),"complete payload with failed response never accepted");
        byte[] illegal=response(Ptp.OK,0);Ptp.put32(illegal,0,11);rejects(()->ptp(new Wire(illegal,64)).open(),"container smaller than header rejected");
        rejects(()->ptp(new Wire(concat(container(2,0x1009,0,new byte[0]),container(2,0x1009,0,new byte[0]),response(Ptp.OK,0)),64)).object(1,new ByteArrayOutputStream(),100),"duplicate data container rejected");
    }
    private static void jpeg(Path dir)throws Exception {
        BufferedImage picture=new BufferedImage(192,128,BufferedImage.TYPE_INT_RGB);
        Random rng=new Random(13);for(int y=0;y<128;y++)for(int x=0;x<192;x++)picture.setRGB(x,y,rng.nextInt());
        File file=dir.resolve("original.jpg").toFile();ImageIO.write(picture,"jpg",file);
        JpegCheck result=JpegCheck.check(file,file.length());ok(result.width==192&&result.height==128&&result.sha256.length()==64&&result.md5.length()==32,"real JPEG dimensions and digest");
        byte[] bytes=Files.readAllBytes(file.toPath());
        for(int length:new int[]{1,20,bytes.length/2,bytes.length-1,bytes.length-2}){
            File cut=dir.resolve("cut-"+length+".jpg").toFile();Files.write(cut.toPath(),Arrays.copyOf(bytes,length));rejects(()->JpegCheck.check(cut,cut.length()),"JPEG truncation at "+length);
        }
        rejects(()->JpegCheck.check(file,file.length()+1),"metadata byte mismatch rejected");
        File tail=dir.resolve("tail.jpg").toFile();Files.write(tail.toPath(),concat(bytes,new byte[]{7}));
        JpegCheck tailCheck=JpegCheck.check(tail,tail.length());ok(tailCheck.trailingBytes==1&&tailCheck.width==192,"complete JPEG may contain trailing auxiliary bytes");
        ok(!tailCheck.sha256.equals(result.sha256),"hash includes trailing bytes instead of silently trimming");
        File aligned=dir.resolve("aligned.jpg").toFile();int pad=512-(bytes.length%512);byte[] padding=new byte[pad];new Random(99).nextBytes(padding);Files.write(aligned.toPath(),concat(bytes,padding));
        byte[] rawDigest=java.security.MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(aligned.toPath()));StringBuilder expectedHash=new StringBuilder();for(byte b:rawDigest)expectedHash.append(String.format(Locale.US,"%02x",b&255));
        JpegCheck alignedCheck=JpegCheck.check(aligned,aligned.length());ok(alignedCheck.trailingBytes==pad&&alignedCheck.sha256.equals(expectedHash.toString()),"nonzero camera alignment data preserved and fully hashed");
        File falseEnd=dir.resolve("false-end.jpg").toFile();Files.write(falseEnd.toPath(),concat(new byte[]{(byte)255,(byte)216,(byte)255,(byte)217},padding));rejects(()->JpegCheck.check(falseEnd,falseEnd.length()),"padding cannot make SOI EOI without image valid");
        File fake=dir.resolve("fake.jpg").toFile();Files.write(fake.toPath(),new byte[]{(byte)255,(byte)216,(byte)255,(byte)217});rejects(()->JpegCheck.check(fake,4),"SOI EOI alone is not JPEG");
        File wrong=dir.resolve("wrong.jpg").toFile();byte[] changed=bytes.clone();changed[0]=0;Files.write(wrong.toPath(),changed);rejects(()->JpegCheck.check(wrong,wrong.length()),"missing SOI rejected");
        // Progressive scans must also validate.
        javax.imageio.ImageWriter writer=ImageIO.getImageWritersByFormatName("jpg").next();
        File progressive=dir.resolve("progressive.jpg").toFile();
        try(javax.imageio.stream.ImageOutputStream out=ImageIO.createImageOutputStream(progressive)){
            writer.setOutput(out);javax.imageio.ImageWriteParam params=writer.getDefaultWriteParam();params.setProgressiveMode(javax.imageio.ImageWriteParam.MODE_DEFAULT);writer.write(null,new javax.imageio.IIOImage(picture,null,null),params);
        }finally{writer.dispose();}
        ok(JpegCheck.check(progressive,progressive.length()).width==192,"progressive JPEG multiple scans");
    }
    private static void queue() {
        ReceiveQueue q=new ReceiveQueue();q.baseline(new int[]{1,2});ok(!q.add(1,0,"event"),"baseline excludes old event");
        ok(q.add(3,1,"event")&&!q.add(3,2,"inventory"),"event inventory dedup");
        ReceiveQueue.Item i=q.next(3);ok(i.handle==3&&i.discovered==1&&q.pending()==0,"first discovery retained");
        q.retry(i,10);ok(q.next(11)==null,"busy backoff");q.add(4,20,"event");ok(q.next(21).handle==4,"retry does not block later objects");
        ok(q.next(10000)==i,"retry becomes eligible");q.fail(i);ok(q.failed()==1&&q.unresolved().contains(3),"failure stays visible");
        q.retryFailed();ok(q.failed()==0&&q.next(10001)==i,"explicit failed retry");
        ok(!q.add(3,20000,"inventory"),"completed handle never rediscovered");
        for(int h=5;h<305;h++)q.add(h,h,"event");for(int h=5;h<305;h++)q.add(h,h,"inventory");ok(q.pending()==300,"300-shot dedup queue");
        ReceiveQueue again=new ReceiveQueue();
        ReceiveQueue.Gap gap=again.reopen(new int[]{1,2,3},new int[]{4},new int[]{1,2,3,4,5,6},0);
        ok(!gap.renumbered&&gap.recover==2&&again.baselineCount()==4&&again.pending()==2,"reconnect queues only photos missing after the drop");
        ok(again.next(0).handle==5&&again.next(0).handle==6,"missing handles stay in card order");
        ReceiveQueue renumbered=new ReceiveQueue();
        ReceiveQueue.Gap changed=renumbered.reopen(new int[]{1,2},new int[]{4},new int[]{10,11},0);
        ok(changed.renumbered&&changed.recover==0&&renumbered.baselineCount()==0&&renumbered.pending()==0,"renumbered card is not downloaded as all-new");
        ReceiveQueue emptyCard=new ReceiveQueue();
        ReceiveQueue.Gap shot=emptyCard.reopen(new int[0],new int[]{4},new int[]{4,5},0);
        ok(!shot.renumbered&&shot.recover==1&&emptyCard.baselineCount()==1&&emptyCard.next(0).handle==5,"empty-card session still recovers the unsent frame");
        ReceiveQueue paused=new ReceiveQueue();paused.add(8,0,"card");paused.add(9,0,"card");ok(paused.dropPending()==2&&paused.pending()==0&&!paused.add(8,1,"card"),"paused card import drops the rest without rediscovering it");
        ReceiveQueue stable=new ReceiveQueue();for(int h=1;h<=4;h++)stable.add(h,0,"card");
        ok(stable.omitFinished(new int[]{1,2,3})==3&&stable.pending()==1&&stable.next(0).handle==4,"stable card numbers skip files already copied");
        ReceiveQueue renamed=new ReceiveQueue();renamed.add(10,0,"card");renamed.add(11,0,"card");
        ok(renamed.omitFinished(new int[]{1,2,3})==0&&renamed.pending()==2,"renumbered card is not skipped by old numbers");
        renamed.newestFirst();ok(renamed.next(0).handle==11&&renamed.next(0).handle==10,"renumbered resume asks newest files first");
        ReceiveQueue collision=new ReceiveQueue();for(int h=1;h<=10;h++)collision.add(h,0,"card");
        ok(collision.omitFinished(new int[]{1,2,100,101,102,103,104,105})==0&&collision.pending()==10,"a small number collision does not skip the card");
    }
    public static void main(String[] args)throws Exception {
        Path dir=Path.of(args[0]);Files.createDirectories(dir);protocol();datasets();inventory();jpeg(dir);queue();System.out.println("CORE TESTS PASSED: "+tests);
    }
}
