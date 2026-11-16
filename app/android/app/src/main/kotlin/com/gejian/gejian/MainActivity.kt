package com.gejian.gejian
import android.content.Intent
import android.app.Dialog
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebResourceRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONTokener
import java.io.File
import java.util.concurrent.Executors
class MainActivity : FlutterActivity() {
 private val worker=Executors.newSingleThreadExecutor()
 @Volatile private var inferenceEpoch=0
 private var picker:MethodChannel.Result?=null
 private val views=mutableListOf<WebView>()
 private lateinit var detector:ComicEngine
 override fun configureFlutterEngine(engine:FlutterEngine){
  super.configureFlutterEngine(engine);detector=ComicEngine(this)
  MethodChannel(engine.dartExecutor.binaryMessenger,"gejian/native").setMethodCallHandler { call,result ->
   when(call.method){
    "systemProxy" -> {val manager=getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager;val proxy=manager.defaultProxy;result.success(if(proxy!=null&&proxy.host!=null&&proxy.port>0) "${proxy.host}:${proxy.port}" else null)}
    "mdCookies" -> result.success(android.webkit.CookieManager.getInstance().getCookie("https://api.mangadex.org")?:"")
    "directory" -> result.success(File(filesDir,"library").absolutePath)
    "awake" -> {if(call.arguments==true)window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);result.success(null)}
    "warmup" -> worker.execute {try {detector.warmup();runOnUiThread{result.success(null)}}catch(e:Throwable){runOnUiThread{result.error("INFERENCE",e.message,null)}}}
    "recognize" -> {if(call.argument<Boolean>("background")!=true)inferenceEpoch++;val epoch=inferenceEpoch;worker.execute {if(epoch!=inferenceEpoch){runOnUiThread{result.error("CANCELLED","识别请求已被新页面替代",null)}}else{try {val data=detector.recognize(call.argument<String>("path")!!);runOnUiThread{result.success(data)}} catch(e:Throwable){runOnUiThread{result.error("INFERENCE",e.message,null)}}}}}

    "pick" -> {if(picker!=null){result.error("BUSY","文件选择器已打开",null)}else{picker=result;startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"),71)}}
    "copy" -> copyPage(call.argument<String>("route")!!,call.argument<String>("kind")!!,call.argument<String>("html"),result)
    "mdJson" -> mdPage(call.argument<String>("url")!!,result)
    else -> result.notImplemented()
   }
  }
 }
 private fun mdPage(url:String,result:MethodChannel.Result){
  android.util.Log.d("GejianMD","Loading verification URL: "+url)
  val uri=Uri.parse(url);if(uri.scheme!="https"||uri.host!="api.mangadex.org"){result.error("SOURCE","无效的书源地址",null);return}
  val dialog=Dialog(this);val web=WebView(this);views.add(web)
  web.settings.javaScriptEnabled=true;web.settings.domStorageEnabled=true;web.settings.allowFileAccess=false;web.settings.allowContentAccess=false
  web.settings.userAgentString="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  val container=android.widget.LinearLayout(this);container.orientation=android.widget.LinearLayout.VERTICAL
  val status=android.widget.TextView(this);status.text="MangaDex 书源验证 · 返回可取消";status.setPadding(24,24,24,24);container.addView(status)
  val progress=android.widget.ProgressBar(this);container.addView(progress,android.widget.LinearLayout.LayoutParams(-1,48))
  container.addView(web,android.widget.LinearLayout.LayoutParams(-1,0,1f));dialog.setContentView(container)
  val handler=Handler(Looper.getMainLooper());val deadline=System.currentTimeMillis()+60000;var done=false
  fun finish(value:String?,error:String?){if(done)return;done=true;dialog.setOnCancelListener(null);dialog.dismiss();web.stopLoading();(web.parent as? android.view.ViewGroup)?.removeView(web);web.destroy();views.remove(web);if(error!=null)result.error("SOURCE",error,null)else result.success(value)}
  dialog.setOnCancelListener{finish(null,"已取消验证。你可以切换书源或再次点击验证，不会丢失阅读数据。")}
  web.webViewClient=object:WebViewClient(){
   override fun shouldOverrideUrlLoading(v:WebView,r:WebResourceRequest):Boolean= r.url.scheme!="https" && r.url.scheme!="about"
   override fun onPageFinished(v:WebView,u:String){android.util.Log.d("GejianMD","Finished: "+u);progress.visibility=android.view.View.GONE;status.text="MangaDex 书源验证 · 按网页提示操作，返回可取消"}
   override fun onReceivedError(v:WebView,r:WebResourceRequest,e:android.webkit.WebResourceError){if(r.isForMainFrame)finish(null,"验证页面无法加载：${e.description}。请检查网络或稍后重试。")}
  }
  val poll=object:Runnable{override fun run(){if(done)return;if(System.currentTimeMillis()>deadline){finish(null,"MangaDex 验证超时，请切换网络或书源后重试。");return};web.evaluateJavascript("document.body ? document.body.innerText : ''"){raw->try{val body=JSONTokener(raw).nextValue().toString();if(body.trimStart().startsWith("{")){org.json.JSONObject(body);finish(body,null);return@evaluateJavascript}}catch(e:Exception){};handler.postDelayed(this,400)}}}
  dialog.show();dialog.window?.setLayout(-1,-1);web.loadUrl(url);handler.postDelayed(poll,600)
 }
 @Deprecated("Android compatibility callback") override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?){super.onActivityResult(requestCode,resultCode,data);if(requestCode!=71)return;val result=picker?:return;picker=null;val uri=data?.data;if(resultCode!=RESULT_OK||uri==null){result.success(null);return};worker.execute{try{var name="漫画图片";contentResolver.query(uri,null,null,null,null)?.use{if(it.moveToFirst()){val col=it.getColumnIndex(OpenableColumns.DISPLAY_NAME);if(col>=0)name=it.getString(col)}};val file=File(cacheDir,"import-${System.currentTimeMillis()}");contentResolver.openInputStream(uri)!!.use{input->file.outputStream().use{out->input.copyTo(out)}};runOnUiThread{result.success(mapOf("name" to name,"path" to file.absolutePath))}}catch(e:Exception){runOnUiThread{result.error("IMPORT",e.message,null)}}}}
 private fun copyPage(route:String,kind:String,html:String?,result:MethodChannel.Result){
  if(!Regex("/comic/[a-zA-Z0-9_-]+(/chapter/[a-f0-9-]{36})?").matches(route)){result.error("PATH","书源路径无效",null);return}
  val web=WebView(this);views.add(web);web.settings.javaScriptEnabled=true;web.settings.domStorageEnabled=true;web.settings.allowFileAccess=false;web.settings.allowContentAccess=false;web.alpha=0f;web.importantForAccessibility=android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS;(window.decorView as android.view.ViewGroup).addView(web,android.view.ViewGroup.LayoutParams(1,1));web.onResume()
  web.settings.userAgentString="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  val handler=Handler(Looper.getMainLooper());val deadline=System.currentTimeMillis()+60000;var done=false;var stable=0;var last=""
  fun finish(value:String?,error:String?){if(done)return;done=true;web.stopLoading();(web.parent as? android.view.ViewGroup)?.removeView(web);web.destroy();views.remove(web);if(error!=null)result.error("SOURCE",error,null) else result.success(value)}
  web.webViewClient=object:WebViewClient(){override fun shouldOverrideUrlLoading(v:WebView,r:WebResourceRequest):Boolean = r.url.host!="www.mangacopy.com" || (r.isForMainFrame && r.url.path!=route)}
  val expression=if(kind=="detail") "JSON.stringify([...document.querySelectorAll('a[href*=\"/chapter/\"]')].filter(a=>!a.classList.contains('btn')).map(a=>({id:a.href.split('/').pop(),title:a.textContent.trim()})))" else "JSON.stringify((()=>{for(let n=0;n<500;n++)if(typeof window.onscroll==='function')window.onscroll();let a=[...document.querySelectorAll('.comicContent-list img')].map(i=>i.getAttribute('data-src')||i.src);return a.length===Number(document.querySelector('.comicCount')?.textContent)?a:[]})())"
  val poll=object:Runnable{override fun run(){if(done)return;if(System.currentTimeMillis()>deadline){finish(null,"拷贝漫画页面读取超时，来源可能暂时不可用或需要验证");return};web.evaluateJavascript(expression){value->try{val decoded=JSONTokener(value).nextValue().toString();val array=JSONArray(decoded);stable=if(decoded==last)stable+1 else 0;last=decoded;if(array.length()>0&&stable>=3){finish(decoded,null)}else{handler.postDelayed(this,350)}}catch(e:Exception){handler.postDelayed(this,350)}}}}
  if(html!=null)web.loadDataWithBaseURL("https://www.mangacopy.com$route",html,"text/html","UTF-8",null) else web.loadUrl("https://www.mangacopy.com$route");handler.postDelayed(poll,900)
 }
 override fun onDestroy(){for(v in views.toList())v.destroy();views.clear();worker.shutdown();super.onDestroy()}
}






