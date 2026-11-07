package hk.camlink.usb;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/** Microsoft login stays in this window so the phone's Gonfolio app cannot take the redirect. */
public final class OneDriveLogin extends Activity {
    private boolean taken;
    @Override protected void onCreate(Bundle saved){
        super.onCreate(saved);
        WebView web=new WebView(this);
        setContentView(web);
        CookieManager cookies=CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(web,true);
        web.getSettings().setJavaScriptEnabled(true);
        web.getSettings().setDomStorageEnabled(true);
        String agent=web.getSettings().getUserAgentString();
        if(agent!=null) web.getSettings().setUserAgentString(agent.replace("; wv",""));
        web.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){ return take(request.getUrl()); }
            @Override public boolean shouldOverrideUrlLoading(WebView view,String url){ return take(Uri.parse(url)); }
        });
        String url; try{ url=OneDriveAuth.begin(this); }catch(Exception e){ fail(OneDriveAuth.safe(e)); return; }
        web.loadUrl(url);
    }
    private boolean take(Uri uri){
        if(uri==null||taken) return false;
        boolean callback="work-camera".equals(uri.getScheme())&&"onedrive".equals(uri.getHost())
            ||"camlink".equals(uri.getScheme())&&"onedrive".equals(uri.getHost());
        if(!callback) return false;
        taken=true;
        String code=uri.getQueryParameter("code"), state=uri.getQueryParameter("state"), error=uri.getQueryParameter("error");
        if(error!=null||code==null||state==null){ fail("Microsoft 登入已取消"); return true; }
        new Thread(()->{
            try{ OneDriveAuth.complete(getApplicationContext(),code,state); OneDriveAuth.prefs(getApplicationContext()).edit().putString("status","已登入，之後新拍的 JPG 會上傳").apply(); runOnUiThread(this::done); }
            catch(Exception e){ runOnUiThread(()->fail(OneDriveAuth.safe(e))); }
        },"onedrive-login").start();
        return true;
    }
    private void done(){ startActivity(new Intent(this,OneDriveActivity.class).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP)); finish(); }
    private void fail(String message){ OneDriveAuth.prefs(this).edit().putString("status",message).apply(); done(); }
}
