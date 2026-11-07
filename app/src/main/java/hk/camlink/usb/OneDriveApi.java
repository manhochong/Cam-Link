package hk.camlink.usb;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.*;

/** Microsoft Graph calls. Upload URLs are checked before any bytes are sent. */
final class OneDriveApi {
    /** Same public Microsoft app and mobile redirect Gonfolio already uses. No client secret. */
    static final String CLIENT="90cae47d-4d81-44fd-b973-646056949107";
    static final String REDIRECT="work-camera://onedrive";
    static final String GRAPH="https://graph.microsoft.com/v1.0/";
    static final String TOKEN_URL="https://login.microsoftonline.com/common/oauth2/v2.0/token";
    static final String SCOPE="openid profile offline_access User.Read Files.ReadWrite";
    interface Token { String get() throws Exception; }
    interface Cancel { boolean stopped(); }
    interface Connections { HttpURLConnection open(URL url) throws IOException; }
    interface Body { long length(); void write(OutputStream out) throws Exception; }
    static final class Reply {
        final int status; final String body; final Map<String,String> headers;
        Reply(int status,String body,Map<String,String> headers){this.status=status;this.body=body;this.headers=headers;}
        JSONObject json() throws JSONException { return body.isEmpty()?new JSONObject():new JSONObject(body); }
    }
    static final class Failure extends IOException {
        final int status; final boolean retryable;
        Failure(int status,String reason,boolean retryable){super("OneDrive HTTP "+status+" · "+reason);this.status=status;this.retryable=retryable;}
    }
    static void validate(String url) throws IOException {
        try {
            URI u=new URI(url);
            String host=u.getHost()==null?"":u.getHost().toLowerCase(Locale.ROOT);
            String path=u.getPath()==null?"":u.getPath();
            boolean known=host.equals("graph.microsoft.com")&&path.startsWith("/v1.0/")
                ||host.equals("login.microsoftonline.com")&&(path.startsWith("/common/oauth2/")||path.startsWith("/consumers/oauth2/"))
                ||host.endsWith(".microsoftpersonalcontent.com")||host.endsWith(".sharepoint.com")
                ||host.endsWith(".1drv.com")||host.endsWith(".svc.ms")||host.equals("api.onedrive.com");
            if(!"https".equals(u.getScheme())||u.getUserInfo()!=null||(u.getPort()!=-1&&u.getPort()!=443)||u.getFragment()!=null||!known)
                throw new IOException("不接受 OneDrive 主機 "+host);
        } catch(URISyntaxException e){ throw new IOException("無效 OneDrive 網址"); }
    }
    /** Graph accepts one fragment up to 60 MiB. A normal camera JPG then finishes in a single PUT. */
    static int chunk(long size,long offset){
        long remain=size-offset; long max=60L*1024*1024;
        if(remain<=max) return (int)remain;
        return (int)max;
    }
    static String authorize(String client,String challenge,String state) throws IOException {
        return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id="+enc(client)
            +"&response_type=code&redirect_uri="+enc(REDIRECT)+"&response_mode=query&scope="+enc(SCOPE)
            +"&state="+enc(state)+"&code_challenge="+enc(challenge)+"&code_challenge_method=S256&prompt=select_account";
    }
    static String enc(String s){ try{ return URLEncoder.encode(s,"UTF-8").replace("+","%20"); }catch(Exception e){ throw new IllegalArgumentException(e); } }
    private final Token token; private final Connections connections;
    OneDriveApi(Token token){ this(token,url->(HttpURLConnection)url.openConnection()); }
    OneDriveApi(Token token,Connections connections){ this.token=token; this.connections=connections; }
    Reply send(String method,String url,Map<String,String> headers,Body body,boolean auth) throws Exception {
        return send(method,url,headers,body,auth,60000);
    }
    Reply send(String method,String url,Map<String,String> headers,Body body,boolean auth,int readTimeout) throws Exception {
        validate(url);
        HttpURLConnection c=connections.open(new URL(url));
        c.setRequestMethod(method); c.setInstanceFollowRedirects(false); c.setConnectTimeout(15000); c.setReadTimeout(readTimeout);
        if(auth) c.setRequestProperty("Authorization","Bearer "+token.get());
        for(Map.Entry<String,String> h:headers.entrySet()) c.setRequestProperty(h.getKey(),h.getValue());
        try {
            if(body!=null){ c.setDoOutput(true); c.setFixedLengthStreamingMode(body.length()); try(OutputStream out=c.getOutputStream()){ body.write(out); } }
            int status=c.getResponseCode(); Map<String,String> rh=new HashMap<>();
            for(Map.Entry<String,List<String>> e:c.getHeaderFields().entrySet()) if(e.getKey()!=null&&!e.getValue().isEmpty()) rh.put(e.getKey(),e.getValue().get(0));
            InputStream raw=status>=400?c.getErrorStream():c.getInputStream(); ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            if(raw!=null) try(InputStream in=raw){ byte[] b=new byte[8192]; int n; while((n=in.read(b))!=-1){ if(bytes.size()+n>2*1024*1024) throw new IOException("OneDrive 回應過大"); bytes.write(b,0,n); } }
            return new Reply(status,bytes.toString("UTF-8"),rh);
        } finally { c.disconnect(); }
    }
    private static Body text(String s){ byte[] b=s.getBytes(StandardCharsets.UTF_8); return new Body(){ public long length(){ return b.length; } public void write(OutputStream out) throws IOException { out.write(b); } }; }
    private JSONObject graph(String method,String path,JSONObject body) throws Exception {
        Map<String,String> headers=body==null?Collections.emptyMap():Collections.singletonMap("Content-Type","application/json");
        Reply r=send(method,GRAPH+path,headers,body==null?null:text(body.toString()),true);
        if(r.status<200||r.status>=300) throw failure(r); return r.json();
    }
    static Failure failure(Reply r){
        String reason="requestFailed";
        try { reason=r.json().getJSONObject("error").optString("code",reason); } catch(Exception ignored){}
        if(!reason.matches("[A-Za-z0-9_.]+")) reason="requestFailed";
        boolean retry=r.status==408||r.status==429||r.status>=500||reason.equals("timeout")||reason.equals("activityLimitReached");
        return new Failure(r.status,reason,retry);
    }
    JSONObject user() throws Exception { return graph("GET","me?$select=id,mail,userPrincipalName",null); }
    JSONArray folders() throws Exception {
        JSONArray raw=graph("GET","me/drive/root/children?$select=id,name,folder&$top=200",null).optJSONArray("value");
        JSONArray out=new JSONArray(); if(raw==null) return out;
        for(int i=0;i<raw.length();i++) if(raw.getJSONObject(i).has("folder")&&!raw.getJSONObject(i).isNull("folder")) out.put(raw.getJSONObject(i));
        return out;
    }
    void checkFolder(String id) throws Exception {
        Reply r=send("GET",GRAPH+"me/drive/items/"+enc(id)+"?$select=id,folder",Collections.emptyMap(),null,true);
        if(r.status<200||r.status>=300) throw failure(r);
        JSONObject item=r.json();
        if(!item.has("folder")||item.isNull("folder")) throw new IOException("目的地不是資料夾");
    }
    String ensureFolder(String name) throws Exception {
        String id=lookupRootFolder(name); if(id!=null) return id;
        try { return createFolder(name).getString("id"); }
        catch(Failure e){ if(e.status!=409) throw e; }
        id=lookupRootFolder(name); if(id==null) throw new IOException("找不到剛建立的 OneDrive 資料夾");
        return id;
    }
    private String lookupRootFolder(String name) throws Exception {
        Reply r=send("GET",GRAPH+"me/drive/root:/"+enc(name)+"?$select=id,name,folder",Collections.emptyMap(),null,true);
        if(r.status==404) return null;
        if(r.status<200||r.status>=300) throw failure(r);
        JSONObject item=r.json();
        if(!item.has("folder")||item.isNull("folder")||!name.equals(item.optString("name"))) throw new IOException("同名項目不是資料夾");
        return item.getString("id");
    }
    JSONObject createFolder(String name) throws Exception {
        return graph("POST","me/drive/root/children",new JSONObject().put("name",name).put("folder",new JSONObject()).put("@microsoft.graph.conflictBehavior","fail"));
    }
    String session(String folderId,String name) throws Exception {
        String file=enc(name);
        String path=folderId==null||folderId.isEmpty()||"root".equals(folderId)
            ?"me/drive/root:/"+file+":/createUploadSession"
            :"me/drive/items/"+enc(folderId)+":/"+file+":/createUploadSession";
        JSONObject item=new JSONObject().put("@microsoft.graph.conflictBehavior","fail").put("name",name);
        JSONObject created=graph("POST",path,new JSONObject().put("item",item));
        String url=created.getString("uploadUrl"); validate(url); return url;
    }
    Reply putRange(String uploadUrl,DriveApi.Input source,long size,long offset,int count,Cancel cancel) throws Exception {
        validate(uploadUrl);
        long end=offset+count-1;
        Map<String,String> headers=new HashMap<>();
        headers.put("Content-Range","bytes "+offset+"-"+end+"/"+size);
        headers.put("Content-Length",Long.toString(count));
        Body body=new Body(){
            public long length(){ return count; }
            public void write(OutputStream out) throws Exception {
                try(InputStream in=source.open()){
                    long skip=offset; while(skip>0){ long n=in.skip(skip); if(n<=0) throw new IOException("無法從原圖的續傳位置讀取"); skip-=n; }
                    byte[] buf=new byte[65536]; int left=count;
                    while(left>0){ if(cancel.stopped()) throw new InterruptedIOException("已暫停"); int n=in.read(buf,0,Math.min(buf.length,left)); if(n<0) throw new EOFException("原圖比預期短"); out.write(buf,0,n); left-=n; }
                }
            }
        };
        int readTimeout=(int)Math.min(300_000L,Math.max(60_000L,count/128L));
        return send("PUT",uploadUrl,headers,body,false,readTimeout);
    }
    static long nextOffset(Reply reply,long fallback) throws IOException {
        try {
            JSONArray ranges=reply.json().optJSONArray("nextExpectedRanges");
            if(ranges!=null&&ranges.length()>0){ String range=ranges.getString(0); int dash=range.indexOf('-'); return Long.parseLong(dash<0?range:range.substring(0,dash)); }
        } catch(Exception ignored){}
        return fallback;
    }
    static void verify(JSONObject item,long size,String shaHex) throws Exception {
        if(item.optLong("size",-1)!=size) throw new IOException("OneDrive 檔案大小與本機不符");
        JSONObject hashes=item.optJSONObject("file")==null?null:item.getJSONObject("file").optJSONObject("hashes");
        String remote=hashes==null?"":hashes.optString("sha256Hash","");
        if(remote.isEmpty()) return;
        byte[] local=new byte[shaHex.length()/2];
        for(int i=0;i<local.length;i++) local[i]=(byte)Integer.parseInt(shaHex.substring(i*2,i*2+2),16);
        String expected=Base64.getEncoder().encodeToString(local);
        if(!expected.equals(remote)) throw new IOException("OneDrive SHA-256 與本機不符");
    }
}
