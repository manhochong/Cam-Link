package hk.camlink.usb;

import java.io.File;
import java.io.IOException;
import org.json.JSONObject;

/** The queue keeps a stable local destination even when a shoot begins offline. */
final class EventFolder {
    static String key(File session){return "event:"+session.getName();}

    static JSONObject bind(File session,JSONObject destination,String name)throws Exception{
        if(destination==null||!destination.getString("folder").isEmpty())return destination;
        if(name==null||name.trim().isEmpty())return null;
        return destination.put("eventName",name.trim()).put("folder",key(session));
    }

    private static File receipt(File session){return new File(session,"drive-event-folder.json");}
    private static JSONObject read(File file)throws Exception{
        return new JSONObject(new String(java.nio.file.Files.readAllBytes(file.toPath()),java.nio.charset.StandardCharsets.UTF_8));
    }
    static String readyId(File session)throws Exception{
        if(!receipt(session).isFile())return "";
        JSONObject saved=read(receipt(session));
        return saved.optBoolean("ready")?saved.getString("id"):"";
    }

    static String resolve(File session,String account,String folder,DriveApi api)throws Exception{
        if(!folder.startsWith("event:"))return folder;
        return resolveEvent(session,account,folder,api);
    }
    private static synchronized String resolveEvent(File session,String account,String folder,DriveApi api)throws Exception{
        JSONObject binding=read(new File(session,"cloud-target.json"));
        if(!folder.equals(key(session))||!folder.equals(binding.getString("folder"))||!account.equals(binding.getString("account")))
            throw new IOException("活動資料夾與本場上傳設定不符");
        File file=receipt(session);
        JSONObject saved;
        if(file.isFile())saved=read(file);
        else{
            saved=new JSONObject().put("id",api.generateId());
            SessionReport.writeJson(file,saved);
        }
        String id=saved.getString("id");
        if(!saved.optBoolean("ready")){
            try{
                JSONObject created=api.createFolder(binding.getString("eventName"),id);
                if(!id.equals(created.getString("id")))throw new IOException("Drive 回傳的資料夾不符");
            }catch(DriveApi.Failure e){
                if(e.status!=409)throw e;
                api.checkFolder(id);
            }
            SessionReport.writeJson(file,saved.put("ready",true));
        }
        return id;
    }
}
