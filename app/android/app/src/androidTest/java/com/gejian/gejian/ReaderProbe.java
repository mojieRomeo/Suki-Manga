package com.gejian.gejian;
import android.app.Instrumentation;
import android.app.Activity;
import android.os.Bundle;
import java.io.*;
import org.json.*;
import org.opencv.android.OpenCVLoader;
import org.opencv.core.*;
import org.opencv.imgproc.Imgproc;
import java.util.*;

public class ReaderProbe extends Instrumentation {
 static int pathOwner(JSONArray panels,int x,int y)throws JSONException{
  int owner=-1;
  for(int i=0;i<panels.length();i++){
   JSONArray paths=panels.getJSONObject(i).getJSONArray("paths");
   boolean covered=false;
   for(int j=0;j<paths.length();j++){
    JSONArray path=paths.getJSONArray(j);Point[] xy=new Point[path.length()];
    for(int n=0;n<xy.length;n++)xy[n]=new Point(path.getJSONArray(n).getDouble(0),path.getJSONArray(n).getDouble(1));
    MatOfPoint2f polygon=new MatOfPoint2f(xy);boolean inside=Imgproc.pointPolygonTest(polygon,new Point(x,y),false)>=0;polygon.release();
    if(inside)covered=!covered;
   }
   if(covered)owner=i;
  }
  return owner;
 }
 static void linkedFixtures(String name,JSONObject data)throws JSONException{
  JSONArray p=data.getJSONArray("panels");
  if(name.equals("shounin-28.jpg")){
   if(p.length()!=5)throw new AssertionError("Exterior dialogue must become a reading region");
   if(pathOwner(p,700,170)!=0||pathOwner(p,600,320)!=0)throw new AssertionError("Both exterior balloons belong to the top-right region");
   if(pathOwner(p,490,200)!=1)throw new AssertionError("Exterior dialogue must not steal the adjacent source frame");
   if(pathOwner(p,750,600)!=2||pathOwner(p,180,600)!=3||pathOwner(p,450,950)!=4)throw new AssertionError("Middle and lower regions keep reading order");
  }
  if(name.equals("yuusha-21.jpg")){
   if(p.length()!=8)throw new AssertionError("Both narrow top cells and lower hand cell must have steps");
   if(pathOwner(p,220,120)!=1||pathOwner(p,120,120)!=2)throw new AssertionError("Narrow top cells must appear before the middle and lower layers");
  }
  if(name.equals("rezero-12.jpg")){
   if(p.length()!=2)throw new AssertionError("Keep the two independent diagonal scenes");
   for(int[] point:new int[][]{{60,220},{312,1090}})if(pathOwner(p,point[0],point[1])!=1)throw new AssertionError("Door artwork and its slanted frame must wait for the left scene: "+Arrays.toString(point));
   if(pathOwner(p,600,600)!=0)throw new AssertionError("Right action scene must appear first");
  }
  if(name.equals("rezero-10.jpg")){
   if(p.length()!=3)throw new AssertionError("Keep the two top cells and continuous bottom scene");
   if(pathOwner(p,50,520)!=2)throw new AssertionError("Bottom narration must not leak into the top scenes");
  }
  if(name.equals("thought-10.jpg")){
   if(p.length()!=5)throw new AssertionError("Keep the existing five reading steps");
   for(int i=0;i<5;i++)if(p.getJSONObject(i).getInt("artworkGroup")>=0)throw new AssertionError("Independent right and left bottom scenes must stay separate");
   for(int[] point:new int[][]{{450,826},{304,925},{280,1150}})if(pathOwner(p,point[0],point[1])!=4)throw new AssertionError("Unframed thought and character must belong to the left scene: "+Arrays.toString(point));
   if(pathOwner(p,700,1000)!=3)throw new AssertionError("Right bottom scene must still appear before left content");
  }
  if(name.equals("mushoku-15.jpg")){
   if(p.length()!=5||p.getJSONObject(2).getInt("artworkGroup")<0||p.getJSONObject(2).getInt("artworkGroup")!=p.getJSONObject(3).getInt("artworkGroup")||p.getJSONObject(3).getInt("artworkGroup")!=p.getJSONObject(4).getInt("artworkGroup")||p.getJSONObject(0).getInt("artworkGroup")>=0||p.getJSONObject(1).getInt("artworkGroup")>=0)throw new AssertionError("Split body must reveal its last three panels together, preserving the first two steps");
  }
  if(name.equals("mushoku-91-05.jpg")){
   if(p.length()!=6)throw new AssertionError("Shared balloon page must preserve six source panels");
   for(int i:new int[]{0,2})if(p.getJSONObject(i).getInt("artworkGroup")<0||p.getJSONObject(i).getInt("artworkGroup")!=p.getJSONObject(i+1).getInt("artworkGroup"))throw new AssertionError("A balloon spanning two panels must link both scenes");
  }
  if(name.equals("opm-07.jpg"))for(int i=0;i<p.length();i++)if(p.getJSONObject(i).getInt("artworkGroup")>=0)throw new AssertionError("Independent aligned strips must remain separate steps");
 }
 private String fixtureFilter;
 @Override public void onCreate(Bundle arguments){super.onCreate(arguments);fixtureFilter=arguments.getString("fixtures");start();}
 @Override public void onStart(){Bundle status=new Bundle();try{
  OpenCVLoader.initLocal();
  ComicEngine.Panel gutter=new ComicEngine.Panel(new ComicEngine.Box(20,20,300,400,.9,0,0),ComicEngine.rectangle(new ComicEngine.Box(20,20,300,400,.9,0,0)),"source-gutter-polygon");
  ComicEngine.Panel neighbour=new ComicEngine.Panel(new ComicEngine.Box(280,20,350,400,.9,0,0),ComicEngine.rectangle(new ComicEngine.Box(280,20,350,400,.9,0,0)),"closed-source-frame");
  ComicEngine.respectClosedNeighbours(Arrays.asList(gutter,neighbour),700,500);
  MatOfPoint2f trimmed=new MatOfPoint2f();trimmed.fromList(gutter.poly);
  if(Imgproc.pointPolygonTest(trimmed,new Point(300,200),false)>=0||Imgproc.pointPolygonTest(trimmed,new Point(200,200),false)<0)throw new AssertionError("Gutter must respect a measured neighbour without losing its own scene");trimmed.release();
  Mat bubbleTest=new Mat(300,300,CvType.CV_8U,new Scalar(255));
  Imgproc.putText(bubbleTest,"HELLO",new Point(80,150),Imgproc.FONT_HERSHEY_SIMPLEX,.8,new Scalar(0),2);
  ComicEngine.Box bubbleBox=new ComicEngine.Box(50,50,200,200,1,0,0);
  List<Point> intact=ComicEngine.rectangle(bubbleBox);
  List<Point> torn=Arrays.asList(new Point(50,50),new Point(250,50),new Point(250,250),new Point(160,250),new Point(160,100),new Point(110,100),new Point(110,250),new Point(50,250));
  if(!ComicEngine.safeBubble(intact,bubbleBox,bubbleTest)||ComicEngine.safeBubble(torn,bubbleBox,bubbleTest))throw new AssertionError("Torn masks must be rejected while intact text stays visible");bubbleTest.release();
  ComicEngine.Panel enclosing=new ComicEngine.Panel(new ComicEngine.Box(10,10,680,980,1,0,0),ComicEngine.rectangle(new ComicEngine.Box(10,10,680,980,1,0,0)),"closed-source-frame");
  ComicEngine.Panel window=new ComicEngine.Panel(new ComicEngine.Box(20,20,150,350,.35,0,0),ComicEngine.rectangle(new ComicEngine.Box(20,20,150,350,.35,0,0)),"detector-container");
  if(ComicEngine.removeNested(Arrays.asList(enclosing,window),700000).size()!=1)throw new AssertionError("Nested window should stay part of its enclosing scene");
  ComicEngine.Panel inset=new ComicEngine.Panel(new ComicEngine.Box(20,20,150,350,.95,0,0),ComicEngine.rectangle(new ComicEngine.Box(20,20,150,350,.95,0,0)),"closed-source-frame");
  if(ComicEngine.removeNested(Arrays.asList(enclosing,inset),700000).size()!=2)throw new AssertionError("Confident inset panel must survive enclosing scene filtering");
  List<ComicEngine.Panel> orderCheck=new ArrayList<>();
  for(int[] rect:new int[][]{{20,500,660,400},{20,20,300,400},{380,20,300,400}}){MatOfPoint poly=new MatOfPoint(new Point(rect[0],rect[1]),new Point(rect[0]+rect[2],rect[1]),new Point(rect[0]+rect[2],rect[1]+rect[3]),new Point(rect[0],rect[1]+rect[3]));orderCheck.add(new ComicEngine.Panel(ComicEngine.bounds(poly),poly.toList(),"test"));}
  orderCheck=ComicEngine.order(orderCheck,1000);
  if(orderCheck.get(0).box.x<300||orderCheck.get(1).box.y>100||orderCheck.get(2).box.y<400)throw new AssertionError("Reading order must be top right, top left, then bottom");
  Mat gray=new Mat(1000,700,CvType.CV_8U,new Scalar(255));
  MatOfPoint top=new MatOfPoint(new Point(20,20),new Point(680,20),new Point(680,340),new Point(20,440));
  MatOfPoint bottom=new MatOfPoint(new Point(20,470),new Point(680,370),new Point(680,980),new Point(20,980));
  Imgproc.polylines(gray,Arrays.asList(top,bottom),true,new Scalar(0),4);
  List<ComicEngine.Frame> frames=ComicEngine.frames(gray);boolean slanted=frames.stream().anyMatch(f->f.simple&&f.poly.size()>=4&&f.area>100000);if(!slanted)throw new AssertionError("Slanted source frames were lost");
  List<ComicEngine.Panel> panels=new ArrayList<>();for(MatOfPoint p:Arrays.asList(top,bottom)){ComicEngine.Box b=ComicEngine.bounds(p);panels.add(new ComicEngine.Panel(b,p.toList(),"closed-source-frame"));}ComicEngine.coverage(gray,panels);if(panels.stream().anyMatch(p->p.paths.length()==0))throw new AssertionError("Missing visible paths");gray.release();top.release();bottom.release();
  JSONArray records=new JSONArray(),failures=new JSONArray();ComicEngine engine=new ComicEngine(getTargetContext());
  for(String name:getContext().getAssets().list("fixtures")){if(fixtureFilter!=null&&!Arrays.asList(fixtureFilter.split(",")).contains(name))continue;File f=new File(getTargetContext().getFilesDir(),"qa-"+name);try(InputStream in=getContext().getAssets().open("fixtures/"+name);OutputStream out=new FileOutputStream(f)){byte[] buf=new byte[65536];int n;while((n=in.read(buf))>0)out.write(buf,0,n);}String result=engine.recognize(f.getAbsolutePath());JSONObject data=new JSONObject(result);try(FileWriter debug=new FileWriter(new File(getTargetContext().getFilesDir(),"qa-"+name+".json"))){debug.write(result);}linkedFixtures(name,data);if(name.equals("reported-original-gray.jpg")){JSONArray paths=data.getJSONArray("panels").getJSONObject(0).getJSONArray("paths");for(int pi=0;pi<paths.length();pi++){JSONArray outline=paths.getJSONArray(pi);Point[] xy=new Point[outline.length()];for(int n=0;n<xy.length;n++)xy[n]=new Point(outline.getJSONArray(n).getDouble(0),outline.getJSONArray(n).getDouble(1));MatOfPoint2f shape=new MatOfPoint2f(xy);boolean leaked=Imgproc.pointPolygonTest(shape,new Point(20,20),false)>=0;shape.release();if(leaked)throw new AssertionError("Unrevealed gray paper must not leak into the first panel");}}if((name.equals("yuusha-05.jpg")||name.startsWith("reported-")&&!name.contains("window")&&!name.contains("bubbles"))&&data.getJSONArray("stockPaths").length()==0)failures.put("Missing non-white page stock: "+name);data.put("fixture",name);records.put(data);try(FileWriter out=new FileWriter(new File(getTargetContext().getFilesDir(),"qa-"+name+".json"))){out.write(result);}try(FileWriter out=new FileWriter(new File(getTargetContext().getFilesDir(),"native-progress.json"))){out.write(new JSONObject().put("results",records).toString());}if(name.equals("reported-original-window.jpg")&&data.getJSONArray("panels").length()!=2)failures.put("Full window page must have two scenes, without splitting windows");if(name.equals("reported-window.png")&&data.getJSONArray("panels").length()!=1)failures.put("The reported window scene must remain one panel");if((Arrays.asList("reported-gray.png","reported-pink.png","reported-blue.png","reported-green.png","reported-yellow.png","reported-darkpurple.png","reported-black.png").contains(name)||name.equals("reported-original-gray.jpg"))&&data.getJSONArray("panels").length()!=3)failures.put("Non-white background must preserve three real panels: "+name);if((name.startsWith("isekai-")||name.equals("real-page.jpg"))&&data.getJSONArray("panels").length()!=4)failures.put("Existing four-panel layout regressed: "+name);if(name.equals("mushoku-live.jpg")&&data.getJSONArray("panels").length()!=6)failures.put("Existing six-panel layout regressed");if(name.equals("user-slanted.png")&&data.getJSONArray("panels").length()!=2)failures.put("Slanted layout regressed");if(name.equals("blank.png")&&data.getJSONArray("panels").length()!=0)failures.put("Blank page should show original");}
  File report=new File(getTargetContext().getFilesDir(),"native-test.json");try(FileWriter out=new FileWriter(report)){out.write(new JSONObject().put("passed",failures.length()==0).put("failures",failures).put("slantedGeometry",true).put("results",records).toString());}
  if(failures.length()>0)throw new AssertionError(failures.toString());
  status.putString("stream","Native inference, reading order and slanted geometry passed\n");finish(Activity.RESULT_OK,status);
 }catch(Throwable e){status.putString("stream",android.util.Log.getStackTraceString(e));finish(Activity.RESULT_CANCELED,status);}}
}
