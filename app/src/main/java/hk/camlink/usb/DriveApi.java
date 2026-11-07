package hk.camlink.usb;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import org.json.*;

/** Streaming REST transport. Tokens and resumable URLs are never placed in diagnostics. */
public final class DriveApi {
    public static final String BASE="https://www.googleapis.com/drive/v3/";
    public interface Token { String get() throws Exception; }
    public interface Cancel { boolean stopped(); }
    public interface Progress { void sent(long bytes); }
    public interface Input { FileInputStream open() throws IOException; }
    public interface Transport { Reply send(String method,String url,Map<String,String> headers,Body body) throws Exception; }
    public interface Body { long length(); void write(OutputStream out)throws Exception; }
    public static final class Reply {
        public final int status; public final String body;public final Map<String,String> headers;
        public Reply(int status,String body,Map<String,String> headers){this.status=status;this.body=body;this.headers=headers;}
        public String header(String key){for(Map.Entry<String,String> h:headers.entrySet())if(h.getKey()!=null&&h.getKey().equalsIgnoreCase(key))return h.getValue();return "";}
        public JSONObject json()throws JSONException{return body.isEmpty()?new JSONObject():new JSONObject(body);}
    }
    public static final class Failure extends IOException {
        public final int status;public final boolean retryable;
        Failure(int status,String reason,boolean retryable){super("Drive HTTP "+status+" · "+reason);this.status=status;this.retryable=retryable;}
    }
    public static final class Http implements Transport {
        public interface Connections { HttpURLConnection open(URL url)throws IOException; }
        private final Connections connections;
        public Http(){this(url->(HttpURLConnection)url.openConnection());}
        public Http(Connections connections){this.connections=connections;}
        public Reply send(String method,String url,Map<String,String> headers,Body body)throws Exception {
            validateUrl(url);
            HttpURLConnection c=connections.open(new URL(url));
            c.setRequestMethod(method);c.setInstanceFollowRedirects(false);c.setConnectTimeout(15000);c.setReadTimeout(30000);
            for(Map.Entry<String,String> h:headers.entrySet())c.setRequestProperty(h.getKey(),h.getValue());
            try {
                if(body!=null){c.setDoOutput(true);c.setFixedLengthStreamingMode(body.length());try(OutputStream out=c.getOutputStream()){body.write(out);}}
                int status=c.getResponseCode();Map<String,String> rh=new HashMap<>();
                for(Map.Entry<String,List<String>> e:c.getHeaderFields().entrySet())if(e.getKey()!=null&&!e.getValue().isEmpty())rh.put(e.getKey(),e.getValue().get(0));
                InputStream raw=status>=400?c.getErrorStream():c.getInputStream();ByteArrayOutputStream bytes=new ByteArrayOutputStream();
                if(raw!=null)try(InputStream in=raw){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1){if(bytes.size()+n>2*1024*1024)throw new IOException("Drive 回應過大");bytes.write(b,0,n);}}
                return new Reply(status,bytes.toString("UTF-8"),rh);
            }finally{c.disconnect();}
        }
    }
    private final Token token;private final Transport http;
    public DriveApi(Token token){this(token,new Http());}
    public DriveApi(Token token,Transport http){this.token=token;this.http=http;}
    public static void validateUrl(String url)throws IOException {
        try{URI u=new URI(url);if(!"https".equals(u.getScheme())||!"www.googleapis.com".equals(u.getHost())||u.getUserInfo()!=null||(u.getPort()!=-1&&u.getPort()!=443)||u.getFragment()!=null||!(u.getPath().startsWith("/drive/v3/")||u.getPath().startsWith("/upload/drive/v3/")))throw new IOException("不接受非 Google Drive 上傳網址");}
        catch(URISyntaxException e){throw new IOException("無效 Drive 網址");}
    }
    public static String enc(String s){try{return URLEncoder.encode(s,"UTF-8");}catch(Exception e){throw new IllegalArgumentException(e);}}
    static Body text(String s){byte[] b=s.getBytes(StandardCharsets.UTF_8);return new Body(){public long length(){return b.length;}public void write(OutputStream out)throws IOException{out.write(b);}};}
    private Reply request(String method,String url,Map<String,String> headers,Body body)throws Exception{
        validateUrl(url);Map<String,String> h=new HashMap<>(headers);h.put("Authorization","Bearer "+token.get());return http.send(method,url,h,body);
    }
    static Failure failure(Reply r){String reason="請稍後重試";try{JSONArray errors=r.json().getJSONObject("error").optJSONArray("errors");if(errors!=null&&errors.length()>0)reason=errors.getJSONObject(0).optString("reason",reason);}catch(Exception ignored){}
        if(!reason.matches("[a-zA-Z0-9_]+"))reason="requestFailed";
        boolean retry=r.status==408||r.status==429||r.status>=500||reason.equals("rateLimitExceeded")||reason.equals("userRateLimitExceeded");
        return new Failure(r.status,reason,retry);
    }
    private JSONObject json(String method,String path,JSONObject body)throws Exception {
        Reply r=request(method,BASE+path,body==null?Collections.emptyMap():Collections.singletonMap("Content-Type","application/json; charset=UTF-8"),body==null?null:text(body.toString()));
        if(r.status<200||r.status>=300)throw failure(r);return r.json();
    }
    public JSONObject user()throws Exception{return json("GET","about?fields=user(displayName,emailAddress,permissionId)",null).getJSONObject("user");}
    public String generateId()throws Exception{return json("GET","files/generateIds?count=1&space=drive&type=files",null).getJSONArray("ids").getString(0);}
    private final ArrayDeque<String> uploadIds=new ArrayDeque<>();
    synchronized String nextUploadId()throws Exception{
        if(uploadIds.isEmpty()){
            JSONArray ids=json("GET","files/generateIds?count=10&space=drive&type=files",null).getJSONArray("ids");
            Set<String> batch=new LinkedHashSet<>();
            for(int i=0;i<ids.length();i++){
                String id=ids.getString(i);
                if(id.isEmpty()||!batch.add(id))throw new IOException("Drive 回傳無效的檔案 ID");
            }
            if(batch.isEmpty())throw new IOException("Drive 未回傳檔案 ID");
            uploadIds.addAll(batch);
        }
        return uploadIds.removeFirst();
    }
    public JSONArray folders()throws Exception {
        JSONArray all=new JSONArray();String page="";
        do{JSONObject r=json("GET","files?q="+enc("trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='camlinkFolder' and value='1' }")+"&fields=nextPageToken,files(id,name)&pageSize=100&orderBy=name"+(page.isEmpty()?"":"&pageToken="+enc(page)),null);
            JSONArray files=r.getJSONArray("files");for(int i=0;i<files.length();i++)all.put(files.getJSONObject(i));page=r.optString("nextPageToken");
        }while(!page.isEmpty());return all;
    }
    public JSONObject createFolder(String name,String id)throws Exception {
        return json("POST","files?fields=id,name",new JSONObject().put("id",id).put("name",name).put("mimeType","application/vnd.google-apps.folder").put("appProperties",new JSONObject().put("camlinkFolder","1")));
    }
    public JSONObject metadata(String id)throws Exception {
        return json("GET","files/"+enc(id)+"?fields=id,size,md5Checksum,sha256Checksum,trashed,parents,mimeType,capabilities(canAddChildren)",null);
    }
    public void checkFolder(String id)throws Exception {JSONObject f=metadata(id);JSONObject caps=f.optJSONObject("capabilities");if(f.optBoolean("trashed")||!"application/vnd.google-apps.folder".equals(f.optString("mimeType"))||caps==null||!caps.optBoolean("canAddChildren"))throw new IOException("資料夾不存在或沒有新增檔案權限");}
    public String begin(String id,String folder,String name,long size,String key,String sha)throws Exception {
        JSONObject meta=new JSONObject().put("id",id).put("name",name).put("parents",new JSONArray().put(folder)).put("appProperties",new JSONObject().put("camlinkKey",key).put("sha256",sha));
        Map<String,String> headers=new HashMap<>();headers.put("Content-Type","application/json; charset=UTF-8");headers.put("X-Upload-Content-Type","image/jpeg");headers.put("X-Upload-Content-Length",Long.toString(size));
        Reply r=request("POST","https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,size,md5Checksum,sha256Checksum,trashed,parents",headers,text(meta.toString()));
        if(r.status!=200&&r.status!=201)throw failure(r);String location=r.header("Location");validateUrl(location);return location;
    }
    public Reply probe(String url,long size)throws Exception{return request("PUT",url,Collections.singletonMap("Content-Range","bytes */"+size),text(""));}
    public Reply chunk(String url,File file,long offset,int count,Cancel cancel,Progress progress)throws Exception {
        return chunk(url,()->new FileInputStream(file),file.length(),offset,count,cancel,progress);
    }
    public Reply chunk(String url,Input source,long size,long offset,int count,Cancel cancel,Progress progress)throws Exception {
        Map<String,String> headers=new HashMap<>();headers.put("Content-Type","image/jpeg");headers.put("Content-Range","bytes "+offset+"-"+(offset+count-1)+"/"+size);
        return request("PUT",url,headers,new Body(){public long length(){return count;}public void write(OutputStream out)throws Exception{
            try(FileInputStream in=source.open()){in.getChannel().position(offset);byte[] b=new byte[65536];int left=count;
                while(left>0){if(cancel.stopped())throw new InterruptedIOException("上傳已暫停");int n=in.read(b,0,Math.min(left,b.length));if(n<0)throw new EOFException("本機檔案截斷");out.write(b,0,n);left-=n;progress.sent(n);}
            }
        }});
    }
    public static long acknowledged(Reply r,long size)throws IOException {
        String range=r.header("Range");if(range.isEmpty())return 0;
        if(!range.matches("bytes=0-[0-9]+"))throw new IOException("Drive 回覆無效 Range");
        try{long end=Long.parseLong(range.substring(8));if(end<0||end>=size)throw new IOException("Drive Range 超出檔案大小");return end+1;}catch(NumberFormatException e){throw new IOException("Drive Range 超出範圍");}
    }
    public static void verify(JSONObject remote,String id,String folder,long size,String md5,String sha)throws Exception {
        if(!id.equals(remote.optString("id"))||remote.optBoolean("trashed")||remote.optLong("size",-1)!=size||!md5.equalsIgnoreCase(remote.optString("md5Checksum")))throw new IOException("雲端檔案大小或 MD5 不符，保留本機原檔");
        String remoteSha=remote.optString("sha256Checksum");if(!remoteSha.isEmpty()&&!sha.equalsIgnoreCase(remoteSha))throw new IOException("雲端 SHA-256 不符");
        JSONArray parents=remote.optJSONArray("parents");boolean match=false;if(parents!=null)for(int i=0;i<parents.length();i++)if(folder.equals(parents.getString(i)))match=true;
        if(!match)throw new IOException("雲端目的資料夾不符");
    }
    public static String[] hashes(File file,Cancel cancel)throws Exception {
        return hashes(()->new FileInputStream(file),file.length(),cancel);
    }
    public static String[] hashes(Input source,long expected,Cancel cancel)throws Exception {
        MessageDigest sha=MessageDigest.getInstance("SHA-256"),md5=MessageDigest.getInstance("MD5");
        long size=0;
        try(InputStream in=source.open()){byte[] b=new byte[256*1024];int n;while((n=in.read(b))!=-1){if(cancel.stopped())throw new InterruptedIOException("已暫停");sha.update(b,0,n);md5.update(b,0,n);size+=n;}}
        if(size!=expected)throw new IOException("本機檔案大小改變");
        return new String[]{hex(sha.digest()),hex(md5.digest())};
    }
    static String hex(byte[] bytes){StringBuilder s=new StringBuilder();for(byte b:bytes)s.append(String.format(Locale.US,"%02x",b&255));return s.toString();}
}
