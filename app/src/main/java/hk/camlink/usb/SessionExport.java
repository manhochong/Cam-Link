package hk.camlink.usb;

import android.content.Context;
import android.database.Cursor;
import java.io.File;
import java.util.*;

/** Simple per-session delivery CSV for operators. */
final class SessionExport {
    private SessionExport(){}
    static String csv(Context c,File dir)throws Exception{
        String session=dir.getName();
        Map<String,Row> rows=new LinkedHashMap<>();
        File photos=new File(dir,"jpg");
        File csv=new File(dir,"files.csv");
        if(csv.isFile()){
            for(String line:java.nio.file.Files.readAllLines(csv.toPath())){
                if(!line.startsWith("\"OK\","))continue;
                String[] parts=line.split(",(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)",-1);
                if(parts.length<8)continue;
                String local=unquote(parts[4]);String camera=unquote(parts[3]);String sha=unquote(parts[7]);String time=unquote(parts.length>13?parts[13]:"");
                Row row=rows.computeIfAbsent(local.isEmpty()?camera:local,k->new Row());
                row.name=camera.isEmpty()?local:camera;row.local=local;row.sha=sha;row.time=time;
            }
        }
        File[] files=photos.listFiles((d,n)->n.toLowerCase(Locale.ROOT).endsWith(".jpg"));
        if(files!=null)for(File f:files){
            Row row=rows.computeIfAbsent(f.getName(),k->new Row());
            if(row.name.isEmpty())row.name=f.getName().replaceFirst("^[0-9]+_","");
            row.local=f.getName();
            File marker=Gallery.marker(f);
            if(marker.isFile())try{org.json.JSONObject ref=Gallery.record(marker);row.sha=ref.optString("sha",row.sha);row.name=ref.optString("name",row.name);}catch(Exception ignored){}
        }
        try(Cursor cur=CloudStore.get(c).getReadableDatabase().rawQuery("SELECT path,name,sha,state,created FROM uploads WHERE session=?",new String[]{session})){
            while(cur.moveToNext()){
                String path=cur.getString(0);String key=new File(path).getName();
                Row row=rows.computeIfAbsent(key,k->new Row());
                if(row.name.isEmpty())row.name=cur.getString(1);
                if(row.sha.isEmpty())row.sha=cur.getString(2)==null?"":cur.getString(2);
                row.drive=cur.getString(3);row.local=key;
            }
        }
        try(Cursor cur=OneDriveStore.get(c).getReadableDatabase().rawQuery("SELECT path,name,sha,state FROM items WHERE session=?",new String[]{session})){
            while(cur.moveToNext()){
                String key=new File(cur.getString(0)).getName();
                Row row=rows.computeIfAbsent(key,k->new Row());
                if(row.name.isEmpty())row.name=cur.getString(1);
                if(row.sha.isEmpty())row.sha=cur.getString(2)==null?"":cur.getString(2);
                row.onedrive=cur.getString(3);row.local=key;
            }
        }
        String prefix=new File(dir,"jpg").getAbsolutePath()+File.separator;
        try(Cursor cur=DavBackup.db(c).getReadableDatabase().rawQuery("SELECT path,name,sha,state FROM items WHERE profile LIKE 'pc:%' AND substr(path,1,?)=?",new String[]{Integer.toString(prefix.length()),prefix})){
            while(cur.moveToNext()){
                String key=new File(cur.getString(0)).getName();
                Row row=rows.computeIfAbsent(key,k->new Row());
                if(row.name.isEmpty())row.name=cur.getString(1);
                if(row.sha.isEmpty())row.sha=cur.getString(2)==null?"":cur.getString(2);
                int state=cur.getInt(3);row.computer=state==1?"DONE":state==2?"ERROR":"WAITING";row.local=key;
            }
        }
        StringBuilder out=new StringBuilder("filename,local,time,sha256,computer,drive,onedrive\n");
        for(Row row:rows.values()){
            out.append(csv(row.name)).append(',').append(csv(row.local)).append(',').append(csv(row.time)).append(',')
                    .append(csv(row.sha)).append(',').append(csv(blank(row.computer))).append(',')
                    .append(csv(blank(row.drive))).append(',').append(csv(blank(row.onedrive))).append('\n');
        }
        return out.toString();
    }
    private static String blank(String s){return s==null||s.isEmpty()?"—":s;}
    private static String unquote(String s){if(s==null)return "";s=s.trim();if(s.length()>=2&&s.charAt(0)=='"'&&s.charAt(s.length()-1)=='"')return s.substring(1,s.length()-1).replace("\"\"","\"");return s;}
    private static String csv(String s){if(s==null)s="";if(s.indexOf(',')>=0||s.indexOf('"')>=0||s.indexOf('\n')>=0)return '"'+s.replace("\"","\"\"")+'"';return s;}
    private static final class Row{String name="",local="",time="",sha="",computer="",drive="",onedrive="";}
}
