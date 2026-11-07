package hk.camlink.usb;

import org.junit.*;
import static org.junit.Assert.*;
import org.json.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;

public class DriveTests {
    static final String URI="https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture";
    File file;CloudStore.Job job;
    @Before public void setup()throws Exception {file=File.createTempFile("camlink-drive-",".jpg");byte[] b=new byte[5*1024*1024+13];new Random(44).nextBytes(b);Files.write(file.toPath(),b);String[] hash=DriveApi.hashes(file,()->false);job=new CloudStore.Job();job.key="key";job.path=file.getPath();job.name="original.JPG";job.size=file.length();job.sha=hash[0];job.md5="";job.remote="";job.uri="";job.folder="folder";job.account="account";job.email="fixture@example.invalid";job.state="WAITING";}
    @After public void cleanup(){if(file!=null)file.delete();}
    JSONObject metadata()throws Exception{return new JSONObject().put("id","file-id").put("size",file.length()).put("md5Checksum",DriveApi.hashes(file,()->false)[1]).put("sha256Checksum",job.sha).put("parents",new JSONArray().put("folder"));}
    static DriveApi.Reply reply(int status,String body,String...header){Map<String,String> h=new HashMap<>();for(int i=0;i<header.length;i+=2)h.put(header[i],header[i+1]);return new DriveApi.Reply(status,body,h);}
    static DriveApi.Reply missing(){return reply(404,"{}");}
    static class Mock implements DriveApi.Transport {
        Queue<Object> replies=new ArrayDeque<>();List<String> calls=new ArrayList<>(),ranges=new ArrayList<>();long bytes;List<String> posted=new ArrayList<>();
        Mock(Object...r){replies.addAll(Arrays.asList(r));}
        public DriveApi.Reply send(String method,String url,Map<String,String> headers,DriveApi.Body body)throws Exception {
            calls.add(method+" "+url);ranges.add(headers.getOrDefault("Content-Range",""));assertEquals("Bearer fake",headers.get("Authorization"));
            if(body!=null){ByteArrayOutputStream out=new ByteArrayOutputStream();body.write(out);assertEquals(body.length(),out.size());if(method.equals("POST"))posted.add(out.toString("UTF-8"));if(method.equals("PUT"))bytes+=out.size();}
            if(replies.isEmpty())throw new AssertionError("Unexpected HTTP call "+method+" "+url);Object r=replies.remove();if(r instanceof Exception)throw (Exception)r;return (DriveApi.Reply)r;
        }
    }
    UploadEngine engine(Mock m,List<String> saves){return new UploadEngine(new DriveApi(()->"fake",m),j->saves.add(j.remote+":"+j.offset+":"+j.state),()->false,n->{});}
    @Rule public org.junit.rules.TemporaryFolder temp=new org.junit.rules.TemporaryFolder();
    @Test public void completeReplyNeedsNoMetadataReadAndWrongChecksumFails()throws Exception{
        JSONObject full=metadata().put("trashed",false);
        for(boolean corrupt:new boolean[]{false,true}){
            job.remote="";job.uri="";job.state="WAITING";
            if(corrupt)full.put("md5Checksum","incorrect");
            Mock m=new Mock(reply(200,"{\"ids\":[\"file-id\"]}"),reply(200,"","Location",URI),reply(200,full.toString()));
            try{engine(m,new ArrayList<>()).run(job);assertFalse(corrupt);}
            catch(IOException error){assertTrue(corrupt);}
            assertEquals(!corrupt,"DONE".equals(job.state));assertEquals(3,m.calls.size());
        }
    }
    @Test public void twoWorkersShareTenUniqueIds()throws Exception{
        JSONArray ids=new JSONArray();for(int i=0;i<10;i++)ids.put("id-"+i);
        Mock m=new Mock(reply(200,new JSONObject().put("ids",ids).toString()));
        DriveApi api=new DriveApi(()->"fake",m);
        java.util.concurrent.ExecutorService workers=java.util.concurrent.Executors.newFixedThreadPool(2);
        try{
            Set<String> used=new HashSet<>();List<java.util.concurrent.Future<String>> futures=new ArrayList<>();
            for(int i=0;i<10;i++)futures.add(workers.submit(api::nextUploadId));
            for(java.util.concurrent.Future<String> future:futures)assertTrue(used.add(future.get()));
            assertEquals(1,m.calls.size());assertTrue(m.calls.get(0).contains("count=10&"));
        }finally{workers.shutdownNow();}
    }
    @Test public void fixedFolderWinsEvenWithEventName()throws Exception{
        File dir=temp.newFolder();JSONObject dest=new JSONObject().put("folder","fixed");
        assertEquals("fixed",EventFolder.bind(dir,dest,"活動").getString("folder"));
        assertEquals("fixed",EventFolder.resolve(dir,"account","fixed",null));
        assertNull(EventFolder.bind(dir,null,"活動"));
        assertNull(EventFolder.bind(dir,new JSONObject().put("folder",""),"  "));
    }
    @Test public void lostFolderReplyThenUploadToConfirmedParent()throws Exception{
        File dir=temp.newFolder();JSONObject dest=EventFolder.bind(dir,new JSONObject().put("folder","").put("account","account"),"  晚宴  ");
        job.folder=dest.getString("folder");
        SessionReport.writeJson(new File(dir,"cloud-target.json"),dest);
        Mock first=new Mock(reply(200,"{\"ids\":[\"folder\"]}"),new IOException("lost reply"));
        try{EventFolder.resolve(dir,"account",job.folder,new DriveApi(()->"fake",first));fail();}catch(IOException expected){}
        assertEquals("",EventFolder.readyId(dir));
        Mock retry=new Mock(reply(409,"{}"),reply(200,"{\"mimeType\":\"application/vnd.google-apps.folder\",\"capabilities\":{\"canAddChildren\":true}}"));
        String actual=EventFolder.resolve(dir,"account",job.folder,new DriveApi(()->"fake",retry));
        assertEquals("folder",actual);assertEquals(actual,EventFolder.readyId(dir));
        assertEquals(actual,EventFolder.resolve(dir,"account",job.folder,null));
        for(Mock attempt:Arrays.asList(first,retry)){
            JSONObject body=new JSONObject(attempt.posted.get(0));assertEquals(actual,body.getString("id"));assertEquals("晚宴",body.getString("name"));
        }
        Mock upload=new Mock(reply(200,"{\"ids\":[\"file-id\"]}"),reply(200,"","Location",URI),reply(200,"{}"),reply(200,metadata().toString()));
        engine(upload,new ArrayList<>()).run(job,()->new FileInputStream(file),actual);
        assertEquals("DONE",job.state);assertEquals(actual,new JSONObject(upload.posted.get(0)).getJSONArray("parents").getString(0));
        try{EventFolder.resolve(dir,"another account",job.folder,null);fail();}catch(IOException expected){}
    }
    @Test public void storedMd5SkipsThePreUploadRead()throws Exception {
        job.md5=DriveApi.hashes(file,()->false)[1];
        java.util.concurrent.atomic.AtomicInteger opens=new java.util.concurrent.atomic.AtomicInteger();
        DriveApi.Input source=()->{opens.incrementAndGet();return new FileInputStream(file);};
        Mock m=new Mock(reply(200,"{\"ids\":[\"file-id\"]}"),reply(200,"","Location",URI),reply(200,"{}"),reply(200,metadata().put("trashed",false).toString()));
        engine(m,new ArrayList<>()).run(job,source);
        assertEquals("DONE",job.state);assertEquals(1,opens.get());assertEquals(job.size,m.bytes);
    }
    @Test public void chunkedUploadChecksMetadataAndPersistsIdFirst()throws Exception {
        Mock m=new Mock(reply(200,"{\"ids\":[\"file-id\"]}"),reply(200,"","Location",URI),reply(200,"{}"),reply(200,metadata().toString()));List<String> saves=new ArrayList<>();engine(m,saves).run(job);
        assertEquals("DONE",job.state);assertEquals(job.size,job.offset);assertEquals("",job.uri);assertEquals(job.size,m.bytes);assertTrue(saves.contains("file-id:0:UPLOADING"));assertEquals("bytes 0-5242892/5242893",m.ranges.get(2));assertEquals("file-id",new JSONObject(m.posted.get(0)).getString("id"));assertEquals("original.JPG",new JSONObject(m.posted.get(0)).getString("name"));
    }
    @Test public void lostFinalResponseReconcilesSameFileWithoutReupload()throws Exception {
        job.remote="file-id";job.uri=URI;Mock interrupted=new Mock(missing(),reply(308,"","Range","bytes=0-4194303"),new IOException("lost response"));
        try{engine(interrupted,new ArrayList<>()).run(job);fail();}catch(IOException expected){}assertEquals("file-id",job.remote);assertNotEquals("DONE",job.state);
        Mock recovered=new Mock(reply(200,metadata().toString()));engine(recovered,new ArrayList<>()).run(job);assertEquals("DONE",job.state);assertEquals(1,recovered.calls.size());assertEquals(0,recovered.bytes);
    }
    @Test public void resumesFromServerRangeNotLocalOffset()throws Exception {
        job.remote="file-id";job.uri=URI;job.offset=2;Mock m=new Mock(missing(),reply(308,"","Range","bytes=0-4194303"),reply(200,"{}"),reply(200,metadata().toString()));engine(m,new ArrayList<>()).run(job);assertEquals("bytes 4194304-5242892/5242893",m.ranges.get(2));assertEquals(job.size-4194304,m.bytes);
    }
    @Test public void expiredSessionRestartsWithSameId()throws Exception {
        job.remote="file-id";job.uri=URI;job.offset=500;Mock m=new Mock(missing(),reply(404,"{}"),reply(200,"","Location",URI),reply(308,"","Range","bytes=0-4194303"),reply(201,"{}"),reply(200,metadata().toString()));engine(m,new ArrayList<>()).run(job);assertEquals("file-id",new JSONObject(m.posted.get(0)).getString("id"));assertEquals("DONE",job.state);
    }
    @Test public void conflictReconcilesPreallocatedId()throws Exception {
        job.remote="file-id";Mock m=new Mock(missing(),reply(409,"{}"),reply(200,metadata().toString()));engine(m,new ArrayList<>()).run(job);assertEquals("DONE",job.state);assertEquals(0,m.bytes);
    }
    @Test public void checksumMismatchNeverCompletes()throws Exception {
        job.remote="file-id";Mock m=new Mock(reply(200,metadata().put("md5Checksum","bad").toString()));try{engine(m,new ArrayList<>()).run(job);fail();}catch(IOException expected){}assertNotEquals("DONE",job.state);
    }
    @Test public void wrongParentNeverCompletes()throws Exception {
        try{DriveApi.verify(metadata().put("parents",new JSONArray().put("other")),"file-id","folder",job.size,DriveApi.hashes(file,()->false)[1],job.sha);fail();}catch(IOException expected){}
    }
    @Test public void localCorruptionStopsBeforeNetwork()throws Exception {
        try(RandomAccessFile f=new RandomAccessFile(file,"rw")){f.seek(10);f.write(0);}Mock m=new Mock();try{engine(m,new ArrayList<>()).run(job);fail();}catch(IOException expected){}assertEquals(0,m.calls.size());
    }
    @Test public void invalidRangesRejected()throws Exception {
        for(String r:new String[]{"bytes=1-2","bytes=0-99999999999999999999","bytes=0-5242893","broken"})try{DriveApi.acknowledged(reply(308,"","Range",r),job.size);fail(r);}catch(IOException expected){}
        assertEquals(0,DriveApi.acknowledged(reply(308,""),job.size));assertEquals(256,DriveApi.acknowledged(reply(308,"","range","bytes=0-255"),job.size));
    }
    @Test public void tokensCannotFollowUntrustedUrls()throws Exception {
        for(String url:new String[]{"http://www.googleapis.com/drive/v3/files","https://www.googleapis.com.evil.test/drive/v3/files","https://www.googleapis.com@evil.test/drive/v3/files","https://www.googleapis.com:8443/drive/v3/files","https://www.googleapis.com/not-drive"})try{DriveApi.validateUrl(url);fail(url);}catch(IOException expected){}
        DriveApi.validateUrl(URI);
    }
    @Test public void rateLimitRetriesButPermissionAndQuotaNeedAction(){
        assertTrue(DriveApi.failure(reply(503,"{}")).retryable);assertTrue(DriveApi.failure(reply(429,"{}")).retryable);
        assertTrue(DriveApi.failure(reply(403,"{\"error\":{\"errors\":[{\"reason\":\"userRateLimitExceeded\"}]}}")).retryable);
        assertFalse(DriveApi.failure(reply(403,"{\"error\":{\"errors\":[{\"reason\":\"storageQuotaExceeded\"}]}}")).retryable);assertFalse(DriveApi.failure(reply(401,"{}")).retryable);
    }
    @Test public void cancellationPreventsSendingBody()throws Exception {
        Mock m=new Mock(reply(200,"{}"));try{new DriveApi(()->"fake",m).chunk(URI,file,0,100,()->true,n->{});fail();}catch(InterruptedIOException expected){}assertEquals(0,m.bytes);
    }
    @Test public void folderBrowserIsLimitedToCamLinkInSharedProject()throws Exception {
        Mock m=new Mock(reply(200,"{\"files\":[]}"),reply(200,"{\"id\":\"folder\",\"name\":\"Cam Link\"}"));DriveApi api=new DriveApi(()->"fake",m);assertEquals(0,api.folders().length());api.createFolder("Cam Link","folder");
        assertTrue(java.net.URLDecoder.decode(m.calls.get(0),"UTF-8").contains("appProperties has { key='camlinkFolder' and value='1' }"));assertEquals("1",new JSONObject(m.posted.get(0)).getJSONObject("appProperties").getString("camlinkFolder"));
    }
    @Test public void successResponseStillNeedsIndependentMetadata()throws Exception {
        job.remote="file-id";job.uri=URI;Mock m=new Mock(missing(),reply(200,"{}"),reply(503,"{}"));try{engine(m,new ArrayList<>()).run(job);fail();}catch(DriveApi.Failure expected){assertEquals(503,expected.status);}assertNotEquals("DONE",job.state);
    }
}
