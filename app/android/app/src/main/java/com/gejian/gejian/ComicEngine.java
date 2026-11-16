package com.gejian.gejian;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import org.json.*;
import org.opencv.android.OpenCVLoader;
import org.opencv.android.Utils;
import org.opencv.core.*;
import org.opencv.imgproc.Imgproc;
import org.pytorch.executorch.EValue;
import org.pytorch.executorch.Tensor;
import org.pytorch.executorch.Module;
import java.io.*;
import java.util.*;

/** Original trained weights; inference and source geometry run on-device. */
public final class ComicEngine {
 private final Context context;
 private Module magi,bubble;
 private static final int MAGI_WIDTH=800, MAGI_HEIGHT=1136;
 public ComicEngine(Context context){this.context=context;}
 public synchronized void warmup()throws IOException{init();}
 private String model(String name)throws IOException{File target=new File(context.getFilesDir(),name+"-et15-v071-1136.pte");if(!target.exists()){File temp=new File(target+".tmp");try(InputStream in=context.getAssets().open("models/"+name+".pte");OutputStream out=new FileOutputStream(temp)){byte[] data=new byte[65536];int count;while((count=in.read(data))>0)out.write(data,0,count);}if(!temp.renameTo(target))throw new IOException("无法保存识别模型");}return target.getAbsolutePath();}
 private void init()throws IOException{if(!OpenCVLoader.initLocal())throw new IOException("OpenCV 加载失败");if(magi==null)magi=Module.load(model("magi"));if(bubble==null)bubble=Module.load(model("bubbles"));}
 static class Box{double x,y,w,h,score;int index,kind;Box(double x,double y,double w,double h,double score,int index,int kind){this.x=x;this.y=y;this.w=w;this.h=h;this.score=score;this.index=index;this.kind=kind;}double cx(){return x+w/2;}double cy(){return y+h/2;}double area(){return w*h;}JSONArray json(){return new JSONArray(Arrays.asList(x,y,w,h));}}
 static class Panel{Box box;List<Point> poly;String source;int artworkGroup=-1;JSONArray paths=new JSONArray(),bubbles=new JSONArray();Panel(Box b,List<Point> p,String s){box=b;poly=p;source=s;}}
 static class Frame{Box box;List<Point> poly;double area;boolean simple;Frame(Box b,List<Point> p,double a,boolean s){box=b;poly=p;area=a;simple=s;}}
 static double overlap(Box a,Box b){return Math.max(0,Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x))*Math.max(0,Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y));}
 static double iou(Box a,Box b){double n=overlap(a,b);return n/Math.max(1,a.area()+b.area()-n);}
 static List<Point> rectangle(Box b){return new ArrayList<>(Arrays.asList(new Point(b.x,b.y),new Point(b.x+b.w,b.y),new Point(b.x+b.w,b.y+b.h),new Point(b.x,b.y+b.h)));}
 static JSONArray points(List<Point> points){JSONArray a=new JSONArray();for(Point p:points)a.put(new JSONArray(Arrays.asList(p.x,p.y)));return a;}
 static List<Point> simplified(MatOfPoint contour,double epsilon){MatOfPoint2f input=new MatOfPoint2f(contour.toArray()),output=new MatOfPoint2f();Imgproc.approxPolyDP(input,output,epsilon,true);List<Point> result=output.toList();input.release();output.release();return result;}
 static double perimeter(MatOfPoint c){MatOfPoint2f f=new MatOfPoint2f(c.toArray());double n=Imgproc.arcLength(f,true);f.release();return n;}
 static Box bounds(MatOfPoint p){org.opencv.core.Rect r=Imgproc.boundingRect(p);return new Box(r.x,r.y,r.width,r.height,1,0,0);}
 static List<Box> nms(List<Box> boxes,double threshold){boxes.sort((a,b)->Double.compare(b.score,a.score));List<Box> out=new ArrayList<>();for(Box b:boxes){boolean skip=false;for(Box a:out)if(a.kind==b.kind&&iou(a,b)>threshold){skip=true;break;}if(!skip)out.add(b);}return out;}
 static class Input{float[] values;long[] mask;double scale;int left,top;Input(float[] v,long[] m,double s,int l,int t){values=v;mask=m;scale=s;left=l;top=t;}}
 private Input input(Bitmap bitmap,int width,int height,boolean detr){
  double ratio=Math.min((double)width/bitmap.getWidth(),(double)height/bitmap.getHeight());
  int w=Math.max(1,(int)Math.round(bitmap.getWidth()*ratio)),h=Math.max(1,(int)Math.round(bitmap.getHeight()*ratio));
  int left=detr?0:(width-w)/2,top=detr?0:(height-h)/2;
  Bitmap scaled=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);Canvas canvas=new Canvas(scaled);canvas.drawColor(detr?Color.BLACK:Color.rgb(114,114,114));canvas.drawBitmap(bitmap,null,new Rect(left,top,left+w,top+h),new Paint(Paint.FILTER_BITMAP_FLAG));
  int count=width*height;int[] pixels=new int[count];scaled.getPixels(pixels,0,width,0,0,width,height);scaled.recycle();float[] values=new float[3*count];long[] mask=detr?new long[count]:null;
  float[] mean={.485f,.456f,.406f},std={.229f,.224f,.225f};
  for(int i=0;i<count;i++){boolean valid=i%width>=left&&i%width<left+w&&i/width>=top&&i/width<top+h;if(detr)mask[i]=valid?1:0;for(int ch=0;ch<3;ch++){float value=((pixels[i]>>(16-8*ch))&255)/255f;values[ch*count+i]=detr?(valid?(value-mean[ch])/std[ch]:0):value;}}
  return new Input(values,mask,ratio,left,top);
 }
 public synchronized String recognize(String path)throws Exception{
  long start=System.nanoTime();init();Bitmap original=BitmapFactory.decodeFile(path);if(original==null)throw new IOException("图片无法解码");
  // Geometry is retained at source resolution up to 1800px, then mapped exactly back.
  int originalW=original.getWidth(),originalH=original.getHeight();double geometryScale=Math.min(1,1800.0/Math.max(originalW,originalH));Bitmap bitmap=geometryScale<1?Bitmap.createScaledBitmap(original,(int)Math.round(originalW*geometryScale),(int)Math.round(originalH*geometryScale),true):original;
  int w=bitmap.getWidth(),h=bitmap.getHeight();Mat rgba=new Mat(),gray=new Mat();Utils.bitmapToMat(bitmap,rgba);Imgproc.cvtColor(rgba,gray,Imgproc.COLOR_RGBA2GRAY);rgba.release();
  Bitmap detectorBitmap=neutralBackground(bitmap,gray);
  Mat geometryGray=gray;if(detectorBitmap!=bitmap){Mat normalized=new Mat();Utils.bitmapToMat(detectorBitmap,normalized);geometryGray=new Mat();Imgproc.cvtColor(normalized,geometryGray,Imgproc.COLOR_RGBA2GRAY);normalized.release();}
  try{
   Input mi=input(detectorBitmap,MAGI_WIDTH,MAGI_HEIGHT,true);EValue[] detection=magi.forward(EValue.from(Tensor.fromBlob(mi.values,new long[]{1,3,MAGI_HEIGHT,MAGI_WIDTH})),EValue.from(Tensor.fromBlob(mi.mask,new long[]{1,MAGI_HEIGHT,MAGI_WIDTH})));
   float[] classes=detection[0].toTensor().getDataAsFloatArray(),boxes=detection[1].toTensor().getDataAsFloatArray(),dialogue=detection[2].toTensor().getDataAsFloatArray();List<Box> panelBoxes=new ArrayList<>(),textBoxes=new ArrayList<>(),ownershipTexts=new ArrayList<>(),characterBoxes=new ArrayList<>();
   for(int i=0;i<300;i++){int label=0;for(int k=1;k<3;k++)if(classes[i*3+k]>classes[i*3+label])label=k;double score=classes[i*3+label];if((label==0&&score>.3)||(label==2&&score>.2)||(label==1&&score>.25)){double bw=boxes[i*4+2]*w,bh=boxes[i*4+3]*h,x=Math.max(0,boxes[i*4]*w-bw/2),y=Math.max(0,boxes[i*4+1]*h-bh/2);Box b=new Box(x,y,Math.min(bw,w-x),Math.min(bh,h-y),score,i,label);if(label==2&&b.area()>w*h*.008)panelBoxes.add(b);if(label==1){ownershipTexts.add(b);if(dialogue[i]>.35)textBoxes.add(b);}if(label==0)characterBoxes.add(b);}}
   panelBoxes=nms(panelBoxes,.5);panelBoxes=removePageProposal(panelBoxes,w*h);panelBoxes.sort((a,b)->Double.compare(a.y,b.y));if(panelBoxes.size()>20)panelBoxes=panelBoxes.subList(0,20);
   JSONArray detectorPanels=new JSONArray(),detectorScores=new JSONArray();for(Box b:panelBoxes){detectorPanels.put(b.json());detectorScores.put(b.score);}boolean darkBackground=darkBackground(gray);
   List<Box> recovered=darkBackground?darkCells(gray,panelBoxes):null;if(recovered!=null)panelBoxes=recovered;
   List<Frame> frames=frames(geometryGray);frames.addAll(inkFrames(gray));List<Frame> balloonFrames=new ArrayList<>(frames(gray));balloonFrames.addAll(whiteBalloons(gray));Mat edge=new Mat(),edgeGray=new Mat();Imgproc.Canny(gray,edge,40,100);Core.bitwise_not(edge,edgeGray);frames.addAll(frames(edgeGray));edge.release();edgeGray.release();List<Panel> panels=removeNested(makePanels(geometryGray,panelBoxes,frames,darkBackground),w*h);
   Input bi=input(detectorBitmap,640,640,false);EValue[] masks=bubble.forward(EValue.from(Tensor.fromBlob(bi.values,new long[]{1,3,640,640})));float[] prediction=masks[0].toTensor().getDataAsFloatArray(),proto=masks[1].toTensor().getDataAsFloatArray();List<Box> bubbleBoxes=new ArrayList<>(), yoloPanels=new ArrayList<>();int n=8400;
   for(int i=0;i<n;i++){int label=0;float score=prediction[4*n+i];for(int k=1;k<4;k++)if(prediction[(4+k)*n+i]>score){label=k;score=prediction[(4+k)*n+i];}if((label!=0&&label!=1)||score<(label==0?.35:.65))continue;double bw=prediction[2*n+i]/bi.scale,bh=prediction[3*n+i]/bi.scale,x=(prediction[i]-prediction[2*n+i]/2-bi.left)/bi.scale,y=(prediction[n+i]-prediction[3*n+i]/2-bi.top)/bi.scale;Box b=new Box(Math.max(0,x),Math.max(0,y),Math.min(w,x+bw)-Math.max(0,x),Math.min(h,y+bh)-Math.max(0,y),score,i,0);if(b.w>6&&b.h>6){if(label==0&&b.area()<w*h*.45)bubbleBoxes.add(b);if(label==1&&b.area()>w*h*.025)yoloPanels.add(b);}}
   yoloPanels=nms(yoloPanels,.5);
   long strong=yoloPanels.stream().filter(b->b.score>=.80).count();double panelArea=yoloPanels.stream().mapToDouble(Box::area).sum();
   if(yoloPanels.size()>=2&&strong>=2&&panelArea>w*h*.20){
    List<Panel> proposed=makePanels(geometryGray,restoreTruncatedProposals(yoloPanels,panelBoxes),frames,darkBackground);
    for(Panel panel:proposed)panel.source="YOLO-container+"+panel.source;
    panels=darkBackground?proposed:reconcileScenes(panels,proposed,w*h);
   }
   bubbleBoxes=nms(bubbleBoxes,.45);panels=recoverExteriorRegions(geometryGray,panels,panelBoxes,ownershipTexts,bubbleBoxes,frames,darkBackground);int accepted=0;
   for(Box b:bubbleBoxes){if(accepted>=50)break;boolean text=false;for(Box t:textBoxes)if(overlap(t,b)/Math.max(1,t.area())>.7){text=true;break;}if(!text&&b.score<.65)continue;List<Point> contour=bubbleContour(b,bi,prediction,proto,balloonFrames,w,h,gray,textBoxes);if(contour.size()<3)continue;Panel owner=null;double best=-1;for(Panel p:panels){double score=overlap(b,p.box)/Math.max(1,b.area());if(score>best){best=score;owner=p;}}if(owner!=null&&best>.15){owner.bubbles.put(new JSONObject().put("polygon",points(contour)).put("box",b.json()).put("score",b.score).put("evidence",text?"MAGI-dialogue+YOLO-mask":"high-confidence-YOLO-mask"));accepted++;}}
   panels=order(panels,h);certifyOpenGutters(geometryGray,panels);linkArtwork(panels,nms(characterBoxes,.5),w,h);coverage(geometryGray,panels,characterBoxes,ownershipTexts);JSONArray result=new JSONArray();double sx=(double)originalW/w,sy=(double)originalH/h;for(Panel p:panels){List<JSONObject> ordered=new ArrayList<>();for(int i=0;i<p.bubbles.length();i++)ordered.add(p.bubbles.getJSONObject(i));ordered.sort((a,b)->{JSONArray aa=a.optJSONArray("box"),bb=b.optJSONArray("box");double ay=aa.optDouble(1),by=bb.optDouble(1);return Math.abs(ay-by)<Math.min(aa.optDouble(3),bb.optDouble(3))*.5?Double.compare(bb.optDouble(0),aa.optDouble(0)):Double.compare(ay,by);});JSONArray balloons=new JSONArray();for(JSONObject balloon:ordered){scalePoints(balloon.getJSONArray("polygon"),sx,sy);balloons.put(balloon);}JSONArray poly=points(p.poly);scalePoints(poly,sx,sy);for(int i=0;i<p.paths.length();i++)scalePoints(p.paths.getJSONArray(i),sx,sy);result.put(new JSONObject().put("box",new JSONArray(Arrays.asList(p.box.x*sx,p.box.y*sy,p.box.w*sx,p.box.h*sy))).put("polygon",poly).put("paths",p.paths).put("score",p.box.score).put("source",p.source).put("artworkGroup",p.artworkGroup).put("bubbles",balloons));}
   JSONArray characters=new JSONArray();for(Box b:nms(characterBoxes,.5))characters.put(new JSONObject().put("box",b.json()).put("score",b.score));
   JSONArray tile=new JSONArray();JSONArray stock=stockPaths(bitmap,panels,sx,sy,tile);
   return new JSONObject().put("completeRegions",true).put("stockColor",stock.length()>0?stockColour(bitmap,tile,sx,sy):"#ffffff").put("stockPaths",stock).put("stockTile",tile).put("background",darkBackground?"#000000":"#ffffff").put("width",originalW).put("height",originalH).put("panels",result).put("engine","ExecuTorch 1.5.1 / MAGI + YOLO segmentation / OpenCV").put("seconds",(System.nanoTime()-start)/1e9).put("detectorScores",detectorScores).put("detectorPanels",detectorPanels).put("characters",characters).put("bubbleCount",accepted).toString();
  }finally{if(geometryGray!=gray)geometryGray.release();if(detectorBitmap!=bitmap)detectorBitmap.recycle();gray.release();if(bitmap!=original)bitmap.recycle();original.recycle();}
 }

 // Group only detected shared artwork; panel alignment alone is insufficient.
 static int root(int[] parent,int i){while(parent[i]!=i){parent[i]=parent[parent[i]];i=parent[i];}return i;}
 static void join(int[] parent,int a,int b){parent[root(parent,b)]=root(parent,a);}
 static double polygonShare(List<Point> polygon,List<Point> scene){
  MatOfPoint2f outline=new MatOfPoint2f();outline.fromList(polygon);MatOfPoint2f frame=new MatOfPoint2f();frame.fromList(scene);
  org.opencv.core.Rect bounds=Imgproc.boundingRect(outline);int inside=0,shared=0;
  int stride=Math.max(2,(int)Math.sqrt(Math.max(1,bounds.area())/8000));
  for(int y=bounds.y;y<bounds.y+bounds.height;y+=stride)for(int x=bounds.x;x<bounds.x+bounds.width;x+=stride){Point q=new Point(x,y);if(Imgproc.pointPolygonTest(outline,q,false)>=0){inside++;if(Imgproc.pointPolygonTest(frame,q,false)>=0)shared++;}}
  outline.release();frame.release();return shared/(double)Math.max(1,inside);
 }
 static void linkArtwork(List<Panel> panels,List<Box> characters,int w,int h)throws JSONException{
  int n=panels.size();int[] parent=new int[n];for(int i=0;i<n;i++)parent[i]=i;
  for(Panel panel:panels)for(int bi=0;bi<panel.bubbles.length();bi++){
   JSONArray points=panel.bubbles.getJSONObject(bi).getJSONArray("polygon");List<Point> shape=new ArrayList<>();for(int k=0;k<points.length();k++)shape.add(new Point(points.getJSONArray(k).getDouble(0),points.getJSONArray(k).getDouble(1)));
   int first=-1;for(int i=0;i<n;i++)if(polygonShare(shape,panels.get(i).poly)>.055){if(first<0)first=i;else join(parent,first,i);}
  }
  for(Box c:characters)if(c.score>.65&&c.area()<w*h*.55){int first=-1;for(int i=0;i<n;i++)if(polygonShare(Arrays.asList(new Point(c.x,c.y),new Point(c.x+c.w,c.y),new Point(c.x+c.w,c.y+c.h),new Point(c.x,c.y+c.h)),panels.get(i).poly)>.18){if(first<0)first=i;else join(parent,first,i);}}
  // A head followed by wide torso/leg detections touching successive gutters
  // is one intentionally sliced figure, rather than three independent scenes.
  for(int a=0;a<n;a++)for(int b=0;b<n;b++)for(int c=0;c<n;c++)if(a!=b&&b!=c&&a!=c){
   Panel pa=panels.get(a),pb=panels.get(b),pc=panels.get(c);
   if(pa.box.w<w*.65||pb.box.w<w*.65||pc.box.w<w*.65||pa.box.h>h*.23||pb.box.h>h*.18||pc.box.h>h*.18)continue;
   if(pb.box.y<pa.box.y+pa.box.h-h*.035||pb.box.y>pa.box.y+pa.box.h+h*.035||pc.box.y<pb.box.y+pb.box.h-h*.035||pc.box.y>pb.box.y+pb.box.h+h*.035)continue;
   for(Box head:characters)if(head.w<pa.box.w*.5&&head.w>pa.box.w*.15&&overlap(head,pa.box)>head.area()*.8)
    for(Box torso:characters)if(torso.w>pb.box.w*.55&&torso.w/torso.h>3&&overlap(torso,pb.box)>torso.area()*.8&&Math.abs(head.y+head.h-torso.y)<h*.028)
     for(Box leg:characters)if(leg.w>pc.box.w*.55&&leg.w/leg.h>3&&overlap(leg,pc.box)>leg.area()*.8&&Math.abs(torso.y+torso.h-leg.y)<h*.028){join(parent,a,b);join(parent,b,c);}
  }
  for(int i=0;i<n;i++){int count=0;for(int j=0;j<n;j++)if(root(parent,j)==root(parent,i))count++;if(count>1)panels.get(i).artworkGroup=root(parent,i);}
 }

 // Independent rendering mask: retain original non-white stock without changing
 // detection, panel ownership, artwork completion or source colours.
  static String stockColour(Bitmap bitmap,JSONArray tile,double sx,double sy){
   if(tile.length()==4){int x=(int)(tile.optDouble(0)/sx),y=(int)(tile.optDouble(1)/sy),tw=(int)Math.round(tile.optDouble(2)/sx),th=(int)Math.round(tile.optDouble(3)/sy);long rr=0,gg=0,bb=0,nn=0;for(int py=y;py<Math.min(bitmap.getHeight(),y+th);py++)for(int px=x;px<Math.min(bitmap.getWidth(),x+tw);px++){int c=bitmap.getPixel(px,py);rr+=Color.red(c);gg+=Color.green(c);bb+=Color.blue(c);nn++;}if(nn>0)return String.format(java.util.Locale.ROOT,"#%02x%02x%02x",rr/nn,gg/nn,bb/nn);}
   int w=bitmap.getWidth(),h=bitmap.getHeight();long r=0,g=0,b=0,n=0;
   for(int i=0;i<Math.max(w,h);i++)for(int c:new int[]{bitmap.getPixel(i%w,0),bitmap.getPixel(i%w,h-1),bitmap.getPixel(0,i%h),bitmap.getPixel(w-1,i%h)}){r+=Color.red(c);g+=Color.green(c);b+=Color.blue(c);n++;}
   return String.format(java.util.Locale.ROOT,"#%02x%02x%02x",r/n,g/n,b/n);
  }
 static JSONArray stockPaths(Bitmap bitmap,List<Panel> panels,double sx,double sy,JSONArray tile)throws JSONException{
  JSONArray paths=new JSONArray();if(panels.size()<2)return paths;
  int w=bitmap.getWidth(),h=bitmap.getHeight();Mat rgba=new Mat(),rgb=new Mat(),smooth=new Mat();Utils.bitmapToMat(bitmap,rgba);Imgproc.cvtColor(rgba,rgb,Imgproc.COLOR_RGBA2RGB);rgba.release();Imgproc.GaussianBlur(rgb,smooth,new Size(5,5),1.2);rgb.release();rgb=smooth;
  byte[] pixels=new byte[w*h*3];rgb.get(0,0,pixels);int[] histogram=new int[4096];
  for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(x==0||y==0||x==w-1||y==h-1){int k=(y*w+x)*3;histogram[(((pixels[k]&255)>>4)<<8)|(((pixels[k+1]&255)>>4)<<4)|((pixels[k+2]&255)>>4)]++;}
  int best=0;for(int i=1;i<histogram.length;i++)if(histogram[i]>histogram[best])best=i;
  int red=((best>>8)&15)*16+8,green=((best>>4)&15)*16+8,blue=(best&15)*16+8;
  if(Math.min(red,Math.min(green,blue))>=245){rgb.release();return paths;}
  Mat mask=Mat.zeros(h+2,w+2,CvType.CV_8U),inner=mask.submat(1,h+1,1,w+1);
  // Never seed the background through an open frame into a future scene.
  for(Panel panel:panels){MatOfPoint outline=new MatOfPoint();outline.fromList(panel.poly);Imgproc.fillPoly(inner,Collections.singletonList(outline),new Scalar(1));outline.release();}
  int flags=4|Imgproc.FLOODFILL_MASK_ONLY|Imgproc.FLOODFILL_FIXED_RANGE|(255<<8);
  for(int i=0;i<64;i++){int x=(w-1)*i/63,y=(h-1)*i/63;for(Point seed:Arrays.asList(new Point(x,0),new Point(x,h-1),new Point(0,y),new Point(w-1,y))){double[] c=rgb.get((int)seed.y,(int)seed.x);if(Math.abs(c[0]-red)<24&&Math.abs(c[1]-green)<24&&Math.abs(c[2]-blue)<24)Imgproc.floodFill(rgb,mask,seed,new Scalar(0),new org.opencv.core.Rect(),new Scalar(24,24,24),new Scalar(24,24,24),flags);}}
  Mat stock=new Mat();Core.inRange(inner,new Scalar(255),new Scalar(255),stock);
  if(Core.countNonZero(stock)>w*h*.025){
   // Sample only verified paper, never artwork. Repeat its original screentone
   // beneath hidden scenes so their silhouettes are not exposed by flat fills.
   int tileSize=24;boolean found=false;
   for(int y=0;y+tileSize<=h&&!found;y+=8)for(int x=0;x+tileSize<=w&&!found;x+=8){Mat patch=stock.submat(y,y+tileSize,x,x+tileSize);boolean valid=Core.countNonZero(patch)==tileSize*tileSize;patch.release();if(valid){tile.put(x*sx).put(y*sy).put(tileSize*sx).put(tileSize*sy);found=true;}}
   List<MatOfPoint> contours=new ArrayList<>();Mat hierarchy=new Mat();Imgproc.findContours(stock,contours,hierarchy,Imgproc.RETR_LIST,Imgproc.CHAIN_APPROX_SIMPLE);for(MatOfPoint outline:contours){if(outline.total()>=3){JSONArray poly=points(simplified(outline,.35));scalePoints(poly,sx,sy);paths.put(poly);}outline.release();}hierarchy.release();}
  stock.release();inner.release();mask.release();rgb.release();return paths;
 }

 // Neutralize only edge-connected, near-uniform page stock for inference.
 // Source pixels and rendering always retain their original colours.
 static Bitmap neutralBackground(Bitmap bitmap,Mat gray){
  int w=bitmap.getWidth(),h=bitmap.getHeight();
  // Estimate actual RGB page stock, not just luminance. Two colours can have
  // identical luminance while belonging to completely different regions.
  Mat rgba=new Mat(),rgb=new Mat(),smooth=new Mat();Utils.bitmapToMat(bitmap,rgba);Imgproc.cvtColor(rgba,rgb,Imgproc.COLOR_RGBA2RGB);
  // Average print screentone for inference; do not modify the source image.
  Imgproc.GaussianBlur(rgb,smooth,new Size(5,5),1.2);rgb.release();rgb=smooth;
  int[] pixels=new int[w*h],histogram=new int[4096];Bitmap sample=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888);Utils.matToBitmap(rgb,sample);sample.getPixels(pixels,0,w,0,0,w,h);sample.recycle();
  for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(x==0||y==0||x==w-1||y==h-1){int c=pixels[y*w+x];histogram[((Color.red(c)>>4)<<8)|((Color.green(c)>>4)<<4)|(Color.blue(c)>>4)]++;}
  int best=0;for(int i=1;i<histogram.length;i++)if(histogram[i]>histogram[best])best=i;
  int red=((best>>8)&15)*16+8,green=((best>>4)&15)*16+8,blue=(best&15)*16+8;
  // Retain the established black/white paths; supplement coloured page stock.
  if(Math.min(red,Math.min(green,blue))>=235||Math.max(red,Math.max(green,blue))<45){rgba.release();rgb.release();return bitmap;}
  Mat mask=Mat.zeros(h+2,w+2,CvType.CV_8U);int flags=4|Imgproc.FLOODFILL_MASK_ONLY|Imgproc.FLOODFILL_FIXED_RANGE|(255<<8);
  for(int i=0;i<32;i++){int x=(w-1)*i/31,y=(h-1)*i/31;for(Point seed:Arrays.asList(new Point(x,0),new Point(x,h-1),new Point(0,y),new Point(w-1,y))){double[] c=rgb.get((int)seed.y,(int)seed.x);if(Math.abs(c[0]-red)<24&&Math.abs(c[1]-green)<24&&Math.abs(c[2]-blue)<24)Imgproc.floodFill(rgb,mask,seed,new Scalar(0),new org.opencv.core.Rect(),new Scalar(24,24,24),new Scalar(24,24,24),flags);}}
  Mat inner=mask.submat(1,h+1,1,w+1);Bitmap result=bitmap;
  if(Core.countNonZero(inner)>w*h*.025){rgba.setTo(new Scalar(255,255,255,255),inner);result=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888);Utils.matToBitmap(rgba,result);}
  inner.release();mask.release();rgba.release();rgb.release();return result;
 }
 static int borderTone(Mat gray){int w=gray.cols(),h=gray.rows();int[] histogram=new int[256];for(int x=0;x<w;x++){histogram[(int)gray.get(0,x)[0]]++;histogram[(int)gray.get(h-1,x)[0]]++;}for(int y=0;y<h;y++){histogram[(int)gray.get(y,0)[0]]++;histogram[(int)gray.get(y,w-1)[0]]++;}int best=255;for(int i=0;i<256;i++)if(histogram[i]>histogram[best])best=i;return best;}
 static List<Box> removePageProposal(List<Box> boxes,double area){
  List<Box> result=new ArrayList<>();for(Box parent:boxes){int children=0;for(Box child:boxes)if(child!=parent&&child.score>parent.score+.15&&child.area()<parent.area()*.8&&child.area()>area*.05&&overlap(child,parent)/child.area()>.94)children++;
   if(!(parent.score<.7&&parent.area()>area*.65&&children>=2))result.add(parent);
  }return result;
 }
 // Reconcile locally: one architectural scene must not change the decisions
 // for unrelated panels elsewhere on the page. A confident inset found by both
 // detectors remains a real panel, even when enclosed by a larger frame.
 // Two detectors must agree on the narrow axis before restoring a truncated
 // longitudinal extent. The measured gutter still clips the restored container.
 static List<Box> restoreTruncatedProposals(List<Box> proposed,List<Box> reference){
  List<Box> restored=new ArrayList<>();
  for(Box b:proposed){Box chosen=b;double best=0;
   for(Box r:reference){double match=iou(b,r);if(match<.45||match<best)continue;
    boolean vertical=r.h>b.h*1.3&&Math.abs(r.x-b.x)<b.w*.08&&Math.abs(r.w-b.w)<b.w*.12;
    boolean horizontal=r.w>b.w*1.3&&Math.abs(r.y-b.y)<b.h*.08&&Math.abs(r.h-b.h)<b.h*.12;
    if(vertical||horizontal){chosen=new Box(vertical?b.x:r.x,vertical?r.y:b.y,vertical?b.w:r.w,vertical?r.h:b.h,b.score,b.index,b.kind);best=match;}
   }
   // Extending a proposal must not swallow another independently proposed cell.
   for(Box peer:proposed)if(peer!=b&&peer.area()<chosen.area()*.9&&overlap(peer,chosen)/Math.max(1,peer.area())>.8){chosen=b;break;}
   restored.add(chosen);
  }return restored;
 }
 static List<Panel> reconcileScenes(List<Panel> magi,List<Panel> proposed,double area){
  List<Panel> result=new ArrayList<>(proposed);
  for(Panel scene:magi){
   if(scene.box.score<.45||scene.box.area()<area*.3)continue;
   List<Panel> parts=new ArrayList<>();boolean independentlySplit=false;
   for(Panel q:proposed)if(q.box.area()<scene.box.area()*.95&&overlap(q.box,scene.box)/q.box.area()>.92)parts.add(q);
   if(parts.size()==1){
    // A cropped single proposal is not evidence for dropping the rest of a
    // confidently detected scene. Keep that scene intact instead of donating
    // its missing artwork to unrelated earlier panels.
    Panel part=parts.get(0);double share=overlap(part.box,scene.box)/scene.box.area();
    if(share>.45&&share<.78&&scene.box.score>=.5){result.remove(part);result.add(scene);}
    continue;
   }
   if(parts.size()<2)continue;
   for(Panel p:magi)if(p!=scene&&p.box.score>=.5&&p.box.area()<scene.box.area()*.85&&overlap(p.box,scene.box)/p.box.area()>.92)independentlySplit=true;
   if(independentlySplit)continue;
   // Require the proposed pieces collectively to explain most of this scene.
   double covered=0;for(Panel q:parts)covered+=overlap(q.box,scene.box);
   if(covered<scene.box.area()*.6)continue;
   result.removeIf(q->overlap(q.box,scene.box)/Math.max(1,q.box.area())>.92);
   result.add(scene);
  }
  return result;
 }
 // Keep corroborated exterior regions from the second detector: selecting the
 // stronger detector must not discard real narrow cells or unframed dialogue.
 static List<Panel> recoverExteriorRegions(Mat gray,List<Panel> panels,List<Box> proposals,List<Box> texts,List<Box> balloons,List<Frame> frames,boolean dark){
  List<Box> missing=new ArrayList<>();List<Box> candidates=new ArrayList<>(proposals);
  candidates.sort((a,b)->Double.compare(b.area(),a.area()));
  for(Box b:candidates){
   double covered=0;boolean containsScene=false;for(Panel p:panels){covered+=overlap(b,p.box);if(overlap(b,p.box)>p.box.area()*.9)containsScene=true;}
   if(containsScene)continue;
   if(covered>b.area()*.18)continue;
   boolean duplicate=false;for(Box a:missing)if(overlap(a,b)>b.area()*.65)duplicate=true;
   if(duplicate)continue;
   int dialogue=0,balloon=0;for(Box t:texts)if(overlap(t,b)>t.area()*.75)dialogue++;
   for(Box t:balloons)if(overlap(t,b)>t.area()*.7)balloon++;
   boolean measured=false;for(Frame f:frames)if(f.simple&&iou(f.box,b)>.7)measured=true;
   boolean aligned=false;for(Panel p:panels){Box a=p.box;double gap=Math.min(Math.abs(b.x+b.w-a.x),Math.abs(a.x+a.w-b.x));if(gap<gray.cols()*.025&&Math.abs(b.y-a.y)<b.h*.08&&Math.abs(b.h-a.h)<b.h*.12)aligned=true;}
   for(Box a:missing){double gap=Math.min(Math.abs(b.x+b.w-a.x),Math.abs(a.x+a.w-b.x));if(gap<gray.cols()*.025&&Math.abs(b.y-a.y)<b.h*.08&&Math.abs(b.h-a.h)<b.h*.12)aligned=true;}
   if((b.score>.45&&measured)||(b.score>.5&&aligned)||(b.score>.25&&dialogue>=2&&balloon>=1))missing.add(b);
  }
  if(missing.isEmpty())return panels;
  List<Panel> recovered=makePanels(gray,missing,frames,dark);
  for(Panel p:recovered){
   // An unframed dialogue area is a real reading region, certified by both
   // text and balloon evidence rather than an invented rectangular frame.
   if(p.source.equals("detector-container"))p.source="corroborated-exterior-region";
   panels.add(p);
  }
  // Detector padding can overlap between separately corroborated narrow cells.
  // Split only this small padding overlap, leaving ambiguous scenes untouched.
  for(int i=0;i<recovered.size();i++)for(int j=i+1;j<recovered.size();j++){
   Panel a=recovered.get(i),b=recovered.get(j);Box x=a.box,y=b.box;
   double ox=Math.min(x.x+x.w,y.x+y.w)-Math.max(x.x,y.x);
   double oy=Math.min(x.y+x.h,y.y+y.h)-Math.max(x.y,y.y);
   if(oy>Math.min(x.h,y.h)*.7&&ox>-6&&ox<Math.min(x.w,y.w)*.2){
    boolean left=x.x<y.x;double cut=left?(x.x+x.w+y.x)/2:(y.x+y.w+x.x)/2;
    a.poly=clip(a.poly,true,0,cut,left?-1:1);b.poly=clip(b.poly,true,0,cut,left?1:-1);
   }else if(ox>Math.min(x.w,y.w)*.7&&oy>-6&&oy<Math.min(x.h,y.h)*.2){
    boolean top=x.y<y.y;double cut=top?(x.y+x.h+y.y)/2:(y.y+y.h+x.y)/2;
    a.poly=clip(a.poly,false,0,cut,top?-1:1);b.poly=clip(b.poly,false,0,cut,top?1:-1);
   }
  }
  respectClosedNeighbours(panels,gray.cols(),gray.rows());return panels;
 }
 static List<Panel> removeNested(List<Panel> panels,double area){
  List<Panel> out=new ArrayList<>();for(Panel child:panels){boolean nested=false;
   for(Panel parent:panels)if(parent!=child&&parent.box.score>.65&&child.box.score<.5&&parent.box.area()>area*.3&&child.box.area()<parent.box.area()*.4&&overlap(child.box,parent.box)/Math.max(1,child.box.area())>.96)nested=true;
   if(!nested)out.add(child);
  }return out;
 }
 static boolean containsDialogue(List<Point> polygon,Box bubble,List<Box> texts){
  MatOfPoint2f outline=new MatOfPoint2f();outline.fromList(polygon);boolean complete=true;
  for(Box t:texts){if(overlap(t,bubble)/Math.max(1,t.area())<.7)continue;
   // Check all dialogue lines, including text near the top/bottom of a bubble.
   for(int y=0;y<5;y++)for(int x=0;x<5;x++)if(Imgproc.pointPolygonTest(outline,new Point(t.x+t.w*(.08+.84*x/4),t.y+t.h*(.08+.84*y/4)),false)<0)complete=false;
  }outline.release();return complete;
 }
 static boolean safeBubble(List<Point> polygon,Box box,Mat gray){if(polygon.size()<3)return false;Mat mask=Mat.zeros(gray.size(),CvType.CV_8U);MatOfPoint outline=new MatOfPoint();outline.fromList(polygon);Imgproc.fillPoly(mask,Collections.singletonList(outline),new Scalar(255));int ink=0,missing=0,total=0,inside=0;int x0=Math.max(0,(int)(box.x+box.w*.18)),x1=Math.min(gray.cols(),(int)(box.x+box.w*.82)),y0=Math.max(0,(int)(box.y+box.h*.18)),y1=Math.min(gray.rows(),(int)(box.y+box.h*.82));for(int y=y0;y<y1;y++)for(int x=x0;x<x1;x++){boolean covered=mask.get(y,x)[0]>0;total++;if(covered)inside++;if(gray.get(y,x)[0]<160){ink++;if(!covered)missing++;}}mask.release();outline.release();return total>0&&inside>total*.985&&(ink<8||missing<=ink*.005);}
 static List<Panel> makePanels(Mat gray,List<Box> boxes,List<Frame> frames,boolean darkBackground){int w=gray.cols(),h=gray.rows();List<Panel> panels=new ArrayList<>();for(Box b:boxes){Frame best=null;double score=0;for(Frame f:frames){if(!f.simple)continue;double match=iou(b,f.box);if(match>.72&&(best==null||match>score+.08||(match>=score-.08&&f.area>best.area))){best=f;score=match;}}if(best!=null){panels.add(new Panel(b,best.poly,"closed-source-frame"));}else{Box expanded=new Box(Math.max(0,b.x-3),Math.max(0,b.y-3),Math.min(w-b.x+3,b.w+6),Math.min(h-b.y+3,b.h+6),b.score,b.index,b.kind);panels.add(new Panel(b,rectangle(expanded),"detector-container"));}}
   if(darkBackground){Mat inverted=new Mat();Core.bitwise_not(gray,inverted);refineGutters(inverted,panels,true);inverted.release();}else{refineGutters(gray,panels,false);}Mat neutral=new Mat();int bg=borderTone(gray);Core.absdiff(gray,new Scalar(bg),neutral);neutral.convertTo(neutral,-1,-2,255);refineGutters(neutral,panels,false);neutral.release();respectClosedNeighbours(panels,w,h);panels=order(panels,h);return panels;}
 // A gutter estimate must never extend into an adjacent, measured source frame.
 // Only resolve small edge overlaps; nested or genuinely ambiguous scenes still
 // reach the reader's whole-page fallback. Keep the source contour, not its hull.
 static void respectClosedNeighbours(List<Panel> panels,int w,int h){
  for(Panel p:panels){
   if(!p.source.endsWith("source-gutter-polygon")&&!p.source.equals("corroborated-exterior-region"))continue;
   Mat mask=Mat.zeros(h,w,CvType.CV_8U),before=new Mat();
   MatOfPoint original=new MatOfPoint();original.fromList(p.poly);
   Imgproc.fillPoly(mask,Collections.singletonList(original),new Scalar(255));original.release();
   int area=Core.countNonZero(mask);mask.copyTo(before);boolean changed=false;
   for(Panel neighbour:panels){
    if(neighbour==p||!neighbour.source.endsWith("closed-source-frame"))continue;
    Mat other=Mat.zeros(h,w,CvType.CV_8U),intersection=new Mat();MatOfPoint contour=new MatOfPoint();contour.fromList(neighbour.poly);
    Imgproc.fillPoly(other,Collections.singletonList(contour),new Scalar(255));contour.release();Core.bitwise_and(before,other,intersection);
    int overlap=Core.countNonZero(intersection);
    if(overlap>0&&overlap<area*.2){mask.setTo(new Scalar(0),other);changed=true;}
    other.release();intersection.release();
   }
   if(changed&&Core.countNonZero(mask)>area*.7){
    List<MatOfPoint> contours=new ArrayList<>();Mat hierarchy=new Mat();Imgproc.findContours(mask,contours,hierarchy,Imgproc.RETR_EXTERNAL,Imgproc.CHAIN_APPROX_SIMPLE);
    contours.sort((a,b)->Double.compare(Imgproc.contourArea(b),Imgproc.contourArea(a)));
    if(!contours.isEmpty()&&(contours.size()==1||Imgproc.contourArea(contours.get(1))<area*.03))p.poly=simplified(contours.get(0),.4);
    for(MatOfPoint contour:contours)contour.release();hierarchy.release();
   }
   mask.release();before.release();
  }
 }
 static boolean darkBackground(Mat gray){
  int w=gray.cols(),h=gray.rows(),n=0;byte[] pixels=new byte[w*h];gray.get(0,0,pixels);
  for(int side=0;side<4;side++){int count=0,total=0;int thick=Math.max(2,(side<2?w:h)/100);for(int y=0;y<h;y++)for(int x=0;x<w;x++){boolean edge=side==0?x<thick:side==1?x>=w-thick:side==2?y<thick:y>=h-thick;if(edge){total++;if((pixels[y*w+x]&255)<45)count++;}}if(count>total*.85)n++;}
  return n>=2;
 }
 static List<Box> darkCells(Mat gray,List<Box> boxes){
  byte[] pixels=new byte[(int)gray.total()];gray.get(0,0,pixels);int w=gray.cols(),h=gray.rows();
  List<Box> cells=splitDark(pixels,w,h,new Box(0,0,w,h,1,0,2),boxes,0);
  if(cells.size()<2||cells.size()>12)return null;
  for(Box b:boxes){if(b.area()>w*h*.65)continue;double best=0;for(Box c:cells)best=Math.max(best,overlap(b,c)/Math.max(1,b.area()));if(best<.85)return null;}
  // A validated corridor can replace an uninformative full-page detector box.
  return cells.size()>boxes.size()?cells:null;
 }
 static List<Box> splitDark(byte[] pixels,int width,int height,Box bounds,List<Box> boxes,int depth){
  if(depth>=5)return new ArrayList<>(Collections.singletonList(bounds));
  Box[] bestChildren=null;double bestScore=0;
  for(int axis:new int[]{1,0}){
   int length=(int)(axis==1?bounds.h:bounds.w),cross=(int)(axis==1?bounds.w:bounds.h),band=-1;
   for(int offset=0;offset<=length;offset++){
    int dark=0;if(offset<length){for(int t=0;t<cross;t++){int x=(int)bounds.x+(axis==1?t:offset),y=(int)bounds.y+(axis==1?offset:t);if((pixels[y*width+x]&255)<45)dark++;}}
    boolean corridor=offset<length&&dark>=cross*.985;
    if(corridor&&band<0)band=offset;
    if(!corridor&&band>=0){int start=band;band=-1;int thickness=offset-start,local=(start+offset-1)/2;
     if(thickness<Math.max(3,Math.round(length*.004))||Math.min(local,length-local)<Math.max(30,length*.12))continue;
     double cut=(axis==1?bounds.y:bounds.x)+local;boolean crosses=false;
     for(Box b:boxes){if(b.area()>width*height*.65)continue;double origin=axis==1?b.y:b.x,extent=axis==1?b.h:b.w;double otherOverlap=axis==1?Math.min(b.x+b.w,bounds.x+bounds.w)-Math.max(b.x,bounds.x):Math.min(b.y+b.h,bounds.y+bounds.h)-Math.max(b.y,bounds.y);if(otherOverlap>(axis==1?b.w:b.h)*.4&&origin+extent*.12<cut&&cut<origin+extent*.88){crosses=true;break;}}
     if(crosses)continue;
     Box[] children=axis==1?new Box[]{new Box(bounds.x,bounds.y,bounds.w,local,1,0,2),new Box(bounds.x,cut,bounds.w,bounds.h-local,1,0,2)}:new Box[]{new Box(cut,bounds.y,bounds.w-local,bounds.h,1,0,2),new Box(bounds.x,bounds.y,local,bounds.h,1,0,2)};
     boolean valid=true;for(Box child:children){if(child.area()<width*height*.025){valid=false;break;}int light=0;for(int y=(int)child.y;y<child.y+child.h;y++)for(int x=(int)child.x;x<child.x+child.w;x++)if((pixels[y*width+x]&255)>100)light++;if(light<child.area()*.10){valid=false;break;}}
     double score=(double)thickness/length;if(valid&&score>bestScore){bestScore=score;bestChildren=children;}
    }
   }
  }
  if(bestChildren==null)return new ArrayList<>(Collections.singletonList(bounds));
  List<Box> result=new ArrayList<>();for(Box child:bestChildren)result.addAll(splitDark(pixels,width,height,child,boxes,depth+1));return result;
 }
 static void scalePoints(JSONArray a,double sx,double sy)throws JSONException{for(int i=0;i<a.length();i++){JSONArray p=a.getJSONArray(i);p.put(0,p.getDouble(0)*sx);p.put(1,p.getDouble(1)*sy);}}
 static List<Frame> frames(Mat gray){Mat ink=new Mat(),hierarchy=new Mat();Imgproc.threshold(gray,ink,180,255,Imgproc.THRESH_BINARY_INV);List<MatOfPoint> contours=new ArrayList<>();Imgproc.findContours(ink,contours,hierarchy,Imgproc.RETR_LIST,Imgproc.CHAIN_APPROX_SIMPLE);List<Frame> out=new ArrayList<>();for(MatOfPoint c:contours){double area=Imgproc.contourArea(c);if(area>gray.total()*.0005){Box b=bounds(c);double length=perimeter(c);List<Point> coarse=simplified(c,.003*length);boolean simple=area>gray.total()*.008&&coarse.size()>=3&&coarse.size()<=12&&area/b.area()>.55;out.add(new Frame(b,simplified(c,Math.max(.4,.0003*length)),area,simple));}c.release();}ink.release();hierarchy.release();return out;}
 // Source black outlines are measured before any inference-only stock normalization.
 // Keep their actual non-convex contours, including notches and speech-box protrusions.
 static List<Frame> inkFrames(Mat gray){
  Mat ink=new Mat(),hierarchy=new Mat();Imgproc.threshold(gray,ink,80,255,Imgproc.THRESH_BINARY_INV);
  List<MatOfPoint> contours=new ArrayList<>();Imgproc.findContours(ink,contours,hierarchy,Imgproc.RETR_LIST,Imgproc.CHAIN_APPROX_SIMPLE);
  List<Frame> result=new ArrayList<>();for(MatOfPoint c:contours){
   double area=Imgproc.contourArea(c);if(area>gray.total()*.008){
    Box box=bounds(c);double length=perimeter(c);List<Point> coarse=simplified(c,.003*length);
    if(area/box.area()>.65&&coarse.size()>=3&&coarse.size()<=24)result.add(new Frame(box,simplified(c,Math.max(.4,.0003*length)),area,true));
   }c.release();
  }ink.release();hierarchy.release();return result;
 }
 static List<Frame> whiteBalloons(Mat gray){
  Mat light=new Mat(),hierarchy=new Mat();Imgproc.threshold(gray,light,235,255,Imgproc.THRESH_BINARY);Mat kernel=Imgproc.getStructuringElement(Imgproc.MORPH_RECT,new Size(3,3));Imgproc.morphologyEx(light,light,Imgproc.MORPH_CLOSE,kernel);List<MatOfPoint> contours=new ArrayList<>();Imgproc.findContours(light,contours,hierarchy,Imgproc.RETR_EXTERNAL,Imgproc.CHAIN_APPROX_SIMPLE);List<Frame> result=new ArrayList<>();for(MatOfPoint c:contours){double area=Imgproc.contourArea(c);Box b=bounds(c);if(area>100&&area<gray.total()*.15&&b.w>12&&b.h>12&&area/b.area()>.6)result.add(new Frame(b,simplified(c,.6),area,true));c.release();}light.release();hierarchy.release();kernel.release();return result;
 }
 static List<Point> bubbleContour(Box b,Input input,float[] det,float[] proto,List<Frame> frames,int w,int h,Mat gray,List<Box> texts){
  byte[] pixels=new byte[160*160];int x0=Math.max(0,(int)((b.x*input.scale+input.left)/4)),y0=Math.max(0,(int)((b.y*input.scale+input.top)/4)),x1=Math.min(160,(int)Math.ceil(((b.x+b.w)*input.scale+input.left)/4)),y1=Math.min(160,(int)Math.ceil(((b.y+b.h)*input.scale+input.top)/4));
  for(int y=y0;y<y1;y++)for(int x=x0;x<x1;x++){float sum=0;for(int k=0;k<32;k++)sum+=det[(8+k)*8400+b.index]*proto[k*25600+y*160+x];if(sum>0)pixels[y*160+x]=(byte)255;}
  Mat small=new Mat(160,160,CvType.CV_8U);small.put(0,0,pixels);Mat square=new Mat();Imgproc.resize(small,square,new Size(640,640),0,0,Imgproc.INTER_LINEAR);org.opencv.core.Rect valid=new org.opencv.core.Rect(input.left,input.top,Math.min(640-input.left,(int)Math.round(w*input.scale)),Math.min(640-input.top,(int)Math.round(h*input.scale)));Mat roi=square.submat(valid),full=new Mat();Imgproc.resize(roi,full,new Size(w,h),0,0,Imgproc.INTER_LINEAR);Imgproc.threshold(full,full,100,255,Imgproc.THRESH_BINARY);Mat kernel=Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE,new Size(5,5));Imgproc.morphologyEx(full,full,Imgproc.MORPH_CLOSE,kernel);Imgproc.dilate(full,full,kernel);List<MatOfPoint> contours=new ArrayList<>();Mat hierarchy=new Mat();Imgproc.findContours(full,contours,hierarchy,Imgproc.RETR_EXTERNAL,Imgproc.CHAIN_APPROX_SIMPLE);MatOfPoint best=null;double bestArea=0;for(MatOfPoint c:contours){double a=Imgproc.contourArea(c);if(a>bestArea){bestArea=a;best=c;}}List<Point> result=best==null?new ArrayList<>():simplified(best,.65);List<Point> rawContour=new ArrayList<>(result);
  // Prefer a matching closed ink border when available; this restores fine tails
  // and border pixels lost at the 160x160 prototype-mask resolution.
  Frame source=null;double match=0;for(Frame f:frames){double score=iou(b,f.box);if(score>.65&&f.area>bestArea*.65&&f.area<bestArea*1.45&&score>match){source=f;match=score;}}{double expandedArea=Double.MAX_VALUE;for(Frame f:frames){double cover=overlap(b,f.box)/Math.max(1,b.area());if(cover<.60||b.cx()<f.box.x||b.cx()>f.box.x+f.box.w||b.cy()<f.box.y||b.cy()>f.box.y+f.box.h||f.area<bestArea*1.15||f.area>b.area()*4.0||f.area>w*h*.15||f.box.w>b.w*1.5||f.box.h>b.h*2.9)continue;org.opencv.core.Rect rr=new org.opencv.core.Rect((int)f.box.x,(int)f.box.y,Math.min(w-(int)f.box.x,(int)f.box.w),Math.min(h-(int)f.box.y,(int)f.box.h));if(rr.width<=0||rr.height<=0)continue;Mat patch=gray.submat(rr);double light=Core.mean(patch).val[0];patch.release();double score=iou(b,f.box);if(light>210&&f.area<expandedArea){source=f;match=score;expandedArea=f.area;}}}if(source!=null&&containsDialogue(source.poly,b,texts))result=source.poly;boolean sourceValid=source!=null&&result==source.poly;
  for(MatOfPoint c:contours)c.release();small.release();square.release();roi.release();full.release();kernel.release();hierarchy.release();if((!sourceValid&&!safeBubble(result,b,gray))||!containsDialogue(result,b,texts)){result=rawContour;sourceValid=false;}if((!sourceValid&&!safeBubble(result,b,gray))||!containsDialogue(result,b,texts))result=new ArrayList<>();if(result.size()>=3)result=includeOutline(result,w,h);return result;
 }
 static List<Point> includeOutline(List<Point> polygon,int w,int h){
  // Recover the original 1–2px ink outline, without a convex hull or rectangle.
  Mat mask=Mat.zeros(h,w,CvType.CV_8U),hierarchy=new Mat();MatOfPoint outline=new MatOfPoint();outline.fromList(polygon);Imgproc.fillPoly(mask,Collections.singletonList(outline),new Scalar(255));
  Mat kernel=Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE,new Size(5,5));Imgproc.dilate(mask,mask,kernel);
  List<MatOfPoint> contours=new ArrayList<>();Imgproc.findContours(mask,contours,hierarchy,Imgproc.RETR_EXTERNAL,Imgproc.CHAIN_APPROX_SIMPLE);List<Point> result=polygon;double largest=0;
  for(MatOfPoint c:contours){double area=Imgproc.contourArea(c);if(area>largest){largest=area;result=simplified(c,.45);}c.release();}
  mask.release();hierarchy.release();outline.release();kernel.release();return result;
 }
 static List<Panel> order(List<Panel> panels,int height){if(panels.size()<2)return panels;for(int axis:new int[]{1,0}){List<Panel> sorted=new ArrayList<>(panels);final int a=axis;sorted.sort(Comparator.comparingDouble(p->a==1?p.box.y:p.box.x));double best=-Double.MAX_VALUE;int split=-1;for(int i=1;i<sorted.size();i++){double end=-1e9,start=1e9,minSize=1e9;for(int j=0;j<i;j++){Box b=sorted.get(j).box;end=Math.max(end,axis==1?b.y+b.h:b.x+b.w);minSize=Math.min(minSize,axis==1?b.h:b.w);}for(int j=i;j<sorted.size();j++){Box b=sorted.get(j).box;start=Math.min(start,axis==1?b.y:b.x);minSize=Math.min(minSize,axis==1?b.h:b.w);}double gap=start-end;if(gap>=-minSize*.2&&gap>best){best=gap;split=i;}}if(split>0){List<Panel> first=order(new ArrayList<>(sorted.subList(0,split)),height),second=order(new ArrayList<>(sorted.subList(split,sorted.size())),height);if(axis==0){second.addAll(first);return second;}first.addAll(second);return first;}}panels.sort((a,b)->Math.abs(a.box.y-b.box.y)<height*.05?Double.compare(b.box.x,a.box.x):Double.compare(a.box.y,b.box.y));return panels;}
 static List<Point> clip(List<Point> points,boolean vertical,double k,double q,double sign){List<Point> out=new ArrayList<>();for(int i=0;i<points.size();i++){Point p=points.get(i),previous=points.get((i+points.size()-1)%points.size());double dp=sign*(vertical?p.x-k*p.y-q:p.y-k*p.x-q),dq=sign*(vertical?previous.x-k*previous.y-q:previous.y-k*previous.x-q);if((dp>=0)!=(dq>=0)){double t=dq/(dq-dp);out.add(new Point(previous.x+t*(p.x-previous.x),previous.y+t*(p.y-previous.y)));}if(dp>=0)out.add(p);}return out;}
 static void refineGutters(Mat gray,List<Panel> panels,boolean dark){if(panels.size()<2)return;int w=gray.cols(),h=gray.rows();byte[] pixels=new byte[w*h];gray.get(0,0,pixels);Mat edges=new Mat(),lines=new Mat();Imgproc.Canny(gray,edges,80,180);Imgproc.HoughLinesP(edges,lines,1,Math.PI/720,60,Math.min(w,h)*.28,25);for(int i=0;i<panels.size();i++)for(int j=i+1;j<panels.size();j++){Panel pa=panels.get(i),pb=panels.get(j);Box a=pa.box,b=pb.box;boolean vertical=Math.abs(a.cx()-b.cx())/w>Math.abs(a.cy()-b.cy())/h;double start=vertical?Math.max(a.y,b.y):Math.max(a.x,b.x),end=vertical?Math.min(a.y+a.h,b.y+b.h):Math.min(a.x+a.w,b.x+b.w),low=vertical?Math.max(a.x,b.x):Math.max(a.y,b.y),high=vertical?Math.min(a.x+a.w,b.x+b.w):Math.min(a.y+a.h,b.y+b.h),extent=vertical?w:h;if(end-start<(vertical?h:w)*(dark?.15:.23)||high<low-extent*.05)continue;double best=0,bk=0,bq=0;for(int l=0;l<lines.rows();l++){double[] line=lines.get(l,0);double delta=vertical?line[3]-line[1]:line[2]-line[0],cross=vertical?line[2]-line[0]:line[3]-line[1];if(Math.abs(delta)<(end-start)*.65||Math.abs(cross)>Math.abs(delta)*.4)continue;double k=cross/delta,q=vertical?line[0]-k*line[1]:line[1]-k*line[0],middle=k*(start+end)/2+q;if(middle<low-extent*.04||middle>high+extent*.04)continue;for(int offset=-14;offset<=14;offset+=2){int white=0,ink=0;for(int n=0;n<96;n++){double t=start+(end-start)*(.04+.92*n/95),v=k*t+q+offset;int x=(int)Math.round(vertical?v:t),y=(int)Math.round(vertical?t:v);if(sample(pixels,w,h,x,y)>235)white++;if(Math.min(sample(pixels,w,h,x-(vertical?5:0),y-(vertical?0:5)),sample(pixels,w,h,x+(vertical?5:0),y+(vertical?0:5)))<130)ink++;}double score=white/96.0+.4*ink/96.0;if(white>=(dark?68:83)&&ink>=(dark?25:53)&&score>best){best=score;bk=k;bq=q+offset;}}}if(best==0)continue;double da=vertical?a.cx()-bk*a.cy()-bq:a.cy()-bk*a.cx()-bq,db=vertical?b.cx()-bk*b.cy()-bq:b.cy()-bk*b.cx()-bq;if(da*db>=0)continue;Panel[] pair={pa,pb};double[] distances={da,db};for(int n=0;n<2;n++){Panel p=pair[n];if(p.source.endsWith("closed-source-frame"))continue;List<Point> cut=clip(p.poly,vertical,bk,bq,Math.signum(distances[n]));if(cut.size()<3)continue;MatOfPoint contour=new MatOfPoint();contour.fromList(cut);double area=Imgproc.contourArea(contour);contour.release();if(area>p.box.area()*.35){p.poly=cut;p.source="source-gutter-polygon";}}}edges.release();lines.release();}
 static int sample(byte[] p,int w,int h,int x,int y){return p[Math.max(0,Math.min(h-1,y))*w+Math.max(0,Math.min(w-1,x))]&255;}

 // Open or full-bleed frames need not form a closed rectangle. Require an
 // actual paper band with source ink on both sides, rather than box spacing.
 static void certifyOpenGutters(Mat gray,List<Panel> panels){
  int w=gray.cols(),h=gray.rows();byte[] pixels=new byte[w*h];gray.get(0,0,pixels);
  boolean[] verified=new boolean[panels.size()];
  for(int i=0;i<panels.size();i++)for(int j=i+1;j<panels.size();j++){
   Box a=panels.get(i).box,b=panels.get(j).box;
   if(a.score<.8||b.score<.8)continue;
   boolean vertical=Math.abs(a.cx()-b.cx())/w>Math.abs(a.cy()-b.cy())/h;
   Box first=(vertical?a.cx()<b.cx():a.cy()<b.cy())?a:b,second=first==a?b:a;
   double low=vertical?first.x+first.w:first.y+first.h,high=vertical?second.x:second.y;
   double start=vertical?Math.max(a.y,b.y):Math.max(a.x,b.x),end=vertical?Math.min(a.y+a.h,b.y+b.h):Math.min(a.x+a.w,b.x+b.w);
   int extent=vertical?w:h;
   if(high-low<3||high-low>extent*.12||end-start<(vertical?h:w)*.6)continue;
   int consecutive=0;boolean band=false;
   for(int c=(int)Math.ceil(low);c<high;c++){
    int paper=0,before=0,after=0;
    for(int n=0;n<128;n++){
     int t=(int)(start+(end-start)*(.02+.96*n/127));
     int x=vertical?c:t,y=vertical?t:c;
     if(sample(pixels,w,h,x,y)>240)paper++;
     for(int d=4;d<=Math.max(6,extent*.025);d+=3){
      if(sample(pixels,w,h,x-(vertical?d:0),y-(vertical?0:d))<170){before++;break;}
     }
     for(int d=4;d<=Math.max(6,extent*.025);d+=3){
      if(sample(pixels,w,h,x+(vertical?d:0),y+(vertical?0:d))<170){after++;break;}
     }
    }
    consecutive=paper>=112&&before>=20&&after>=20?consecutive+1:0;
    if(consecutive>=3){band=true;break;}
   }
   if(band){verified[i]=true;verified[j]=true;}
  }
  for(int i=0;i<panels.size();i++)if(verified[i]&&panels.get(i).source.endsWith("detector-container"))panels.get(i).source="measured-open-source-gutter";
 }

 // Retain original ink outside inferred polygons: frame strokes, disconnected
 // sound effects and limbs crossing gutters. Only foreground receives an
 // owner; uniform page stock must never become a rectangular reveal.
 static double segmentDistance(Point p,Point a,Point b){double dx=b.x-a.x,dy=b.y-a.y,t=Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/Math.max(1,dx*dx+dy*dy)));return Math.hypot(p.x-a.x-t*dx,p.y-a.y-t*dy);}
 // Frame completion may fill unowned pixels, never steal an established neighbour.
 static void ownFrameStrokes(Mat gray,List<Panel> panels,short[] owner){
  int w=gray.cols(),h=gray.rows();Mat edges=new Mat(),lines=new Mat();Imgproc.Canny(gray,edges,50,140);Imgproc.HoughLinesP(edges,lines,1,Math.PI/720,80,w*.22,12);
  for(int k=0;k<lines.rows();k++){double[] line=lines.get(k,0);Point a=new Point(line[0],line[1]),b=new Point(line[2],line[3]);double best=10;int selected=-1;
   for(int i=0;i<panels.size();i++){List<Point> poly=panels.get(i).poly;double distance=0;for(Point sample:new Point[]{a,b,new Point((a.x+b.x)/2,(a.y+b.y)/2)}){double nearest=Double.MAX_VALUE;for(int j=0;j<poly.size();j++)nearest=Math.min(nearest,segmentDistance(sample,poly.get(j),poly.get((j+1)%poly.size())));distance=Math.max(distance,nearest);}if(panels.get(i).source.endsWith("closed-source-frame"))distance-=.5;if(distance<best){best=distance;selected=i;}}
   if(selected>=0){int steps=(int)Math.ceil(Math.hypot(a.x-b.x,a.y-b.y));for(int t=0;t<=steps;t++){int x=(int)Math.round(a.x+(b.x-a.x)*t/steps),y=(int)Math.round(a.y+(b.y-a.y)*t/steps);for(int yy=Math.max(0,y-2);yy<=Math.min(h-1,y+2);yy++)for(int xx=Math.max(0,x-2);xx<=Math.min(w-1,x+2);xx++)if(owner[yy*w+xx]<0)owner[yy*w+xx]=(short)selected;}}
  }edges.release();lines.release();
 }
 static void completeForeground(Mat gray,short[] owner){
  int w=gray.cols(),h=gray.rows(),count=w*h;
  Mat foreground=new Mat();
  if(darkBackground(gray))Imgproc.threshold(gray,foreground,15,255,Imgproc.THRESH_BINARY);
  else Imgproc.threshold(gray,foreground,245,255,Imgproc.THRESH_BINARY_INV);
  Mat kernel=Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE,new Size(3,3));
  Imgproc.dilate(foreground,foreground,kernel);
  byte[] ink=new byte[count];foreground.get(0,0,ink);foreground.release();kernel.release();
  short[] nearest=owner.clone();int[] distance=new int[count];int[] queue=new int[count];int head=0,tail=0;
  // Seed the boundary only. Interior pixels already have an owner.
  for(int k=0;k<count;k++)if(owner[k]>=0){
   int x=k%w;
   if((x>0&&owner[k-1]<0)||(x+1<w&&owner[k+1]<0)||(k>=w&&owner[k-w]<0)||(k+w<count&&owner[k+w]<0))queue[tail++]=k;
  }
  while(head<tail){
   int k=queue[head++],x=k%w;
   for(int n:new int[]{x>0?k-1:-1,x+1<w?k+1:-1,k>=w?k-w:-1,k+w<count?k+w:-1})if(n>=0&&nearest[n]<0){nearest[n]=nearest[k];distance[n]=distance[k]+1;queue[tail++]=n;}
  }
  // Keep each unowned ink component intact. A frame stroke must not be
  // split across nearest-panel cells and appear before its own scene.
  boolean[] visited=new boolean[count];
  for(int start=0;start<count;start++)if(owner[start]<0&&ink[start]!=0&&!visited[start]){
   head=0;tail=0;queue[tail++]=start;visited[start]=true;
   int[] contact=new int[64],fallback=new int[64];int furthest=0;
   while(head<tail){int k=queue[head++],x=k%w;
    furthest=Math.max(furthest,distance[k]);if(nearest[k]>=0&&nearest[k]<64)fallback[nearest[k]]++;
    for(int n:new int[]{x>0?k-1:-1,x+1<w?k+1:-1,k>=w?k-w:-1,k+w<count?k+w:-1})if(n>=0){
     if(owner[n]>=0&&owner[n]<64)contact[owner[n]]++;
     else if(ink[n]!=0&&!visited[n]){visited[n]=true;queue[tail++]=n;}
    }
   }
   // Proximity alone is not evidence that an exterior scene belongs to a
   // revealed panel. Complete only local ink fragments; distant scene-sized
   // components stay hidden until their own panel (or the full-page step).
   // Validated balloons and unframed scenes have already been reserved.
   if(tail>count*.04||furthest>Math.max(12,w*.045))continue;
   int best=0;for(int i=1;i<64;i++)if(contact[i]>contact[best])best=i;
   if(contact[best]==0)for(int i=1;i<64;i++)if(fallback[i]>fallback[best])best=i;
   if(contact[best]>0||fallback[best]>0)for(int i=0;i<tail;i++)owner[queue[i]]=(short)best;
  }
 }
 // An unframed character can belong to a small neighbouring narration scene.
 // Reserve that scene's exterior artwork before the generic nearest-frame fill;
 // otherwise a thought balloon touching the preceding frame is revealed early.
 static void ownUnframedScenes(Mat gray,List<Panel> panels,List<Box> characters,List<Box> texts,short[] owner){
  int w=gray.cols(),h=gray.rows();List<Box> free=new ArrayList<>();List<Integer> destinations=new ArrayList<>();
  for(Box character:characters){
   if(character.score<.75)continue;
   double contained=0;for(Panel p:panels)contained=Math.max(contained,overlap(character,p.box)/character.area());
   if(contained>.15)continue;
   int selected=-1;double best=Double.MAX_VALUE;
   for(int i=0;i<panels.size();i++){
    Box p=panels.get(i).box;
    double vertical=Math.max(0,Math.min(character.y+character.h,p.y+p.h)-Math.max(character.y,p.y));
    double gap=Math.max(0,Math.max(p.x-character.x-character.w,character.x-p.x-p.w));
    if(vertical<character.h*.15||gap>w*.12||p.area()>w*h*.09)continue;
    double distance=Math.hypot(character.cx()-p.cx(),character.cy()-p.cy());
    if(distance<best){best=distance;selected=i;}
   }
   if(selected>=0){free.add(character);destinations.add(selected);}
  }
  if(free.isEmpty())return;
  // Close only small interruptions in an ink outline. These contours are
  // ownership evidence, never replacement pixels or new panel boundaries.
  Mat ink=new Mat(),hierarchy=new Mat();Imgproc.threshold(gray,ink,180,255,Imgproc.THRESH_BINARY_INV);
  int size=Math.max(5,((int)Math.round(w*.015))|1);
  Mat kernel=Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE,new Size(size,size));
  Imgproc.morphologyEx(ink,ink,Imgproc.MORPH_CLOSE,kernel);
  List<MatOfPoint> contours=new ArrayList<>();Imgproc.findContours(ink,contours,hierarchy,Imgproc.RETR_LIST,Imgproc.CHAIN_APPROX_SIMPLE);
  for(int f=0;f<free.size();f++){
   Box character=free.get(f);int destination=destinations.get(f);
   Mat region=Mat.zeros(h,w,CvType.CV_8U);
   Imgproc.rectangle(region,new Point(Math.max(0,character.x-4),Math.max(0,character.y-4)),new Point(Math.min(w-1,character.x+character.w+4),Math.min(h-1,character.y+character.h+4)),new Scalar(255),-1);
   for(MatOfPoint contour:contours){
    double area=Imgproc.contourArea(contour);Box b=bounds(contour);
    if(area<w*h*.002||area>w*h*.12||area/b.area()<.45)continue;
    double contained=0;for(Panel p:panels)contained=Math.max(contained,overlap(b,p.box)/b.area());
    if(contained>.15)continue;
    double dx=Math.max(0,Math.max(b.x-character.x-character.w,character.x-b.x-b.w));
    double dy=Math.max(0,Math.max(b.y-character.y-character.h,character.y-b.y-b.h));
    if(Math.hypot(dx,dy)>Math.min(w,h)*.12)continue;
    MatOfPoint2f polygon=new MatOfPoint2f(contour.toArray());boolean dialogue=false;
    for(Box text:texts)if(Imgproc.pointPolygonTest(polygon,new Point(text.cx(),text.cy()),false)>=0){dialogue=true;break;}
    polygon.release();if(!dialogue)continue;
    Imgproc.fillPoly(region,Collections.singletonList(contour),new Scalar(255));
    Imgproc.polylines(region,Collections.singletonList(contour),true,new Scalar(255),size+2);
   }
   byte[] pixels=new byte[w*h];region.get(0,0,pixels);
   for(int k=0;k<owner.length;k++)if(pixels[k]!=0){
    boolean exterior=owner[k]<0;
    if(!exterior){Box frame=panels.get(owner[k]).box;int x=k%w,y=k/w;exterior=x<frame.x-4||x>frame.x+frame.w+4||y<frame.y-4||y>frame.y+frame.h+4;}
    if(exterior)owner[k]=(short)destination;
   }
   region.release();
  }
  for(MatOfPoint contour:contours)contour.release();ink.release();hierarchy.release();kernel.release();
 }
 // Partition the paper into complete reading regions at row/column gutters.
 // Existing source polygons, balloons and reserved unframed scenes win; these
 // expanded cells assign only the remaining pixels, never steal a neighbour.
 static void partitionRegions(List<Panel> all,List<Integer> ids,int left,int top,int right,int bottom,short[] regions,int width){
  if(ids.size()==1){short id=ids.get(0).shortValue();for(int y=top;y<bottom;y++)Arrays.fill(regions,y*width+left,y*width+right,id);return;}
  for(int axis:new int[]{1,0}){
   List<Integer> sorted=new ArrayList<>(ids);final int a=axis;sorted.sort(Comparator.comparingDouble(i->a==1?all.get(i).box.y:all.get(i).box.x));
   double best=-Double.MAX_VALUE,cut=0;int split=-1;
   for(int i=1;i<sorted.size();i++){
    double end=-1e9,start=1e9,small=1e9;
    for(int j=0;j<sorted.size();j++){Box b=all.get(sorted.get(j)).box;double origin=axis==1?b.y:b.x,size=axis==1?b.h:b.w;small=Math.min(small,size);if(j<i)end=Math.max(end,origin+size);else start=Math.min(start,origin);}
    if(start-end>=-small*.2&&start-end>best){best=start-end;cut=(start+end)/2;split=i;}
   }
   if(split>0){int boundary=(int)Math.round(cut);boundary=Math.max((axis==1?top:left)+1,Math.min((axis==1?bottom:right)-1,boundary));
    partitionRegions(all,new ArrayList<>(sorted.subList(0,split)),left,top,axis==0?boundary:right,axis==1?boundary:bottom,regions,width);
    partitionRegions(all,new ArrayList<>(sorted.subList(split,sorted.size())),axis==0?boundary:left,axis==1?boundary:top,right,bottom,regions,width);return;
   }
  }
  // Diagonal/interlocking frames have no straight full-width gutter. Their
  // measured polygons already own their interiors; use closest source edge
  // only for the residual exterior area in this branch.
  List<MatOfPoint2f> outlines=new ArrayList<>();for(int id:ids){MatOfPoint2f p=new MatOfPoint2f();p.fromList(all.get(id).poly);outlines.add(p);}
  for(int y=top;y<bottom;y++)for(int x=left;x<right;x++){double best=-Double.MAX_VALUE;int selected=ids.get(0);for(int i=0;i<ids.size();i++){double d=Imgproc.pointPolygonTest(outlines.get(i),new Point(x,y),true);if(d>best){best=d;selected=ids.get(i);}}regions[y*width+x]=(short)selected;}
  for(MatOfPoint2f p:outlines)p.release();
 }
 static void completeRegions(Mat gray,List<Panel> panels,short[] owner){
  int w=gray.cols(),h=gray.rows();short[] regions=new short[w*h];List<Integer> ids=new ArrayList<>();for(int i=0;i<panels.size();i++)ids.add(i);
  partitionRegions(panels,ids,0,0,w,h,regions,w);
  byte[] pixels=new byte[w*h];gray.get(0,0,pixels);
  // Include the whole source region, including its white balloon interiors.
  // Neutral paper outside the artwork can remain transparent: stock is drawn
  // separately, before any reading step, with its original texture and colour.
  int x0=w,y0=h,x1=0,y1=0;
  boolean dark=darkBackground(gray);
  for(int k=0;k<pixels.length;k++)if(dark?(pixels[k]&255)>15:(pixels[k]&255)<245){int x=k%w,y=k/w;x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);}
  for(int y=Math.max(0,y0-3);y<Math.min(h,y1+4);y++)for(int x=Math.max(0,x0-3);x<Math.min(w,x1+4);x++){int k=y*w+x;if(owner[k]<0)owner[k]=regions[k];}
 }
 // Export pixel-cell boundaries, rather than contours through pixel centres.
 // This preserves the exact ownership mask without dilating into neighbours
 // or cutting the outer half of a source stroke. Holes keep their own loops.
 static void regionPaths(Panel panel,short[] owner,int id,int w,int h)throws JSONException{
  int stride=w+1;Map<Integer,ArrayDeque<Integer>> edges=new HashMap<>();
  for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(owner[y*w+x]==id){
   int a=y*stride+x,b=a+1,c=b+stride,d=a+stride;
   if(y==0||owner[(y-1)*w+x]!=id)edges.computeIfAbsent(a,k->new ArrayDeque<>()).add(b);
   if(x==w-1||owner[y*w+x+1]!=id)edges.computeIfAbsent(b,k->new ArrayDeque<>()).add(c);
   if(y==h-1||owner[(y+1)*w+x]!=id)edges.computeIfAbsent(c,k->new ArrayDeque<>()).add(d);
   if(x==0||owner[y*w+x-1]!=id)edges.computeIfAbsent(d,k->new ArrayDeque<>()).add(a);
  }
  while(!edges.isEmpty()){
   int start=edges.keySet().iterator().next(),at=start;List<Integer> loop=new ArrayList<>();
   do{loop.add(at);ArrayDeque<Integer> next=edges.get(at);if(next==null)throw new IllegalStateException("Open ownership boundary");int end=next.removeFirst();if(next.isEmpty())edges.remove(at);at=end;}while(at!=start);
   JSONArray path=new JSONArray();int n=loop.size();
   for(int i=0;i<n;i++){int prev=loop.get((i+n-1)%n),p=loop.get(i),next=loop.get((i+1)%n);if((prev%stride==p%stride&&p%stride==next%stride)||(prev/stride==p/stride&&p/stride==next/stride))continue;path.put(new JSONArray().put(p%stride).put(p/stride));}
   if(path.length()>=3)panel.paths.put(path);
  }
 }
 static void coverage(Mat gray,List<Panel> panels)throws JSONException{coverage(gray,panels,Collections.emptyList(),Collections.emptyList());}
 static void coverage(Mat gray,List<Panel> panels,List<Box> characters,List<Box> texts)throws JSONException{if(panels.isEmpty())return;int w=gray.cols(),h=gray.rows();short[] owner=new short[w*h];Arrays.fill(owner,(short)-1);for(short i=0;i<panels.size();i++){Panel p=panels.get(i);Mat seed=Mat.zeros(h,w,CvType.CV_8U);MatOfPoint poly=new MatOfPoint();poly.fromList(p.poly);Imgproc.fillPoly(seed,Collections.singletonList(poly),new Scalar(255));if(p.source.endsWith("closed-source-frame"))Imgproc.polylines(seed,Collections.singletonList(poly),true,new Scalar(255),6);byte[] inside=new byte[w*h];seed.get(0,0,inside);for(int k=0;k<owner.length;k++){if(owner[k]<0&&inside[k]!=0)owner[k]=i;}seed.release();poly.release();}/* Balloon contours are assigned before completing source foreground. */for(short i=0;i<panels.size();i++){Panel panel=panels.get(i);for(int bi=0;bi<panel.bubbles.length();bi++){JSONArray points=panel.bubbles.getJSONObject(bi).getJSONArray("polygon");Point[] xy=new Point[points.length()];for(int n=0;n<xy.length;n++)xy[n]=new Point(points.getJSONArray(n).getDouble(0),points.getJSONArray(n).getDouble(1));MatOfPoint outline=new MatOfPoint(xy);Mat mask=Mat.zeros(h,w,CvType.CV_8U);Imgproc.fillPoly(mask,Collections.singletonList(outline),new Scalar(255));Imgproc.polylines(mask,Collections.singletonList(outline),true,new Scalar(255),4);byte[] pixels=new byte[w*h];mask.get(0,0,pixels);for(int k=0;k<owner.length;k++)if(pixels[k]!=0)owner[k]=i;mask.release();outline.release();}}
ownFrameStrokes(gray,panels,owner);ownUnframedScenes(gray,panels,characters,texts,owner);completeForeground(gray,owner);completeRegions(gray,panels,owner);
for(int i=0;i<panels.size();i++)regionPaths(panels.get(i),owner,i,w,h);}
}




