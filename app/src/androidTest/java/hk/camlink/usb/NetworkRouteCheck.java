package hk.camlink.usb;

import android.app.Instrumentation;
import android.content.Context;
import android.net.*;
import android.os.Bundle;
import org.json.JSONObject;

/** Read-only device check. No camera commands, uploaded files or credential logging. */
final class NetworkRouteCheck {
    static void run(Instrumentation test){
        Context context=test.getTargetContext();StringBuilder log=new StringBuilder();int code=0;
        try(CloudNetwork internet=new CloudNetwork(context)){
            ConnectivityManager cm=context.getSystemService(ConnectivityManager.class);
            for(Network n:cm.getAllNetworks()){
                NetworkCapabilities caps=cm.getNetworkCapabilities(n);if(caps==null)continue;
                log.append("NETWORK wifi=").append(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))
                    .append(" cellular=").append(caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR))
                    .append(" internet=").append(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
                    .append(" validated=").append(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)).append('\n');
            }
            Network selected=internet.awaitReady();NetworkCapabilities caps=cm.getNetworkCapabilities(selected);
            log.append("SELECTED ").append(internet.label()).append(" validated=").append(caps!=null&&caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)).append('\n');
            String account=CloudStore.prefs(context).getString("account",""),email=CloudStore.prefs(context).getString("email","");
            if(account.isEmpty())log.append("DRIVE_READ_SKIPPED no_configured_account\n");
            else{
                JSONObject user=new DriveApi(()->CloudAuth.token(context,account,email,internet),internet).user();
                if(!account.equals(user.getString("permissionId")))throw new AssertionError("Account mismatch");
                log.append("DRIVE_READ_OK account_matches=true no_files_created\n");
            }
        }catch(Exception|AssertionError e){code=1;log.append("CHECK_FAILED ").append(e instanceof Exception?UploadService.safeError((Exception)e):"Account mismatch").append('\n');}
        log.append("CAMERA_PAIRING_NOT_TESTED\nSIMULTANEOUS_CAMERA_AND_CELLULAR_NOT_TESTED\n");
        Bundle result=new Bundle();result.putString("stream",log.toString());test.finish(code,result);
    }
}
