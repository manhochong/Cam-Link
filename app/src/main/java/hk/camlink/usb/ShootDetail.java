package hk.camlink.usb;

import android.content.*;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.io.File;
import java.util.*;
import java.util.concurrent.*;
import org.json.JSONObject;

/** A shoot is an existing session directory. Delivery rows come from the durable queues. */
public final class ShootDetail extends LightScreen {
    private final ExecutorService reader=Executors.newSingleThreadExecutor();
    private final Handler timer=new Handler(Looper.getMainLooper());
    private final android.util.LruCache<String,Bitmap> thumbnails=new android.util.LruCache<>(16);
    private String path,signature="";private boolean history,visible,busy;
    private LinearLayout content;
    private HistoryAdapter historyAdapter;
    private File[] available=new File[0];
    private String query="";
    private TextView empty;
    private boolean historyLoaded;
    static String eventName(Context context,File directory){
        return SessionNames.get(context,directory);
    }
    private final android.util.LruCache<File,HistoryEntry> covers=new android.util.LruCache<>(32);
    private int historyGeneration;
    private final Runnable poll=new Runnable(){public void run(){load();timer.postDelayed(this,1800);}};
    static String title(File dir){
        String s=dir.getName();
        if(!s.matches("[0-9]{8}-[0-9]{6}-.+"))return "拍攝紀錄";
        return s.substring(0,4)+"."+s.substring(4,6)+"."+s.substring(6,8)+"　"+s.substring(9,11)+":"+s.substring(11,13);
    }
    @Override public void onCreate(Bundle state){
        super.onCreate(state);light();
        history=getIntent().getBooleanExtra("history",false);
        path=getIntent().getStringExtra("session");
        if(path==null)path=getSharedPreferences("state",0).getString("last_session","");
        LinearLayout back=row(body);pill(back,"‹ 返回",this::finish);
        space(body,12);content=new LinearLayout(this);content.setOrientation(LinearLayout.VERTICAL);body.addView(content);
        if(history){
            label(content,"拍攝紀錄",26,INK,true);
            empty=label(content,"",15,GRAY);empty.setVisibility(View.GONE);
            SearchView search=new SearchView(this);
            search.setIconifiedByDefault(false);search.setQueryHint("搜尋活動名稱");
            fill(back,search);
            search.setOnQueryTextListener(new SearchView.OnQueryTextListener(){
                public boolean onQueryTextSubmit(String text){search.clearFocus();return true;}
                public boolean onQueryTextChange(String text){query=text;filterHistory(false);return true;}
            });
            sheet.removeView(scroll);
            scroll.removeView(body);
            sheet.addView(body,0,new LinearLayout.LayoutParams(-1,-2));
            ListView list=new ListView(this);
            list.setContentDescription("拍攝場次列表");
            list.setPadding(dp(16),0,dp(16),0);
            sheet.addView(list,1,new LinearLayout.LayoutParams(-1,0,1));
            historyAdapter=new HistoryAdapter();list.setAdapter(historyAdapter);
            search.setQuery(state==null?"":state.getString("query",""),false);search.clearFocus();
            list.setOnItemClickListener((p,v,i,id)->startActivity(new Intent(this,ShootDetail.class)
                    .putExtra("session",historyAdapter.getItem(i).getPath())));
        }
        if(!history){if(!path.isEmpty()){pill(back,"更改場次名稱",this::rename);pill(back,"匯出清單",this::exportCsv);}
            dock.setPadding(dp(14),dp(6),dp(14),dp(6));Button change=pill(dock,"更改上傳目的地",this::destinations);change.setLayoutParams(new LinearLayout.LayoutParams(-1,-2));}
    }
    private void rename(){
        File directory=new File(path);
        EditText input=new EditText(this);
        input.setSingleLine(true);input.setHint("例如：週年晚宴");
        input.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(SessionNames.LIMIT)});
        input.setText(eventName(this,directory));input.selectAll();
        FrameLayout frame=new FrameLayout(this);
        frame.setPadding(dp(20),dp(8),dp(20),0);frame.addView(input);
        android.app.AlertDialog dialog=new android.app.AlertDialog.Builder(this).setTitle("更改場次名稱").setView(frame)
                .setNegativeButton("取消",null).setPositiveButton("儲存",null).show();
        Button save=dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE);
        save.setOnClickListener(v->{
            String name=input.getText().toString().trim();
            save.setEnabled(false);
            reader.execute(()->{
                boolean saved=SessionNames.save(this,directory,name);
                runOnUiThread(()->{
                    if(isDestroyed())return;
                    if(saved){dialog.dismiss();signature="";load();}
                    else{input.setError("未能儲存名稱，請再試");save.setEnabled(true);}
                });
            });
        });
    }
    private static final class Delivery{String folder,name;int done,total;}
    private static final class Snapshot{
        String title,account,folder;int count,done,waiting,failed,failedJobs;
        final List<Delivery> services=new ArrayList<>();
        final List<String> pending=new ArrayList<>(),delivered=new ArrayList<>();
        final Map<String,Bitmap> images=new HashMap<>();
    }
    private void load(){
        if(busy||!visible)return;
        if(history){listHistory();return;}
        if(path.isEmpty()){if(content.getChildCount()==0)label(content,"未有拍攝紀錄",20,INK);return;}
        busy=true;
        reader.execute(()->{
            Snapshot snap=null;try{snap=read(new File(path));}catch(Exception ignored){}
            Snapshot value=snap;runOnUiThread(()->{
                busy=false;if(!visible)return;
                if(value==null){if(content.getChildCount()==0)label(content,"暫時未能讀取本場紀錄",17,GRAY);return;}
                String custom=eventName(this,new File(path));
                if(!custom.isEmpty())value.title=custom;
                StringBuilder key=new StringBuilder(value.title).append(value.count).append('/').append(value.done).append('/').append(value.waiting).append('/').append(value.failed).append(value.pending).append(value.delivered);
                key.append('/').append(value.failedJobs);
                for(Delivery d:value.services)key.append(d.folder).append(d.done).append('/').append(d.total);
                if(!signature.contentEquals(key)){signature=key.toString();render(value);}
            });
        });
    }
    private Snapshot read(File dir)throws Exception{
        Snapshot s=new Snapshot();s.title=title(dir);
        CaptureService active=CaptureService.active;
        if(active!=null&&active.report!=null&&dir.equals(active.report.dir))s.count=CaptureService.good;
        else if(new File(dir,"summary.json").exists())s.count=Gallery.record(new File(dir,"summary.json")).optInt("valid_jpg");
        else try(java.io.BufferedReader log=java.nio.file.Files.newBufferedReader(new File(dir,"files.csv").toPath())){
            String line;while((line=log.readLine())!=null)if(line.startsWith("\"OK\","))s.count++;
        }
        String account="",folder="";
        File binding=new File(dir,"cloud-target.json");
        if(binding.isFile()){JSONObject json=Gallery.record(binding);account=json.getString("account");folder=json.getString("folder");}
        CloudStore db=CloudStore.get(this);int[] counts=db.shootCounts(dir.getName(),"",account,folder);
        s.account=account;s.folder=folder;
        if(folder.isEmpty()){
            try(Cursor c=db.getReadableDatabase().rawQuery("SELECT COUNT(*) FROM uploads WHERE session=? AND state IN ('AUTH','ERROR')",new String[]{dir.getName()})){
                c.moveToFirst();s.failedJobs=c.getInt(0);
            }
        }else s.failedJobs=counts[2];
        s.done=counts[1];s.failed=counts[2];s.waiting=Math.max(0,(folder.isEmpty()?counts[0]:Math.max(s.count,counts[0]))-s.done-s.failed);
        String where=folder.isEmpty()?"session=?":"session=? AND account=? AND folder=?";
        String[] args=folder.isEmpty()?new String[]{dir.getName()}:new String[]{dir.getName(),account,folder};
        try(Cursor c=db.getReadableDatabase().rawQuery("SELECT folder,COUNT(*),SUM(state='DONE') FROM uploads WHERE "+where+" GROUP BY folder",args)){
            while(c.moveToNext()){Delivery d=new Delivery();d.folder=c.getString(0);d.name="Google Drive";d.total=c.getInt(1);d.done=c.getInt(2);s.services.add(d);}
        }
        if(s.services.isEmpty()&&!folder.isEmpty()){Delivery d=new Delivery();d.name="Google Drive";d.folder=folder;s.services.add(d);}
        for(Delivery delivery:s.services){
            if(EventFolder.key(dir).equals(delivery.folder))delivery.folder=EventFolder.readyId(dir);
        }
        if(folder.equals(CloudStore.prefs(this).getString("folder",""))&&!folder.isEmpty()){
            String name=CloudStore.prefs(this).getString("folder_name","");if(!name.isEmpty())s.title=name;
        }
        Delivery dav=new Delivery();int[] davCounts=DavBackup.counts(this,dir,false);
        if(davCounts[0]>0){dav.name="WebDAV";dav.folder="";dav.total=davCounts[0];dav.done=davCounts[1];s.services.add(dav);}
        int[] pc=DavBackup.counts(this,dir,true);
        if(pc[0]>0){Delivery receiver=new Delivery();receiver.name="電腦";receiver.folder="";receiver.total=pc[0];receiver.done=pc[1];s.services.add(receiver);}
        int[] one=OneDriveStore.get(this).shoot(dir.getName(),"");
        if(one[0]>0){Delivery drive=new Delivery();drive.name="OneDrive";drive.folder="";drive.total=one[0];drive.done=one[1];s.services.add(drive);
            if(folder.isEmpty()&&counts[0]==0){s.done=one[1];s.failed=one[2];s.failedJobs=one[2];s.waiting=Math.max(0,Math.max(s.count,one[0])-s.done-s.failed);}}
        for(boolean done:new boolean[]{false,true}){
            List<String> list=done?s.delivered:s.pending;
            try(Cursor c=db.getReadableDatabase().rawQuery("SELECT DISTINCT path FROM uploads WHERE "+where+
                    (done?" AND state='DONE'":" AND state IN ('WAITING','UPLOADING','RETRY')")+" ORDER BY created DESC LIMIT 4",args)){
                while(c.moveToNext()){
                    String file=c.getString(0);list.add(file);Bitmap image=thumbnails.get(file);
                    if(image==null)try{image=ShootPanel.thumbnail(this,new File(file),220);thumbnails.put(file,image);}catch(Exception ignored){}
                    if(image!=null)s.images.put(file,image);
                }
            }
        }
        if(s.pending.isEmpty()&&s.delivered.isEmpty()&&one[0]>0){
            for(boolean done:new boolean[]{false,true}){
                List<String> list=done?s.delivered:s.pending;
                String states=done?"state='DONE'":"state IN ('WAITING','UPLOADING','RETRY')";
                try(Cursor c=OneDriveStore.get(this).getReadableDatabase().rawQuery("SELECT path FROM items WHERE session=? AND "+states+" ORDER BY created DESC LIMIT 4",new String[]{dir.getName()})){
                    while(c.moveToNext()){
                        String file=c.getString(0);list.add(file);Bitmap image=thumbnails.get(file);
                        if(image==null)try{image=ShootPanel.thumbnail(this,new File(file),220);thumbnails.put(file,image);}catch(Exception ignored){}
                        if(image!=null)s.images.put(file,image);
                    }
                }
            }
        }
        return s;
    }
    private void exportCsv(){
        if(path==null||path.isEmpty())return;
        Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("text/csv")
                .putExtra(Intent.EXTRA_TITLE,new File(path).getName()+"-delivery.csv");
        startActivityForResult(intent,91);
    }
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        if(request!=91||result!=RESULT_OK||data==null||data.getData()==null)return;
        Uri uri=data.getData();File dir=new File(path);
        reader.execute(()->{
            try{
                String csv=SessionExport.csv(this,dir);
                try(java.io.OutputStream out=getContentResolver().openOutputStream(uri)){
                    if(out==null)throw new java.io.IOException("無法寫入");
                    out.write(csv.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                }
                runOnUiThread(()->{if(!isDestroyed())android.widget.Toast.makeText(this,"清單已匯出",android.widget.Toast.LENGTH_SHORT).show();});
            }catch(Exception e){runOnUiThread(()->{if(!isDestroyed())android.widget.Toast.makeText(this,"匯出失敗",android.widget.Toast.LENGTH_SHORT).show();});}
        });
    }
    private void render(Snapshot s){
        content.removeAllViews();label(content,s.title,26,INK,true);label(content,"本場已收 "+s.count+" 張 JPG",14,GRAY);space(content,14);
        label(content,"目的地總覽",16,INK,true);space(content,6);
        Delivery computer=null,onedrive=null,drive=null;
        for(Delivery d:s.services){if("電腦".equals(d.name))computer=d;else if("OneDrive".equals(d.name))onedrive=d;else if("Google Drive".equals(d.name))drive=d;}
        overviewLine("電腦",computer,s.count,DavBackup.pcPaired(this));
        overviewLine("Google Drive",drive,s.count,CloudStore.prefs(this).getBoolean("enabled",false)&&!CloudStore.prefs(this).getString("account","").isEmpty());
        overviewLine("OneDrive",onedrive,s.count,OneDriveAuth.prefs(this).getBoolean("enabled",false)&&OneDriveAuth.signedIn(OneDriveAuth.prefs(this)));
        space(content,10);
        if(s.count>0){pill(row(content),"瀏覽本場照片",()->openAlbum(null));space(content,12);}
        if(s.count>0||!s.services.isEmpty())pill(row(content),"每張 JPG 耗時",this::showTimes);
        for(Delivery d:s.services){
            LinearLayout r=row(content);r.setPadding(dp(9),dp(9),dp(9),dp(9));r.setBackground(rounded(SOFT,12));
            r.addView(badge(d.name,"W",INK,34));LinearLayout desc=new LinearLayout(this);desc.setPadding(dp(9),0,0,0);desc.setOrientation(LinearLayout.VERTICAL);fill(r,desc);
            label(desc,d.name,17,INK,true);label(desc,"已核對 "+d.done+" / "+Math.max(d.total,s.count)+" 張 · 待傳 "+Math.max(0,Math.max(d.total,s.count)-d.done)+" 張",14,GRAY);
            if(!d.folder.isEmpty())pill(r,"開啟",()->startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse("https://drive.google.com/drive/folders/"+Uri.encode(d.folder)))));
            space(content,4);
        }
        if(s.services.isEmpty())label(content,"照片只存於手機",16,INK);
        String summary=computer!=null&&s.folder.isEmpty()?"電腦已核對 "+computer.done+" 張 · 待傳 "+Math.max(0,s.count-computer.done)+" 張":onedrive!=null&&s.folder.isEmpty()?"OneDrive 已核對 "+s.done+" 張 · 待傳 "+s.waiting+" 張":"Drive 已核對 "+s.done+" 張 · 待傳 "+s.waiting+" 張";
        space(content,12);label(content,summary,14,GRAY);
        if(s.failedJobs>0)pill(row(content),"需處理 "+s.failedJobs+" 項　›",()->showFailures(s));
        ProgressBar progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);
        progress.setMax(Math.max(1,s.count));progress.setProgress(s.done);content.addView(progress);
        strip("待傳照片",s.pending,s.images,"本場沒有待傳照片");
        strip("最近已核對",s.delivered,s.images,"尚未有已核對照片");
    }
    private void overviewLine(String name,Delivery d,int photos,boolean enabled){
        String text;
        if(!enabled&&d==null)text=name+"　·　未啟用";
        else if(d==null)text=name+"　·　本場尚未排隊";
        else text=name+"　·　已核對 "+d.done+"　待傳 "+Math.max(0,Math.max(d.total,photos)-d.done);
        label(content,text,14,GRAY);
    }
    private void showTimes(){
        File session=new File(path);
        ListView list=new ListView(this);
        android.app.AlertDialog dialog=new android.app.AlertDialog.Builder(this)
                .setTitle("每張 JPG 耗時").setView(list).setNegativeButton("關閉",null)
                .setNeutralButton("更新",null).create();
        TextView note=copy("排隊計至首次開始處理。上傳計算傳送 JPG 及等候回應的時間。Drive 核對另計；重試會累加。「—」代表尚未有紀錄。",14,GRAY,false);
        note.setPadding(dp(18),dp(10),dp(18),dp(10));list.addHeaderView(note,null,false);
        dialog.show();
        Button update=dialog.getButton(android.app.AlertDialog.BUTTON_NEUTRAL);
        Runnable refresh=()->{
            update.setEnabled(false);
            reader.execute(()->{
                List<String> rows;
                try{rows=PhotoTimes.read(CloudStore.get(this),session);}
                catch(Exception e){rows=Collections.singletonList("未能讀取耗時紀錄，請按更新重試");}
                List<String> result=rows;
                runOnUiThread(()->{
                    if(isDestroyed()||!dialog.isShowing())return;
                    int pos=list.getFirstVisiblePosition();
                    list.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_list_item_1,result));
                    list.setSelection(pos);update.setEnabled(true);
                });
            });
        };
        update.setOnClickListener(v->refresh.run());refresh.run();
    }
    private void showFailures(Snapshot shoot){
        String session=new File(path).getName();
        String current=CloudStore.prefs(this).getString("account","");
        reader.execute(()->{
            ArrayList<String> labels=new ArrayList<>();
            boolean own=false,login=false;
            try(Cursor rows=CloudStore.get(this).shootFailures(session,shoot.account,shoot.folder)){
                while(rows.moveToNext()){
                    boolean auth="AUTH".equals(rows.getString(1));
                    boolean matches=!current.isEmpty()&&current.equals(rows.getString(3));
                    own|=matches;login|=auth||!matches;
                    String reason=rows.getString(2);
                    if(reason.isEmpty())reason=auth?"需要 Google 授權":"未有詳細錯誤紀錄";
                    labels.add(rows.getString(0)+"\n"+reason+(auth?"\n請先重新登入 Google Drive":"")
                            +(matches?"":"\n原上傳帳戶："+rows.getString(4)));
                }
            }
            boolean canRetry=own,showSettings=login;
            runOnUiThread(()->{
                if(!visible||isFinishing())return;
                android.app.AlertDialog.Builder dialog=new android.app.AlertDialog.Builder(this)
                    .setTitle("本場需處理的上傳").setNegativeButton("關閉",null);
                if(labels.isEmpty())dialog.setMessage("本場沒有需要重試的照片");
                else{
                    ListView list=new ListView(this);
                    list.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_list_item_1,labels));
                    dialog.setView(list);
                }
                if(showSettings)dialog.setNeutralButton("Drive 設定",(d,w)->startActivity(new Intent(this,CloudActivity.class)));
                if(canRetry)dialog.setPositiveButton("只重試本場",(d,w)->retryFailures(session,current,shoot.folder));
                dialog.show();
            });
        });
    }
    private void retryFailures(String session,String account,String folder){
        reader.execute(()->{
            SharedPreferences cloud=CloudStore.prefs(this);
            if(!account.equals(cloud.getString("account","")))return;
            int changed=CloudStore.get(this).retryShoot(session,account,folder);
            runOnUiThread(()->{
                boolean paused=cloud.getBoolean("paused",false);
                if(changed>0&&!paused&&account.equals(cloud.getString("account","")))UploadService.start(this);
                if(!visible)return;
                String message=changed==0?"本場沒有需要重試的照片":"本場 "+changed+" 項已加入待傳"+(paused?"，上傳仍暫停":"");
                Toast.makeText(this,message,Toast.LENGTH_LONG).show();
                signature="";load();
            });
        });
    }
    private void strip(String heading,List<String> paths,Map<String,Bitmap> images,String empty){
        space(content,15);label(content,heading,15,INK,true);
        if(paths.isEmpty()){label(content,empty,14,GRAY);return;}
        LinearLayout row=row(content);
        for(String path:paths){ImageView photo=new ImageView(this);photo.setBackground(rounded(SOFT,10));photo.setClipToOutline(true);
            photo.setImageBitmap(images.get(path));photo.setScaleType(ImageView.ScaleType.CENTER_CROP);photo.setContentDescription(new File(path).getName());
            photo.setOnClickListener(v->openAlbum(new File(path).getName()));
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,dp(76),1);lp.rightMargin=dp(4);row.addView(photo,lp);}
    }
    private void openAlbum(String photo){
        startActivity(new Intent(this,SessionAlbum.class).putExtra("session",path).putExtra("photo",photo));
    }
    private static final class HistoryEntry {
        int count=-1;
        Bitmap cover;
    }
    private HistoryEntry readHistoryEntry(File directory){
        HistoryEntry entry=new HistoryEntry();
        try{
            List<String> names=ShootPanel.readPhotoNames(directory);
            entry.count=names.size();
            File originals=new File(directory,"jpg");
            for(int i=names.size()-1;i>=0;i--){
                try{entry.cover=ShootPanel.thumbnail(this,new File(originals,names.get(i)),180);break;}
                catch(Exception unavailable){if(Thread.currentThread().isInterrupted())break;}
            }
        }catch(java.io.IOException missing){
            try{entry.count=Gallery.record(new File(directory,"summary.json")).optInt("valid_jpg",-1);}
            catch(Exception ignored){}
        }
        return entry;
    }
    private final class HistoryRow extends LinearLayout{
        final ImageView cover=new ImageView(ShootDetail.this);
        final TextView event,date,count;
        volatile File bound;
        HistoryRow(){
            super(ShootDetail.this);
            setGravity(Gravity.CENTER_VERTICAL);setPadding(0,dp(7),0,dp(7));
            cover.setBackground(rounded(SOFT,9));cover.setClipToOutline(true);
            addView(cover,new LinearLayout.LayoutParams(dp(72),dp(54)));
            LinearLayout labels=new LinearLayout(ShootDetail.this);
            labels.setOrientation(LinearLayout.VERTICAL);labels.setPadding(dp(12),0,0,0);fill(this,labels);
            event=label(labels,"",17,INK,true);event.setMaxLines(2);
            date=label(labels,"",15,INK,true);count=label(labels,"",14,GRAY);
            addView(copy("›",20,GRAY,true));
        }
        void show(HistoryEntry entry){
            Bitmap bitmap=entry==null?null:entry.cover;
            if(bitmap==null){
                cover.setScaleType(ImageView.ScaleType.CENTER);
                cover.setImageResource(R.drawable.nav_history);
            }else{
                cover.setScaleType(ImageView.ScaleType.CENTER_CROP);
                cover.setImageBitmap(bitmap);
            }
            count.setText(entry==null?"…":entry.count<0?"張數未能讀取":entry.count+" 張照片");
            cover.setContentDescription(bitmap==null?null:"場次封面");
            setContentDescription((event.getVisibility()==VISIBLE?event.getText()+"，":"")+date.getText()+"，"+count.getText());
        }
    }
    private final class HistoryAdapter extends BaseAdapter{
        File[] directories=new File[0];
        public int getCount(){return directories.length;}
        public File getItem(int i){return directories[i];}
        public long getItemId(int i){return i;}
        public View getView(int i,View recycled,ViewGroup parent){
            HistoryRow item=recycled==null?new HistoryRow():(HistoryRow)recycled;
            File directory=getItem(i);
            item.bound=directory;item.date.setText(title(directory));
            String name=eventName(ShootDetail.this,directory);item.event.setText(name);
            item.event.setVisibility(name.isEmpty()?View.GONE:View.VISIBLE);
            HistoryEntry cached=covers.get(directory);item.show(cached);
            if(cached==null){
                int generation=historyGeneration;
                reader.execute(()->{
                    if(!directory.equals(item.bound))return;
                    HistoryEntry entry=readHistoryEntry(directory);
                    runOnUiThread(()->{
                        if(isDestroyed()||historyGeneration!=generation)return;
                        covers.put(directory,entry);
                        if(directory.equals(item.bound))item.show(entry);
                    });
                });
            }
            return item;
        }
    }
    private long previousLiveCount=-1;
    private File previousLiveDirectory;
    // Used by the history reader only. A changed receive log is checked again.
    private final Map<File,Long> emptyLogs=new HashMap<>();
    private final Map<File,Long> nonemptyLogs=new HashMap<>();
    private boolean includeInHistory(File directory){
        File log=new File(directory,"files.csv");
        long size=log.length();
        if(size>0){
            if(Objects.equals(emptyLogs.get(directory),size))return false;
            if(Objects.equals(nonemptyLogs.get(directory),size))return true;
        }
        try{
            boolean hasPhotos=!ShootPanel.readPhotoNames(directory).isEmpty();
            (hasPhotos?nonemptyLogs:emptyLogs).put(directory,size);
            (hasPhotos?emptyLogs:nonemptyLogs).remove(directory);
            return hasPhotos;
        }catch(java.io.IOException unreadable){
            try{return Gallery.record(new File(directory,"summary.json")).optInt("valid_jpg",-1)!=0;}
            catch(Exception unknown){return true;}
        }
    }
    private void listHistory(){
        busy=true;reader.execute(()->{
            File[] files=new File(getExternalFilesDir(null),"sessions").listFiles(f->f.isDirectory()&&f.getName().matches("[0-9]{8}-[0-9]{6}-.+"));
            if(files!=null)Arrays.sort(files,Comparator.comparing(File::getName).reversed());
            CaptureService service=CaptureService.active;
            SessionReport live=service==null?null:service.report;
            File active=live==null?null:live.dir;
            int count=live==null?-1:live.photoCount();
            List<File> display=new ArrayList<>();
            if(files!=null)for(File file:files){
                if(file.equals(active)?count>0:includeInHistory(file))display.add(file);
            }
            File[] directories=display.toArray(new File[0]);
            runOnUiThread(()->{busy=false;if(!visible)return;
                boolean liveChanged=count!=previousLiveCount||!Objects.equals(previousLiveDirectory,active);
                if(liveChanged){
                    historyGeneration++;
                    if(previousLiveDirectory!=null)covers.remove(previousLiveDirectory);
                    if(active!=null)covers.remove(active);
                    previousLiveDirectory=active;previousLiveCount=count;
                }
                available=directories;historyLoaded=true;filterHistory(liveChanged);
            });
        });
    }
    private void filterHistory(boolean refreshRows){
        if(historyAdapter==null)return;
        String needle=query.trim().toLowerCase(Locale.ROOT);
        List<File> matches=new ArrayList<>();
        for(File directory:available){
            if(needle.isEmpty()||eventName(this,directory).toLowerCase(Locale.ROOT).contains(needle)
                    ||title(directory).contains(needle))matches.add(directory);
        }
        File[] filtered=matches.toArray(new File[0]);
        if(refreshRows||!Arrays.equals(historyAdapter.directories,filtered)){
            historyAdapter.directories=filtered;historyAdapter.notifyDataSetChanged();
        }
        empty.setText(needle.isEmpty()?"暫時沒有收到照片的場次":"找不到符合的場次");
        empty.setVisibility(historyLoaded&&filtered.length==0?View.VISIBLE:View.GONE);
    }
    @Override protected void onSaveInstanceState(Bundle state){super.onSaveInstanceState(state);state.putString("query",query);}
    @Override protected void onResume(){super.onResume();if(history)filterHistory(true);visible=true;timer.post(poll);}
    @Override protected void onPause(){visible=false;timer.removeCallbacks(poll);super.onPause();}
    @Override protected void onDestroy(){reader.shutdownNow();super.onDestroy();}
}
