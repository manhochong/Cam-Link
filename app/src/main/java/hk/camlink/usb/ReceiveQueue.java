package hk.camlink.usb;

import java.util.*;

/** Session-scoped dedup. Baseline must be complete before events can discover new objects. */
public final class ReceiveQueue {
    public static final class Item {
        public final int handle;public final long discovered;public final String source;
        public int attempts;public long retryAt;
        Item(int h,long t,String s){handle=h;discovered=t;source=s;}
    }
    private final Set<Integer> baseline=new HashSet<>(),known=new HashSet<>();
    private final LinkedHashMap<Integer,Item> pending=new LinkedHashMap<>();
    private final Map<Integer,Item> failed=new LinkedHashMap<>();
    public synchronized void baseline(int[] handles){for(int h:handles)baseline.add(h);}
    public synchronized int[] baselineHandles(){int[] out=new int[baseline.size()];int i=0;for(int h:baseline)out[i++]=h;return out;}
    /** Photos still on the card that the interrupted session never finished. A renumbered card is left untouched. */
    public static final class Gap { public final boolean renumbered; public final int recover; Gap(boolean renumbered,int recover){this.renumbered=renumbered;this.recover=recover;} }
    public synchronized Gap reopen(int[] previousBaseline,int[] finished,int[] now,long time){
        Set<Integer> previous=new HashSet<>();for(int h:previousBaseline)previous.add(h);
        int overlap=0;for(int h:now)if(previous.contains(h))overlap++;
        if(!previous.isEmpty()&&overlap==0)return new Gap(true,0);
        baseline.addAll(previous);for(int h:finished)baseline.add(h);
        int recover=0;for(int h:now)if(add(h,time,"reconnect"))recover++;
        return new Gap(false,recover);
    }
    public synchronized boolean add(int h,long now,String source){if(baseline.contains(h)||!known.add(h))return false;pending.put(h,new Item(h,now,source));return true;}
    public synchronized Item next(long now){Iterator<Item> it=pending.values().iterator();while(it.hasNext()){Item i=it.next();if(i.retryAt<=now){it.remove();return i;}}return null;}
    public synchronized void retry(Item i,long now){i.attempts++;i.retryAt=now+Math.min(5000L,250L<<Math.min(i.attempts,4));pending.put(i.handle,i);}
    public synchronized void fail(Item i){failed.put(i.handle,i);}
    synchronized void retryIfFailed(int handle){
        Item item=failed.remove(handle);
        if(item!=null){item.attempts=0;item.retryAt=0;pending.put(handle,item);}
    }
    public synchronized void retryFailed(){for(Item i:failed.values()){i.attempts=0;i.retryAt=0;pending.put(i.handle,i);}failed.clear();}
    public synchronized int dropPending(){int n=pending.size();pending.clear();return n;}
    /** Remove handles already copied when the camera kept those numbers. No overlap means the card was renumbered, so nothing is removed. */
    public synchronized int omitFinished(int[] finished){
        Set<Integer> done=new HashSet<>();for(int h:finished)done.add(h);
        int present=0;for(int h:done)if(known.contains(h))present++;
        if(present==0||present*2<done.size())return 0;
        int removed=0;for(int h:done){if(!known.contains(h))continue;if(pending.remove(h)!=null)removed++;baseline.add(h);}
        return removed;
    }
    public synchronized void newestFirst(){
        ArrayList<Item> items=new ArrayList<>(pending.values());
        items.sort((a,b)->Integer.compareUnsigned(b.handle,a.handle));
        pending.clear();for(Item item:items)pending.put(item.handle,item);
    }
    public synchronized int pending(){return pending.size();}
    public synchronized int failed(){return failed.size();}
    public synchronized int discovered(){return known.size();}
    public synchronized int baselineCount(){return baseline.size();}
    public synchronized List<Integer> unresolved(){List<Integer> ids=new ArrayList<>(pending.keySet());ids.addAll(failed.keySet());return ids;}
}
