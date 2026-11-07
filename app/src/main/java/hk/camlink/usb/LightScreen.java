package hk.camlink.usb;

import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.*;
import android.view.*;
import android.widget.*;

abstract class LightScreen extends ConsoleActivity {
    static final int PAPER=0xfffefdfb,INK=0xff19191b,GRAY=0xff656360,SOFT=0xfff3f2ee,EDGE=0xffe8e6e1;
    LinearLayout sheet,dock,body;
    ScrollView scroll;
    GradientDrawable rounded(int color,int radius){
        GradientDrawable shape=new GradientDrawable();shape.setColor(color);shape.setCornerRadius(dp(radius));return shape;
    }
    LinearLayout light(){
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        getWindow().setNavigationBarColor(PAPER);getWindow().setStatusBarColor(PAPER);
        sheet=new LinearLayout(this);sheet.setOrientation(LinearLayout.VERTICAL);sheet.setBackgroundColor(PAPER);
        sheet.setOnApplyWindowInsetsListener((v,i)->{v.setPadding(i.getSystemWindowInsetLeft(),i.getSystemWindowInsetTop(),i.getSystemWindowInsetRight(),i.getSystemWindowInsetBottom());return i;});
        scroll=new ScrollView(this);sheet.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        body=new LinearLayout(this);body.setOrientation(LinearLayout.VERTICAL);body.setPadding(dp(16),dp(10),dp(16),dp(16));scroll.addView(body);
        dock=new LinearLayout(this);dock.setGravity(Gravity.CENTER_VERTICAL);sheet.addView(dock);
        setContentView(sheet);return body;
    }
    TextView copy(String text,int sp,int color,boolean bold){
        TextView v=new TextView(this);v.setText(text);v.setTextSize(sp);v.setTextColor(color);
        if(bold)v.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));return v;
    }
    LinearLayout row(LinearLayout parent){LinearLayout r=new LinearLayout(this);r.setGravity(Gravity.CENTER_VERTICAL);parent.addView(r);return r;}
    View badge(String name,String fallback,int color,int size){
        int id=0;
        switch(name){case "Google Drive":id=R.drawable.brand_drive;break;case "OneDrive":id=R.drawable.brand_onedrive;break;
            case "Dropbox":id=R.drawable.brand_dropbox;break;case "Flickr":id=R.drawable.brand_flickr;break;case "Google Photos":id=R.drawable.brand_photos;break;}
        View view;
        if(id==0){TextView text=copy(fallback,14,color,true);text.setGravity(Gravity.CENTER);view=text;}
        else{ImageView image=new ImageView(this);image.setImageResource(id);int pad=dp(size/5);image.setPadding(pad,pad,pad,pad);view=image;}
        view.setBackground(rounded(SOFT,9));view.setLayoutParams(new LinearLayout.LayoutParams(dp(size),dp(size)));return view;
    }
    void space(LinearLayout parent,int height){parent.addView(new View(this),new LinearLayout.LayoutParams(1,dp(height)));}
    void hair(LinearLayout parent){View v=new View(this);v.setBackgroundColor(EDGE);parent.addView(v,new LinearLayout.LayoutParams(-1,dp(1)));}
    void fill(LinearLayout row,View child){row.addView(child,new LinearLayout.LayoutParams(0,-2,1));}
    Button pill(LinearLayout row,String text,Runnable action){
        Button b=new Button(this);b.setText(text);b.setTextSize(14);b.setAllCaps(false);b.setTextColor(INK);
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(0x18000000),rounded(SOFT,16),null));
        b.setMinHeight(dp(46));b.setMinimumHeight(dp(46));b.setMinWidth(0);b.setMinimumWidth(0);
        b.setPadding(dp(14),0,dp(14),0);row.addView(b);b.setOnClickListener(v->action.run());return b;
    }
    void navItem(String name,int icon,boolean active,Runnable click){
        LinearLayout tab=new LinearLayout(this);tab.setOrientation(LinearLayout.VERTICAL);tab.setGravity(Gravity.CENTER);
        boolean rightRail=dock.getOrientation()==LinearLayout.VERTICAL;
        dock.addView(tab,rightRail?new LinearLayout.LayoutParams(-1,0,1):new LinearLayout.LayoutParams(0,dp(58),1));
        ImageView mark=new ImageView(this);mark.setImageResource(icon);mark.setColorFilter(active?INK:GRAY);
        tab.addView(mark,new LinearLayout.LayoutParams(dp(20),dp(20)));
        TextView title=copy(name,12,active?INK:GRAY,active);
        title.setGravity(Gravity.CENTER);title.setIncludeFontPadding(false);title.setPadding(0,dp(3),0,0);
        tab.addView(title,new LinearLayout.LayoutParams(-1,-2));tab.setOnClickListener(v->click.run());
        tab.setSelected(active);tab.setContentDescription(name);
    }
    void destinations(){startActivity(new Intent(this,OtherClouds.class));}
    void shootDetails(){startActivity(new Intent(this,ShootDetail.class));}
}
