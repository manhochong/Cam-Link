package hk.camlink.usb;

import android.app.Instrumentation;
import android.os.SystemClock;
import android.view.*;
import android.view.inspector.WindowInspector;

final class PhotoGesturesCheck {
    static ReviewPhoto find(View v,String prefix){
        if(v instanceof ReviewPhoto && v.isShown() && v.getContentDescription()!=null &&
                v.getContentDescription().toString().startsWith(prefix))return (ReviewPhoto)v;
        if(v instanceof ViewGroup){ViewGroup g=(ViewGroup)v;for(int i=0;i<g.getChildCount();i++){ReviewPhoto p=find(g.getChildAt(i),prefix);if(p!=null)return p;}}
        return null;
    }
    static ReviewPhoto waitFor(Instrumentation t,String prefix){
        ReviewPhoto[] v={null};for(int j=0;j<60&&v[0]==null;j++){
            t.runOnMainSync(()->{for(View root:WindowInspector.getGlobalWindowViews()){ReviewPhoto p=find(root,prefix);if(p!=null&&p.getDrawable()!=null&&p.getWidth()>0){v[0]=p;break;}}});
            if(v[0]==null)SystemClock.sleep(80);
        }
        if(v[0]==null)throw new AssertionError("Missing photo: "+prefix);return v[0];
    }
    static void event(ReviewPhoto p,long start,int step,int action,float... xs){
        MotionEvent.PointerProperties[] props=new MotionEvent.PointerProperties[xs.length];
        MotionEvent.PointerCoords[] coords=new MotionEvent.PointerCoords[xs.length];
        for(int i=0;i<xs.length;i++){
            props[i]=new MotionEvent.PointerProperties();props[i].id=i;props[i].toolType=MotionEvent.TOOL_TYPE_FINGER;
            coords[i]=new MotionEvent.PointerCoords();coords[i].x=p.getWidth()*xs[i];coords[i].y=p.getHeight()*.5f;coords[i].pressure=1;coords[i].size=.1f;
        }
        MotionEvent e=MotionEvent.obtain(start,start+step*20,action,xs.length,props,coords,0,0,1,1,0,0,InputDevice.SOURCE_TOUCHSCREEN,0);
        try{p.dispatchTouchEvent(e);}finally{e.recycle();}
    }
    static void stroke(ReviewPhoto p,float a,float b){
        long now=SystemClock.uptimeMillis();event(p,now,0,0,a);event(p,now,1,2,(a+b)/2);event(p,now,2,1,b);
    }
    static float width(ReviewPhoto p){float[] m=new float[9];p.getImageMatrix().getValues(m);return m[0]*p.getDrawable().getIntrinsicWidth();}
    private static void doubleTap(Instrumentation test,ReviewPhoto photo){
        for(int i=0;i<2;i++){
            test.runOnMainSync(()->stroke(photo,.62f,.62f));
            SystemClock.sleep(100);
        }
        SystemClock.sleep(ViewConfiguration.getDoubleTapTimeout());
    }
    static void run(Instrumentation t,int count){
        ReviewPhoto p=waitFor(t,"最新照片 ");
        if(count>=2){String first=p.getContentDescription().toString().substring(5);
            t.runOnMainSync(()->stroke(p,.25f,.75f));ReviewPhoto old=waitFor(t,"瀏覽照片 ");
            if(old.getContentDescription().toString().substring(5).equals(first))throw new AssertionError("Page did not change image");
            t.runOnMainSync(()->stroke(old,.75f,.25f));waitFor(t,"最新照片 ");
        }
        t.runOnMainSync(()->stroke(p,.5f,.5f));ReviewPhoto big=waitFor(t,"大圖 ");
        checkZoom(t,big);
    }
    static void checkZoom(Instrumentation t,ReviewPhoto big){
        float[] original={0};
        t.runOnMainSync(()->original[0]=width(big));
        doubleTap(t,big);
        t.runOnMainSync(()->{
            if(!big.isAttachedToWindow()||Math.abs(width(big)/original[0]-2)>.02f)
                throw new AssertionError("Double tap: attached="+big.isAttachedToWindow()+" base="+original[0]+" scaled="+width(big)+" image="+big.getContentDescription());
        });
        doubleTap(t,big);
        t.runOnMainSync(()->{
            if(!big.isAttachedToWindow()||Math.abs(width(big)/original[0]-1)>.02f)
                throw new AssertionError("Second double tap did not restore fit");
        });
        t.runOnMainSync(()->{
            long now=SystemClock.uptimeMillis();float before=width(big);
            event(big,now,0,0,.38f);event(big,now,1,261,.38f,.62f);
            for(int j=1;j<=6;j++)event(big,now,j+1,2,.38f-j*.043f,.62f+j*.043f);
            event(big,now,8,262,.122f,.878f);event(big,now,9,1,.122f);
            if(width(big)<before*1.3f)throw new AssertionError("Pinch did not magnify the displayed image");
            stroke(big,.5f,.5f);
        });
        SystemClock.sleep(ViewConfiguration.getDoubleTapTimeout()+100);
        t.waitForIdleSync();if(big.isAttachedToWindow())throw new AssertionError("Large photo did not dismiss");
    }
}
