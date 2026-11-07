package hk.camlink.usb;

import org.junit.Test;
import static org.junit.Assert.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

public final class DriveHttpRouteTest {
    static final class Connection extends HttpURLConnection {
        final ByteArrayOutputStream sent=new ByteArrayOutputStream();boolean disconnected,fail;
        Connection(URL u){super(u);}
        public void connect(){} public boolean usingProxy(){return false;}public void disconnect(){disconnected=true;}
        @Override public OutputStream getOutputStream()throws IOException{if(fail)throw new IOException("link lost");return sent;}
        @Override public int getResponseCode(){return 200;}
        @Override public InputStream getInputStream(){return new ByteArrayInputStream("{}".getBytes(java.nio.charset.StandardCharsets.UTF_8));}
        @Override public Map<String,List<String>> getHeaderFields(){return Collections.emptyMap();}
    }
    @Test public void everyHttpRequestUsesProvidedNetworkAndClosesConnection()throws Exception{
        List<Connection> routes=new ArrayList<>();DriveApi.Http http=new DriveApi.Http(url->{Connection c=new Connection(url);routes.add(c);return c;});
        assertEquals(200,http.send("POST",DriveApi.BASE+"files",Collections.singletonMap("Authorization","Bearer fixture"),DriveApi.text("photo metadata")).status);
        assertEquals(200,http.send("GET",DriveApi.BASE+"files/file",Collections.emptyMap(),null).status);
        assertEquals(2,routes.size());assertEquals("photo metadata",routes.get(0).sent.toString("UTF-8"));
        for(Connection c:routes){assertTrue(c.disconnected);assertFalse(c.getInstanceFollowRedirects());}
    }
    @Test public void rejectsOtherDestinationsBeforeOpeningAnyNetwork()throws Exception{
        AtomicInteger opened=new AtomicInteger();DriveApi.Http http=new DriveApi.Http(url->{opened.incrementAndGet();return new Connection(url);});
        assertThrows(IOException.class,()->http.send("GET","http://192.168.54.1/",Collections.emptyMap(),null));
        assertThrows(IOException.class,()->http.send("GET","https://example.com/drive/v3/files",Collections.emptyMap(),null));assertEquals(0,opened.get());
    }
    @Test public void lostNetworkClosesConnectionInsteadOfFallingBackImplicitly()throws Exception{
        Connection c=new Connection(new URL(DriveApi.BASE+"files"));c.fail=true;AtomicInteger opened=new AtomicInteger();
        DriveApi.Http http=new DriveApi.Http(url->{opened.incrementAndGet();return c;});
        assertThrows(IOException.class,()->http.send("POST",c.getURL().toString(),Collections.emptyMap(),DriveApi.text("data")));
        assertTrue(c.disconnected);assertEquals(1,opened.get());
    }
}
