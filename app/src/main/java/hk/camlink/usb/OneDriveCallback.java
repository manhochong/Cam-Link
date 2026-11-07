package hk.camlink.usb;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

/** Receives the Microsoft browser redirect. Cam Link does not hand the login to the OneDrive app. */
public final class OneDriveCallback extends Activity {
    @Override protected void onCreate(Bundle saved){
        super.onCreate(saved);
        Uri uri=getIntent()==null?null:getIntent().getData();
        boolean camlink=uri!=null&&"camlink".equals(uri.getScheme())&&"onedrive".equals(uri.getHost())&&"/callback".equals(uri.getPath());
        boolean gonfolio=uri!=null&&"work-camera".equals(uri.getScheme())&&"onedrive".equals(uri.getHost());
        if(!camlink&&!gonfolio){ finish(); return; }
        String code=uri.getQueryParameter("code"), state=uri.getQueryParameter("state"), error=uri.getQueryParameter("error");
        if(error!=null||code==null||state==null){ OneDriveAuth.prefs(this).edit().putString("status","Microsoft 登入已取消").apply(); open(); return; }
        new Thread(()->{
            try{ OneDriveAuth.complete(getApplicationContext(),code,state); OneDriveAuth.prefs(getApplicationContext()).edit().putString("status","已登入 Microsoft 帳戶").apply(); }
            catch(Exception e){ OneDriveAuth.prefs(getApplicationContext()).edit().putString("status",OneDriveAuth.safe(e)).apply(); }
            runOnUiThread(this::open);
        },"onedrive-login").start();
    }
    private void open(){ startActivity(new Intent(this,OneDriveActivity.class).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP)); finish(); }
}
