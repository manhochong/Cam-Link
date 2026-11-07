package hk.camlink.usb;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.io.IOException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

/** Microsoft sign-in stays inside Cam Link. The refresh token never leaves the keystore. */
final class OneDriveAuth {
    private static final String KEY="camlink.onedrive.1";
    private static String access="",account=""; private static long expires;
    static SharedPreferences prefs(Context c){ return c.getSharedPreferences("onedrive",Context.MODE_PRIVATE); }
    static boolean signedIn(SharedPreferences p){ return !p.getString("account","").isEmpty()&&!p.getString("secret","").isEmpty(); }
    static JSONObject destination(Context c) throws Exception {
        SharedPreferences p=prefs(c);
        if(!p.getBoolean("enabled",false)||!signedIn(p)) return null;
        return new JSONObject().put("account",p.getString("account","")).put("email",p.getString("email",""))
            .put("folder",p.getString("folder","")).put("folder_name",p.getString("folder_name",""));
    }
    static JSONObject bind(Context c,String eventName) throws Exception {
        JSONObject dest=destination(c); if(dest==null) return null;
        if(!dest.getString("folder").isEmpty()) return dest;
        if(eventName==null||eventName.trim().isEmpty()) return null;
        return dest.put("eventName",eventName.trim());
    }
    static String begin(Context c) throws Exception {
        SharedPreferences p=prefs(c); String client=OneDriveApi.CLIENT;
        byte[] raw=new byte[32]; new SecureRandom().nextBytes(raw);
        String verifier=Base64.encodeToString(raw,Base64.URL_SAFE|Base64.NO_WRAP|Base64.NO_PADDING);
        byte[] state=new byte[16]; new SecureRandom().nextBytes(state);
        String nonce=Base64.encodeToString(state,Base64.URL_SAFE|Base64.NO_WRAP|Base64.NO_PADDING);
        String challenge=Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII)),Base64.URL_SAFE|Base64.NO_WRAP|Base64.NO_PADDING);
        if(!p.edit().putString("verifier",verifier).putString("state",nonce).commit()) throw new IOException("無法保存登入狀態");
        return OneDriveApi.authorize(client,challenge,nonce);
    }
    static void complete(Context c,String code,String state) throws Exception {
        SharedPreferences p=prefs(c);
        String expected=p.getString("state",""), verifier=p.getString("verifier","");
        p.edit().remove("state").remove("verifier").commit();
        if(expected.isEmpty()||!expected.equals(state)||verifier.isEmpty()) throw new IOException("登入狀態不符，請重新按登入");
        JSONObject token=exchange(OneDriveApi.CLIENT,form("grant_type","authorization_code","code",code,"redirect_uri",OneDriveApi.REDIRECT,"client_id",OneDriveApi.CLIENT,"code_verifier",verifier));
        accept(c,token);
    }
    private static void accept(Context c,JSONObject token) throws Exception {
        String accessToken=token.getString("access_token");
        JSONObject user=new OneDriveApi(()->accessToken).user();
        String id=user.getString("id");
        String email=user.optString("mail",""); if(email.isEmpty()) email=user.optString("userPrincipalName","");
        SharedPreferences p=prefs(c); String old=p.getString("account","");
        String refresh=token.optString("refresh_token",""); if(refresh.isEmpty()) refresh=decrypt(p);
        if(refresh.isEmpty()) throw new IOException("Microsoft 沒有回傳可更新的登入");
        SharedPreferences.Editor edit=p.edit().putString("account",id).putString("email",email);
        if(!old.equals(id)) edit.remove("folder").remove("folder_name");
        edit.putBoolean("enabled",true).putBoolean("paused",false);
        store(edit,refresh); if(!edit.commit()) throw new IOException("無法保存 Microsoft 登入");
        synchronized(OneDriveAuth.class){ access=accessToken; account=id; expires=System.currentTimeMillis()+45*60*1000L; }
    }
    static synchronized String token(Context c) throws Exception {
        SharedPreferences p=prefs(c); String id=p.getString("account","");
        if(!signedIn(p)) throw new LoginRequired();
        if(!access.isEmpty()&&expires>System.currentTimeMillis()&&account.equals(id)) return access;
        JSONObject token=exchange(OneDriveApi.CLIENT,form("grant_type","refresh_token","refresh_token",decrypt(p),"client_id",OneDriveApi.CLIENT,"scope",OneDriveApi.SCOPE));
        String next=token.optString("refresh_token",""); if(!next.isEmpty()){ SharedPreferences.Editor edit=p.edit(); store(edit,next); edit.commit(); }
        access=token.getString("access_token"); account=id; expires=System.currentTimeMillis()+45*60*1000L; return access;
    }
    static synchronized void forget(Context c){
        access=""; account=""; expires=0;
        prefs(c).edit().putBoolean("enabled",false).putBoolean("paused",true).remove("account").remove("email").remove("folder").remove("folder_name").remove("secret").remove("iv").remove("verifier").remove("state").commit();
    }
    private static JSONObject exchange(String client,String body) throws Exception {
        if(client==null||client.isEmpty()) throw new LoginRequired();
        OneDriveApi api=new OneDriveApi(()->"");
        Map<String,String> headers=new HashMap<>(); headers.put("Content-Type","application/x-www-form-urlencoded");
        byte[] raw=body.getBytes(StandardCharsets.UTF_8);
        OneDriveApi.Reply reply=api.send("POST",OneDriveApi.TOKEN_URL,headers,new OneDriveApi.Body(){ public long length(){ return raw.length; } public void write(java.io.OutputStream out) throws IOException { out.write(raw); } },false);
        if(reply.status==400||reply.status==401) throw new LoginRequired();
        if(reply.status<200||reply.status>=300) throw OneDriveApi.failure(reply);
        return reply.json();
    }
    private static String form(String... pairs) throws Exception {
        StringBuilder s=new StringBuilder();
        for(int i=0;i<pairs.length;i+=2){ if(s.length()>0) s.append('&'); s.append(URLEncoder.encode(pairs[i],"UTF-8")).append('=').append(URLEncoder.encode(pairs[i+1],"UTF-8")); }
        return s.toString();
    }
    private static SecretKey key() throws Exception {
        KeyStore ks=KeyStore.getInstance("AndroidKeyStore"); ks.load(null);
        if(ks.containsAlias(KEY)) return (SecretKey)ks.getKey(KEY,null);
        KeyGenerator gen=KeyGenerator.getInstance("AES","AndroidKeyStore");
        gen.init(new KeyGenParameterSpec.Builder(KEY,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return gen.generateKey();
    }
    private static void store(SharedPreferences.Editor edit,String refresh) throws Exception {
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key());
        edit.putString("iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP)).putString("secret",Base64.encodeToString(cipher.doFinal(refresh.getBytes(StandardCharsets.UTF_8)),Base64.NO_WRAP));
    }
    private static String decrypt(SharedPreferences p) throws Exception {
        String iv=p.getString("iv",""), secret=p.getString("secret","");
        if(iv.isEmpty()||secret.isEmpty()) throw new LoginRequired();
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(iv,Base64.DEFAULT)));
        return new String(cipher.doFinal(Base64.decode(secret,Base64.DEFAULT)),StandardCharsets.UTF_8);
    }
    static String safe(Exception e){ String s=e.getMessage(); if(s==null||s.contains("http")||s.contains("Bearer")||s.contains("eyJ")) return "Microsoft 登入未完成，請重試"; return s.length()>180?s.substring(0,180):s; }
    static final class LoginRequired extends IOException { LoginRequired(){ super("請返回 OneDrive 設定重新登入"); } }
}
