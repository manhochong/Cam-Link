package hk.camlink.usb;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Matrix;
import android.view.*;
import android.widget.ImageView;
import java.util.function.IntConsumer;

/** At base magnification horizontal drags page; above it they pan. */
final class ReviewPhoto extends ImageView {
    private final boolean crop;
    private final IntConsumer page;
    private final Runnable inspect;
    private final ScaleGestureDetector pinch;
    private GestureDetector viewerTaps;
    private final int slop;
    private float zoom=1,offsetX,offsetY,startX,startY,lastX,lastY,focusX,focusY;
    private boolean multi,moved;
    private Bitmap image;
    private String key="";
    ReviewPhoto(Context ctx,boolean crop,IntConsumer page,Runnable inspect,Runnable tap){
        super(ctx);this.crop=crop;this.page=page;this.inspect=inspect;
        setScaleType(ScaleType.MATRIX);slop=ViewConfiguration.get(ctx).getScaledTouchSlop();
        setOnClickListener(v->tap.run());
        pinch=new ScaleGestureDetector(ctx,new ScaleGestureDetector.SimpleOnScaleGestureListener(){
            @Override public boolean onScaleBegin(ScaleGestureDetector d){
                focusX=d.getFocusX();focusY=d.getFocusY();inspect.run();return true;
            }
            @Override public boolean onScale(ScaleGestureDetector d){
                float next=Math.max(1,Math.min(6,zoom*d.getScaleFactor())),ratio=next/zoom;
                float x=d.getFocusX()-getWidth()/2f,y=d.getFocusY()-getHeight()/2f;
                offsetX=x-(focusX-getWidth()/2f-offsetX)*ratio;
                offsetY=y-(focusY-getHeight()/2f-offsetY)*ratio;
                focusX=d.getFocusX();focusY=d.getFocusY();zoom=next;layoutImage();return true;
            }
        });pinch.setQuickScaleEnabled(false);
    }
    void resetView(){zoom=1;offsetX=offsetY=0;layoutImage();}
    void enableDoubleTapZoom(){
        viewerTaps=new GestureDetector(getContext(),new GestureDetector.SimpleOnGestureListener(){
            @Override public boolean onDown(MotionEvent event){return true;}
            @Override public boolean onSingleTapConfirmed(MotionEvent event){
                if(isAttachedToWindow()&&!multi&&!moved)performClick();
                return true;
            }
            @Override public boolean onDoubleTapEvent(MotionEvent event){
                if(event.getActionMasked()!=MotionEvent.ACTION_UP||multi||moved)return true;
                if(zoom>1){
                    resetView();
                }else{
                    inspect.run();
                    zoom=2;
                    offsetX=(1-zoom)*(event.getX()-getWidth()/2f);
                    offsetY=(1-zoom)*(event.getY()-getHeight()/2f);
                    layoutImage();
                }
                return true;
            }
        });
        viewerTaps.setIsLongpressEnabled(false);
    }
    void show(String id,Bitmap next){
        if(key.equals(id)&&image==next)return;
        if(!key.equals(id)){zoom=1;offsetX=offsetY=0;}
        key=id;image=next;
        if(next==null)setImageDrawable(null);else setImageBitmap(next);
        layoutImage();
    }
    @Override protected void onSizeChanged(int w,int h,int oldW,int oldH){super.onSizeChanged(w,h,oldW,oldH);layoutImage();}
    private void layoutImage(){
        if(getDrawable()==null||getWidth()==0||getHeight()==0)return;
        float w=getDrawable().getIntrinsicWidth(),h=getDrawable().getIntrinsicHeight();
        float sx=getWidth()/w,sy=getHeight()/h,scale=zoom*(crop?Math.max(sx,sy):Math.min(sx,sy));
        float mx=Math.max(0,(w*scale-getWidth())/2),my=Math.max(0,(h*scale-getHeight())/2);
        offsetX=zoom<=1?0:Math.max(-mx,Math.min(mx,offsetX));offsetY=zoom<=1?0:Math.max(-my,Math.min(my,offsetY));
        Matrix transform=new Matrix();transform.setScale(scale,scale);transform.postTranslate((getWidth()-w*scale)/2+offsetX,(getHeight()-h*scale)/2+offsetY);setImageMatrix(transform);
    }
    @Override public boolean onTouchEvent(MotionEvent e){
        int action=e.getActionMasked();float x=e.getX(),y=e.getY();
        if(action==MotionEvent.ACTION_DOWN){multi=moved=false;startX=lastX=x;startY=lastY=y;}
        if(action==MotionEvent.ACTION_POINTER_DOWN){multi=true;getParent().requestDisallowInterceptTouchEvent(true);}
        pinch.onTouchEvent(e);
        if(viewerTaps!=null)viewerTaps.onTouchEvent(e);
        switch(action){
            case MotionEvent.ACTION_DOWN:if(zoom>1)getParent().requestDisallowInterceptTouchEvent(true);break;
            case MotionEvent.ACTION_MOVE:
                float dx=x-startX,dy=y-startY;
                if(Math.abs(dx)>slop||Math.abs(dy)>slop)moved=true;
                if(moved&&Math.abs(dx)>Math.abs(dy))getParent().requestDisallowInterceptTouchEvent(true);
                if(zoom>1&&e.getPointerCount()==1){offsetX+=x-lastX;offsetY+=y-lastY;layoutImage();}
                lastX=x;lastY=y;break;
            case MotionEvent.ACTION_POINTER_UP:
                int remaining=e.getActionIndex()==0?1:0;lastX=e.getX(remaining);lastY=e.getY(remaining);break;
            case MotionEvent.ACTION_UP:
                if(!multi&&!moved){if(viewerTaps==null)performClick();}
                else if(!multi&&zoom<=1&&Math.abs(x-startX)>Math.max(slop*3,getWidth()*.08f)&&Math.abs(x-startX)>1.25f*Math.abs(y-startY))page.accept(x>startX?-1:1);
                if(getParent()!=null)getParent().requestDisallowInterceptTouchEvent(false);break;
            case MotionEvent.ACTION_CANCEL:getParent().requestDisallowInterceptTouchEvent(false);break;
        }
        return true;
    }
}
