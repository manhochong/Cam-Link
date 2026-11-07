package hk.camlink.usb;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import java.util.Map;

/** Common presentation for the capture and transfer screens. */
abstract class ConsoleActivity extends Activity {
    private int resumeGeneration;
    @Override protected void onResume(){
        super.onResume();
        int generation=++resumeGeneration;
        String account=UploadService.resumeAccount(this);
        if(!account.isEmpty()&&!UploadService.running)new Thread(()->{
            if(!CloudStore.get(this).pending(account))return;
            runOnUiThread(()->{
                if(generation==resumeGeneration&&!UploadService.running&&account.equals(UploadService.resumeAccount(this)))
                    UploadService.start(this);
            });
        },"check-pending-drive").start();
        android.content.SharedPreferences one=OneDriveAuth.prefs(this);
        String oneId=one.getString("account","");
        if(!oneId.isEmpty()&&one.getBoolean("enabled",false)&&!one.getBoolean("paused",false)&&!OneDriveService.running)new Thread(()->{
            if(!OneDriveStore.get(this).pending(oneId))return;
            runOnUiThread(()->{
                if(generation==resumeGeneration&&!OneDriveService.running&&oneId.equals(OneDriveAuth.prefs(this).getString("account","")))
                    OneDriveService.start(this);
            });
        },"check-pending-onedrive").start();
    }
    @Override protected void onPause(){resumeGeneration++;super.onPause();}
    static final int BG=0xff151516,CARD=0xff212122,TEXT=0xfffaf6ee,MUTED=0xffc2bdb4,
            ACCENT=0xffffb44b,LINE=0xff464340;
    int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    private GradientDrawable surface(int color,int radius,int border){
        GradientDrawable shape=new GradientDrawable();
        shape.setColor(color);shape.setCornerRadius(dp(radius));
        if(border!=0)shape.setStroke(dp(1),border);
        return shape;
    }
    LinearLayout page(){
        ScrollView scroll=new ScrollView(this);
        scroll.setFillViewport(true);scroll.setBackgroundColor(BG);
        scroll.setOnApplyWindowInsetsListener((v,i)->{
            v.setPadding(i.getSystemWindowInsetLeft(),i.getSystemWindowInsetTop(),i.getSystemWindowInsetRight(),i.getSystemWindowInsetBottom());
            return i;
        });
        LinearLayout root=new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(10),dp(18),dp(26));
        scroll.addView(root);setContentView(scroll);return root;
    }
    private TextView type(String title,int size,int color,boolean bold){
        TextView view=new TextView(this);
        view.setText(title);view.setTextSize(size);view.setTextColor(color);
        view.setTypeface(Typeface.create(bold?"sans-serif-medium":"sans-serif",Typeface.NORMAL));
        return view;
    }
    TextView label(LinearLayout parent,String title,int size,int color,boolean bold){
        TextView view=type(title,size,color,bold);
        view.setPadding(0,dp(3),0,dp(3));parent.addView(view);return view;
    }
    TextView label(LinearLayout parent,String title,int size,int color){return label(parent,title,size,color,size>=18);}
    void masthead(LinearLayout parent,String title,String section){
        LinearLayout row=new LinearLayout(this);row.setGravity(Gravity.CENTER_VERTICAL);parent.addView(row);
        ImageView logo=new ImageView(this);logo.setImageResource(R.drawable.cam_link_mark);
        row.addView(logo,new LinearLayout.LayoutParams(dp(42),dp(42)));
        TextView brand=type("CAM LINK",15,TEXT,true);brand.setLetterSpacing(.12f);
        row.addView(brand,new LinearLayout.LayoutParams(0,-2,1));
        TextView version=type("v"+BuildConfig.VERSION_NAME,12,MUTED,false);
        version.setTypeface(Typeface.MONOSPACE);row.addView(version);
        rule(parent);
        LinearLayout heading=new LinearLayout(this);heading.setGravity(Gravity.CENTER_VERTICAL);parent.addView(heading);
        TextView name=type(title,29,TEXT,true);name.setAccessibilityHeading(true);
        heading.addView(name,new LinearLayout.LayoutParams(0,-2,1));
        TextView tag=type(section,11,ACCENT,true);tag.setLetterSpacing(.08f);heading.addView(tag);
    }
    void rule(LinearLayout parent){
        View line=new View(this);line.setBackgroundColor(LINE);
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,dp(1));
        lp.setMargins(0,dp(7),0,dp(7));parent.addView(line,lp);
    }
    LinearLayout card(LinearLayout parent){
        LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(16),dp(12),dp(16),dp(12));box.setBackground(surface(CARD,14,LINE));
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);
        lp.topMargin=dp(10);parent.addView(box,lp);return box;
    }
    void section(LinearLayout parent,String index,String title){
        LinearLayout row=new LinearLayout(this);row.setGravity(Gravity.CENTER_VERTICAL);parent.addView(row);
        TextView number=type(index,12,ACCENT,true);number.setTypeface(Typeface.MONOSPACE);
        number.setPadding(0,0,dp(10),0);row.addView(number);
        TextView name=type(title,15,TEXT,true);name.setAccessibilityHeading(true);row.addView(name);
    }
    Button button(LinearLayout parent,String title,boolean primary,View.OnClickListener action){
        Button button=new Button(this);
        button.setText(title);button.setAllCaps(false);button.setTextSize(15);
        button.setTextColor(new ColorStateList(new int[][]{{-android.R.attr.state_enabled},{}},
                new int[]{primary?0xffd0c4b2:0xff928f89,primary?BG:TEXT}));
        GradientDrawable shape=surface(primary?ACCENT:0xff2a2929,9,primary?0:LINE);
        if(primary)shape.setColor(new ColorStateList(new int[][]{{-android.R.attr.state_enabled},{}},new int[]{0xff48433c,ACCENT}));
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(primary?0x44000000:0x33ffffff),shape,null));
        button.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));button.setMinHeight(dp(48));
        button.setPadding(dp(12),dp(6),dp(12),dp(6));
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=dp(7);
        parent.addView(button,lp);button.setOnClickListener(action);return button;
    }
    Button button(LinearLayout parent,String title,boolean primary,Runnable action){
        return button(parent,title,primary,v->action.run());
    }
    final class QueueStrip extends LinearLayout {
        private final TextView verified,remaining,attention;
        QueueStrip(LinearLayout parent){
            super(ConsoleActivity.this);
            setPadding(0,dp(5),0,dp(5));parent.addView(this);
            verified=cell("已核對");remaining=cell("待完成");attention=cell("需處理");
        }
        private TextView cell(String name){
            LinearLayout box=new LinearLayout(ConsoleActivity.this);box.setOrientation(VERTICAL);
            addView(box,new LayoutParams(0,-2,1));
            TextView value=type("—",26,TEXT,true);value.setFontFeatureSettings("tnum");box.addView(value);
            box.addView(type(name,13,MUTED,false));return value;
        }
        void display(Map<String,Integer> counts){
            int issues=counts.getOrDefault("ERROR",0)+counts.getOrDefault("AUTH",0);
            int pending=counts.getOrDefault("WAITING",0)+counts.getOrDefault("UPLOADING",0)+counts.getOrDefault("RETRY",0);
            number(verified,counts.getOrDefault("DONE",0));number(remaining,pending);number(attention,issues);
            remaining.setTextColor(pending>0?ACCENT:TEXT);attention.setTextColor(issues>0?0xffff9e91:TEXT);
        }
        private void number(TextView cell,int n){
            String value=Integer.toString(n);
            if(!value.contentEquals(cell.getText()))cell.setText(value);
        }
    }
}
