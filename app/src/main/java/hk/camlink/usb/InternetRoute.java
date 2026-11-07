package hk.camlink.usb;

/** Pure selection policy, shared by device implementation and host checks. */
final class InternetRoute {
    static int score(boolean internet,boolean validated,boolean suspended,boolean wifi,boolean cell,boolean ethernet,boolean vpn,boolean active,boolean activeVpn,boolean wifiOnly){
        if(!internet||!validated||suspended)return -1;
        // A VPN network is not tagged as Wi-Fi. Keep using the active VPN, including in Wi-Fi-only mode,
        // and do not fall through to the underlying network while that VPN is down or reconnecting.
        if(activeVpn)return vpn&&active?100:-1;
        if(vpn)return -1;
        if(wifiOnly&&(!wifi||cell))return -1;
        if(wifi)return 80;if(ethernet&&!wifiOnly)return 70;if(cell&&!wifiOnly)return 60;
        return active&&!wifiOnly?50:-1;
    }
}
