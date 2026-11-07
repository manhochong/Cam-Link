package hk.camlink.usb;

import java.io.IOException;

/** These profiles read objects on the camera card. Remote-release/RAM transfer is a separate protocol. */
enum CameraProfile {
    LUMIX(0x04da,"LUMIX"), SONY(0x054c,"Sony"), CANON(0x04a9,"Canon"),
    NIKON(0x04b0,"Nikon"), FUJI(0x04cb,"Fujifilm");
    final int vendor;
    final String brand;
    CameraProfile(int vendor,String brand){this.vendor=vendor;this.brand=brand;}
    static CameraProfile find(int vendor){
        for(CameraProfile profile:values())if(profile.vendor==vendor)return profile;
        return null;
    }
    boolean inventoryNotice(int code){
        return (this==SONY&&code==0xc201)||(this==FUJI&&code==0xc004)
            ||(this==CANON&&code==0xc101)||(this==NIKON&&code==0xc101);
    }
    int eventOperation(Ptp.DeviceInfo info){
        if(this==CANON&&info.supports(0x9116))return 0x9116;
        if(this==NIKON&&info.supports(0x90c7)&&!info.model.matches("(?i).*\\b[JSV]1\\b.*"))return 0x90c7;
        return 0;
    }
    boolean cardChanged(byte[] packet)throws IOException{
        if(this==NIKON){
            if(packet.length<2||2+Ptp.u16(packet,0)*6!=packet.length)throw new IOException("Nikon 事件長度異常");
            for(int p=2;p<packet.length;p+=6){
                int code=Ptp.u16(packet,p);
                if(code==0x4002||code==0x400d||inventoryNotice(code))return true;
            }
        }else if(this==CANON){
            boolean added=false;
            for(int p=0;p<packet.length;){
                if(packet.length-p<8)throw new IOException("Canon 事件標頭不完整");
                long length=Ptp.u32(packet,p),code=Ptp.u32(packet,p+4);
                if(length<8||length>packet.length-p)throw new IOException("Canon 事件長度異常");
                added|=code==0xc181||code==0xc1a7||code==0xc1b6;
                p+=(int)length;
            }
            return added;
        }
        return false;
    }
}
