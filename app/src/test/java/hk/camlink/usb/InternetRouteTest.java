package hk.camlink.usb;

import org.junit.Test;
import static org.junit.Assert.*;

public final class InternetRouteTest {
    @Test public void cameraWifiDoesNotPreventCellularUpload(){
        int camera=InternetRoute.score(false,false,false,true,false,false,false,true,false,false);
        int mobile=InternetRoute.score(true,true,false,false,true,false,false,false,false,false);
        assertEquals(-1,camera);assertTrue(mobile>=0);
        assertEquals(-1,InternetRoute.score(true,false,false,true,false,false,false,true,false,false));
    }
    @Test public void wifiOnlyNeverFallsBackToMobile(){
        assertEquals(-1,InternetRoute.score(true,true,false,false,true,false,false,true,false,true));
        assertEquals(-1,InternetRoute.score(true,true,false,true,true,false,false,true,false,true));
        assertTrue(InternetRoute.score(true,true,false,true,false,false,false,false,false,true)>=0);
    }
    @Test public void prefersInternetWifiOverCellular(){
        assertTrue(InternetRoute.score(true,true,false,true,false,false,false,false,false,false)>
            InternetRoute.score(true,true,false,false,true,false,false,true,false,false));
    }
    @Test public void offlineAndSuspendedRoutesAreExcluded(){
        assertEquals(-1,InternetRoute.score(true,true,true,false,true,false,false,true,false,false));
        assertEquals(-1,InternetRoute.score(true,false,false,false,true,false,false,true,false,false));
    }
    @Test public void doesNotBypassActiveVpn(){
        assertEquals(-1,InternetRoute.score(true,true,false,false,true,false,false,false,true,false));
        assertTrue(InternetRoute.score(true,true,false,false,false,false,true,true,true,false)>=0);
        assertEquals(-1,InternetRoute.score(true,false,false,false,false,false,true,true,true,false));
    }
    @Test public void wifiOnlyKeepsTheActiveVpn(){
        assertTrue(InternetRoute.score(true,true,false,false,false,false,true,true,true,true)>=0);
        assertEquals(-1,InternetRoute.score(true,true,false,true,false,false,false,false,true,true));
        assertEquals(-1,InternetRoute.score(true,true,false,false,true,false,false,false,false,true));
    }
}
