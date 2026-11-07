package hk.camlink.usb;

import android.app.Dialog;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.util.LruCache;
import android.view.*;
import android.widget.*;
import java.io.File;
import java.util.List;
import java.util.concurrent.*;

/** An album is scoped to the receive log of the selected shoot. */
public final class SessionAlbum extends LightScreen {
    private final ExecutorService thumbnails=Executors.newSingleThreadExecutor();
    private final ExecutorService originals=Executors.newSingleThreadExecutor();
    private final LruCache<String,Bitmap> cache=new LruCache<>(32);
    private List<String> names;
    private File directory;
    private Dialog viewer;
    private ReviewPhoto image;
    private TextView caption;
    private GridView grid;
    private Future<?> pending;
    private int index,request;

    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        light();
        sheet.removeView(scroll);
        sheet.removeView(dock);
        LinearLayout header=row(sheet);
        pill(header,"‹ 返回",this::finish);
        directory=new File(getIntent().getStringExtra("session"));
        String name=ShootDetail.eventName(this,directory);
        TextView heading=copy(name.isEmpty()?ShootDetail.title(directory):name,17,INK,true);
        heading.setMaxLines(2);
        heading.setPadding(dp(12),0,0,0);
        header.addView(heading);
        TextView status=label(sheet,"正在讀取本場照片…",15,GRAY);
        grid=new GridView(this);
        grid.setContentDescription("本場照片列表");
        grid.setNumColumns(GridView.AUTO_FIT);
        grid.setColumnWidth(dp(110));
        grid.setStretchMode(GridView.STRETCH_COLUMN_WIDTH);
        grid.setPadding(dp(8),dp(8),dp(8),dp(8));
        grid.setHorizontalSpacing(dp(4));
        grid.setVerticalSpacing(dp(4));
        sheet.addView(grid,new LinearLayout.LayoutParams(-1,0,1));
        grid.setOnItemClickListener((parent,view,position,id)->open(position));
        String initial=state==null?getIntent().getStringExtra("photo"):state.getString("photo");
        thumbnails.execute(()->{
            try{
                List<String> entries=ShootPanel.readPhotoNames(directory);
                runOnUiThread(()->{
                    if(isDestroyed()||isFinishing())return;
                    names=entries;
                    status.setText(entries.isEmpty()?"本場沒有照片":"本場照片 · "+entries.size()+" 張");
                    grid.setAdapter(new Tiles());
                    if(state!=null)grid.setSelection(state.getInt("first"));
                    int position=entries.indexOf(initial);
                    if(position>=0)open(position);
                });
            }catch(Exception e){runOnUiThread(()->status.setText("未能讀取本場照片紀錄"));}
        });
    }
    private Bitmap decode(String name,int size){
        try{return ShootPanel.thumbnail(this,new File(new File(directory,"jpg"),name),size);}
        catch(Exception e){return null;}
    }
    private static String filename(String name){return name.replaceFirst("^[0-9]+_","");}
    private final class Tile extends FrameLayout {
        final ImageView preview=new ImageView(SessionAlbum.this);
        final TextView name=copy("",11,0xffffffff,false);
        volatile String bound;
        Tile(){
            super(SessionAlbum.this);
            setLayoutParams(new AbsListView.LayoutParams(-1,dp(112)));
            setBackgroundColor(0xff343434);
            preview.setScaleType(ImageView.ScaleType.CENTER_CROP);
            addView(preview,new FrameLayout.LayoutParams(-1,-1));
            name.setSingleLine(true);
            name.setBackgroundColor(0xa0000000);
            addView(name,new FrameLayout.LayoutParams(-1,-2,Gravity.BOTTOM));
        }
    }
    private final class Tiles extends BaseAdapter {
        public int getCount(){return names.size();}
        public String getItem(int position){return names.get(position);}
        public long getItemId(int position){return position;}
        public View getView(int position,View recycled,ViewGroup parent){
            Tile tile=recycled==null?new Tile():(Tile)recycled;
            String name=getItem(position);
            if(name.equals(tile.bound))return tile;
            tile.bound=name;
            tile.name.setText(filename(name));
            tile.setContentDescription("照片 "+filename(name));
            Bitmap cached=cache.get(name);
            tile.preview.setImageBitmap(cached);
            if(cached==null)thumbnails.execute(()->{
                if(!name.equals(tile.bound))return;
                Bitmap result=decode(name,280);
                if(result!=null)cache.put(name,result);
                runOnUiThread(()->{if(name.equals(tile.bound))tile.preview.setImageBitmap(result);});
            });
            return tile;
        }
    }
    private void open(int position){
        if(viewer!=null)return;
        Dialog dialog=new Dialog(this,android.R.style.Theme_Material_NoActionBar_Fullscreen);
        viewer=dialog;
        FrameLayout frame=new FrameLayout(this);
        frame.setBackgroundColor(0xff000000);
        image=new ReviewPhoto(this,false,step->display(index+step),()->{},dialog::dismiss);
        image.enableDoubleTapZoom();
        frame.addView(image,new FrameLayout.LayoutParams(-1,-1));
        TextView close=overlay(frame,"關閉大圖",Gravity.TOP|Gravity.START);
        close.setOnClickListener(v->dialog.dismiss());
        caption=overlay(frame,"",Gravity.BOTTOM|Gravity.END);
        dialog.setContentView(frame);
        dialog.getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN|View.SYSTEM_UI_FLAG_HIDE_NAVIGATION|View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        dialog.setOnDismissListener(d->{request++;if(pending!=null)pending.cancel(false);viewer=null;image=null;caption=null;});
        dialog.show();
        display(position);
    }
    private TextView overlay(FrameLayout parent,String text,int gravity){
        TextView label=copy(text,14,0xffffffff,true);
        label.setPadding(dp(12),dp(10),dp(12),dp(10));
        label.setMinHeight(dp(48));
        label.setGravity(Gravity.CENTER);
        label.setBackground(rounded(0xb5222222,12));
        FrameLayout.LayoutParams params=new FrameLayout.LayoutParams(-2,-2,gravity);
        params.setMargins(dp(10),dp(10),dp(10),dp(10));
        parent.addView(label,params);
        return label;
    }
    private void display(int position){
        if(position<0||position>=names.size())return;
        index=position;
        int generation=++request;
        String name=names.get(position);
        String title=filename(name)+"  ·  "+(position+1)+"/"+names.size();
        caption.setText(title);
        image.setContentDescription("大圖 "+filename(name));
        image.show(name,cache.get(name));
        if(pending!=null)pending.cancel(false);
        pending=originals.submit(()->{
            Bitmap result=decode(name,3072);
            runOnUiThread(()->{
                if(viewer==null||generation!=request)return;
                if(result!=null)image.show(name,result);
                else caption.setText(title+"  ·  手機未能讀取原圖");
            });
        });
    }
    @Override protected void onSaveInstanceState(Bundle state){
        super.onSaveInstanceState(state);
        state.putInt("first",grid.getFirstVisiblePosition());
        if(viewer!=null)state.putString("photo",names.get(index));
    }
    @Override protected void onDestroy(){
        if(viewer!=null)viewer.dismiss();
        thumbnails.shutdownNow();
        originals.shutdownNow();
        super.onDestroy();
    }
}
