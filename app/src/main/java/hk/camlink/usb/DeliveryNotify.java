package hk.camlink.usb;

import android.app.*;
import android.content.*;
import android.os.Build;

/** User-visible alerts for first delivery, session completion, and upload issues. */
final class DeliveryNotify {
    private static final String CHANNEL="delivery";
    private static final int FIRST=21, DONE=22, ISSUE=23;
    private DeliveryNotify(){}
    private static void ensure(Context c){
        NotificationManager nm=c.getSystemService(NotificationManager.class);
        if(nm.getNotificationChannel(CHANNEL)==null)
            nm.createNotificationChannel(new NotificationChannel(CHANNEL,"傳送通知",NotificationManager.IMPORTANCE_DEFAULT));
    }
    private static void show(Context c,int id,String title,String text){
        ensure(c);
        PendingIntent open=PendingIntent.getActivity(c,id,new Intent(c,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT|(Build.VERSION.SDK_INT>=31?PendingIntent.FLAG_IMMUTABLE:0));
        Notification n=new Notification.Builder(c,CHANNEL).setSmallIcon(R.drawable.ic_camera)
                .setContentTitle(title).setContentText(text).setContentIntent(open).setAutoCancel(true).build();
        c.getSystemService(NotificationManager.class).notify(id,n);
    }
    static void first(Context c,String name){show(c,FIRST,"第一張已收到",name==null||name.isEmpty()?"本場第一張 JPG 已存入手機":name);}
    static void finished(Context c,int good,int bad){
        show(c,DONE,"本場接收完成",bad>0?("已驗證 "+good+" 張，失敗 "+bad+" 張"):("已驗證 "+good+" 張 JPG"));
    }
    static void issue(Context c,String detail){
        show(c,ISSUE,"上傳需處理",detail==null||detail.isEmpty()?"有照片未能傳到目的地":detail);
    }
}
