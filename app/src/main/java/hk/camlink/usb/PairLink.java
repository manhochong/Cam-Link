package hk.camlink.usb;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

/** Camera QR camlink://pair opens the existing computer pairing screen. */
public final class PairLink extends Activity {
    @Override protected void onCreate(Bundle saved){
        super.onCreate(saved);
        route(getIntent());
    }
    @Override protected void onNewIntent(Intent intent){
        super.onNewIntent(intent);
        setIntent(intent);
        route(intent);
    }
    private void route(Intent intent){
        Uri data=intent==null?null:intent.getData();
        String raw=intent==null?null:intent.getDataString();
        if(data==null||raw==null||data.getScheme()==null||!data.getScheme().equalsIgnoreCase("camlink")||!"pair".equalsIgnoreCase(data.getHost())){
            finish();return;
        }
        Intent open=new Intent(this,OtherClouds.class);
        open.putExtra("pair_uri",raw);
        open.putExtra("pair_auto",true);
        open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(open);
        finish();
    }
}
