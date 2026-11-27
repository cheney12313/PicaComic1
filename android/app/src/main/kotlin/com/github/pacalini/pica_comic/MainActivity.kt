package com.github.pacalini.pica_comic

import android.os.Build
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.Manifest
import androidx.core.content.ContextCompat
import com.google.android.gms.common.GoogleApiAvailability
import java.io.File
import java.io.FileOutputStream

class MainActivity: FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false

    // 导入备份：自己起 SAF 选择器并复制到缓存，复制阶段要回传字节进度。
    // 这里只能有一个进行中的选择，重复调用直接拒绝。
    private var pendingPick: MethodChannel.Result? = null
    private var pickChannel: MethodChannel? = null

    companion object {
        private const val REQ_PICK_BACKUP = 4101
        private const val COPY_BUFFER = 256 * 1024
        private const val PROGRESS_INTERVAL_MS = 100L
    }


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        val channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.github.pacalini.pica_comic/volume")
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    listening = true
                    volumeListen.whenUp = {
                        events.success(1)
                    }
                    volumeListen.whenDown = {
                        events.success(2)
                    }
                }
                override fun onCancel(arguments: Any?) {
                    listening = false
                }
        })
        //拦截屏幕截图
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/screenshot").setMethodCallHandler{
                _, _ ->
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/secure").setMethodCallHandler{
                _, _ ->
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        }
        //获取cpu架构
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/device").setMethodCallHandler{
                _, res ->
            res.success(getDeviceInfo())
        }
        //获取http代理
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/proxy").setMethodCallHandler{
                _, res ->
            res.success(getProxy())
        }
        //保持屏幕常亮
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/keepScreenOn").setMethodCallHandler{
                call, _ ->
            if(call.method == "set")
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pica_comic/playServer").setMethodCallHandler{
                _, res ->
            val flag = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(this) == com.google.android.gms.common.ConnectionResult.SUCCESS
            res.success(flag)
        }

        // 导入备份：选完文件后由我们自己复制到缓存，复制过程按字节回传进度。
        // flutter_file_dialog 把复制藏在插件里，13GB 的备份要静默几十秒。
        val filePickChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pica_comic/filePick")
        filePickChannel.setMethodCallHandler { call, res ->
            when (call.method) {
                "pickAndCopy" -> {
                    if (pendingPick != null) {
                        res.error("busy", "file picker already running", null)
                        return@setMethodCallHandler
                    }
                    pendingPick = res
                    pickChannel = filePickChannel
                    // 上一次导入留下的缓存副本先清掉，避免占满空间
                    cleanupImportCache()
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    try {
                        startActivityForResult(intent, REQ_PICK_BACKUP)
                    } catch (e: Exception) {
                        pendingPick = null
                        res.error("no_picker", e.message ?: e.toString(), null)
                    }
                }
                else -> res.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pica_comic/settings").setMethodCallHandler{                call, res ->
            if(call.method == "link") {
                val intent = Intent(
                    android.provider.Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS,
                    Uri.parse("package:com.github.pacalini.pica_comic"),
                )
                startActivity(intent)
                res.success(null)
            } else if(call.method == "files") {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                } else {
                    Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                }
                intent.data = Uri.parse("package:com.github.pacalini.pica_comic")
                startActivity(intent)
                res.success(null)
            } else if(call.method == "files_check") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    res.success(Environment.isExternalStorageManager())
                } else {
                    res.success(
                        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                            && ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
                }
            }

        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_BACKUP) {
            val res = pendingPick
            pendingPick = null
            if (res == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                res.success(null)
                return
            }
            copyPickedFile(uri, res, pickChannel)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /// 后台线程分块复制，每 100ms 回传一次已复制字节数。
    /// URI 的 size 拿不到时回传 total = 0，Dart 侧按"不确定进度"处理。
    private fun copyPickedFile(uri: Uri, res: MethodChannel.Result, channel: MethodChannel?) {
        Thread {
            val target = File(cacheDir, "import_${System.currentTimeMillis()}.picadata")
            try {
                val total = querySize(uri)
                var done = 0L
                var lastReport = 0L
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("无法读取所选文件")
                input.use { source ->
                    FileOutputStream(target).use { sink ->
                        val buffer = ByteArray(COPY_BUFFER)
                        while (true) {
                            val read = source.read(buffer)
                            if (read <= 0) break
                            sink.write(buffer, 0, read)
                            done += read
                            val now = System.currentTimeMillis()
                            if (now - lastReport >= PROGRESS_INTERVAL_MS) {
                                lastReport = now
                                reportCopyProgress(channel, done, if (total < 0) 0L else total)
                            }
                        }
                    }
                }
                reportCopyProgress(channel, done, if (total < 0) done else maxOf(total, done))
                runOnUiThread { res.success(target.absolutePath) }
            } catch (e: Exception) {
                target.delete()
                runOnUiThread { res.error("copy_failed", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun reportCopyProgress(channel: MethodChannel?, done: Long, total: Long) {
        if (channel == null) return
        runOnUiThread {
            channel.invokeMethod("progress", mapOf("done" to done, "total" to total))
        }
    }

    private fun querySize(uri: Uri): Long {
        try {
            contentResolver.query(
                uri, arrayOf(android.provider.OpenableColumns.SIZE), null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) {
                    return cursor.getLong(0)
                }
            }
        } catch (_: Exception) {
            // 有些 provider 不支持查询，退化成不确定进度
        }
        return -1L
    }

    /// 清掉上次导入留下的缓存副本（可能是 GB 级）。
    private fun cleanupImportCache() {
        try {
            cacheDir.listFiles()?.forEach { file ->
                if (file.name.startsWith("import_") && file.name.endsWith(".picadata")) {
                    file.delete()
                }
            }
        } catch (_: Exception) {
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if(listening){
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeListen.down()
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeListen.up()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun getDeviceInfo(): String{
        //获取cpu架构从而找到应当下载的app版本
        return Build.SUPPORTED_ABIS[0]
    }

    private fun getProxy(): String{
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if(host!=null&&port!=null){
            "$host:$port"
        }else{
            "No Proxy"
        }
    }
}

class VolumeListen{
    var whenUp = fun() {}
    var whenDown = fun() {}
    fun up(){
        whenUp()
    }
    fun down(){
        whenDown()
    }
}
