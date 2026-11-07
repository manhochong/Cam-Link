package hk.camlink.usb;

import android.accounts.Account;
import android.content.*;
import com.google.android.gms.auth.api.identity.*;
import com.google.android.gms.common.api.Scope;
import com.google.android.gms.tasks.Tasks;
import java.io.IOException;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Google owns credential storage; only a short-lived access token is cached in memory. */
public final class CloudAuth {
    public static final String SCOPE="https://www.googleapis.com/auth/drive.file";
    private static String token="",email="",account="";private static long expires;
    public static AuthorizationRequest request(String email){return AuthorizationRequest.builder().setAccount(new Account(email,"com.google")).setOptOutIncludingGrantedScopes(true).setRequestedScopes(Collections.singletonList(new Scope(SCOPE))).build();}
    public static synchronized void remember(String access,String who,String id){token=access;email=who;account=id;expires=System.currentTimeMillis()+45*60*1000L;}
    public static synchronized void forget(){token="";email="";account="";expires=0;}
    public static synchronized String token(Context c,String expectedAccount,String expectedEmail)throws Exception {
        try(CloudNetwork internet=new CloudNetwork(c)){return token(c,expectedAccount,expectedEmail,internet);}
    }
    static synchronized String token(Context c,String expectedAccount,String expectedEmail,DriveApi.Transport transport)throws Exception {
        if(!expectedAccount.equals(CloudStore.prefs(c).getString("account","")))throw new IOException("上傳帳戶已變更；舊佇列保留");
        if(!token.isEmpty()&&expires>System.currentTimeMillis()&&account.equals(expectedAccount)&&email.equals(expectedEmail))return token;
        try(AutoCloseable pin=transport instanceof CloudNetwork?((CloudNetwork)transport).pinProcess():null){
            AuthorizationResult r=Tasks.await(Identity.getAuthorizationClient(c).authorize(request(expectedEmail)),30,TimeUnit.SECONDS);
            if(r.hasResolution()||r.getAccessToken()==null)throw new LoginRequired();
            String access=r.getAccessToken();org.json.JSONObject user=new DriveApi(()->access,transport).user();
            if(!expectedAccount.equals(user.getString("permissionId")))throw new LoginRequired();
            remember(access,expectedEmail,expectedAccount);return token;
        }
    }
    public static synchronized void invalidate(Context c){String old=token;forget();if(!old.isEmpty())Identity.getAuthorizationClient(c).clearToken(ClearTokenRequest.builder().setToken(old).build());}
    public static final class LoginRequired extends IOException {public LoginRequired(){super("請返回 Google Drive 設定重新登入／授權");}}
}
