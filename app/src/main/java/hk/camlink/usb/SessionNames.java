package hk.camlink.usb;

import android.content.Context;
import android.content.SharedPreferences;
import java.io.File;

final class SessionNames {
    static final int LIMIT=100;
    static final String EXTRA="event_name";

    static String get(Context context,File directory){
        return context.getSharedPreferences("session_names",Context.MODE_PRIVATE).getString(directory.getName(),"");
    }
    static boolean save(Context context,File directory,String value){
        String name=value.trim();
        SharedPreferences.Editor editor=context.getSharedPreferences("session_names",Context.MODE_PRIVATE).edit();
        if(name.isEmpty())editor.remove(directory.getName());else editor.putString(directory.getName(),name);
        return editor.commit();
    }
}
