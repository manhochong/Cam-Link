package hk.camlink.usb;

import android.database.Cursor;
import java.io.*;
import java.nio.file.Files;
import java.util.*;
import java.util.regex.*;

/** Join receive records to queued destinations by unique local name, never camera filename. */
final class PhotoTimes {
    private static final Pattern CELL=Pattern.compile("\"((?:[^\"]|\"\")*)\"(?:,|$)");
    private static final class Photo{
        String name;
        long receive=-1;
        final List<String> deliveries=new ArrayList<>();
        Photo(String name){this.name=name;}
    }
    static List<String> read(CloudStore db,File session)throws IOException{
        Map<String,Photo> photos=new LinkedHashMap<>();
        File csv=new File(session,"files.csv");
        if(csv.isFile())try(BufferedReader input=Files.newBufferedReader(csv.toPath())){
            String line;
            while((line=input.readLine())!=null){
                if(!line.startsWith("\"OK\","))continue;
                Matcher cells=CELL.matcher(line);
                List<String> columns=new ArrayList<>(13);
                while(columns.size()<13&&cells.find())columns.add(cells.group(1).replace("\"\"","\""));
                if(columns.size()<5)continue;
                Photo photo=new Photo(columns.get(3));
                photos.put(columns.get(4),photo);
                if(columns.size()==13)try{
                    long start=Long.parseLong(columns.get(11)),end=Long.parseLong(columns.get(12));
                    if(start>=0&&end>=start)photo.receive=end-start;
                }catch(NumberFormatException ignored){}
            }
        }
        String sql="SELECT path,name,state,created,queue_ms,send_ms,verify_ms FROM uploads WHERE session=? ORDER BY created,key";
        try(Cursor rows=db.getReadableDatabase().rawQuery(sql,new String[]{session.getName()})){
            while(rows.moveToNext()){
                String local=new File(rows.getString(0)).getName();
                Photo photo=photos.get(local);
                if(photo==null){photo=new Photo(rows.getString(1));photos.put(local,photo);}
                String state=rows.getString(2);
                long queue=rows.getLong(4);
                String waiting=queue==-1&&"WAITING".equals(state)?
                        duration(System.currentTimeMillis()-rows.getLong(3))+"（等待中）":duration(queue);
                photo.deliveries.add(CloudStore.label(state)+"\n排隊 "+waiting+"　上傳 "+duration(rows.getLong(5))+
                        "\nDrive 核對 "+duration(rows.getLong(6)));
            }
        }
        List<String> result=new ArrayList<>();
        for(Photo photo:photos.values()){
            String details=photo.deliveries.isEmpty()?"未加入 Drive 上傳":String.join("\n",photo.deliveries);
            result.add(photo.name+"\n接收 "+duration(photo.receive)+"\n"+details);
        }
        Collections.reverse(result);
        if(result.isEmpty())result.add("本場尚未有 JPG 紀錄");
        return result;
    }
    private static String duration(long ms){
        if(ms<0)return "—";
        if(ms==0)return "<1 毫秒";
        if(ms<1000)return ms+" 毫秒";
        return String.format(Locale.ROOT,"%.2f 秒",ms/1000.0);
    }
}
