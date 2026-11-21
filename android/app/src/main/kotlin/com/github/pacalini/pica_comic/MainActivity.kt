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

class MainActivity: FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false


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

        // Read battery / network state / status bar height for the reader's self-drawn status bar.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pica_comic/battery").setMethodCallHandler{
                call, res ->
            if (call.method == "status") {
                val bm = getSystemService(BATTERY_SERVICE) as android.os.BatteryManager
                val level = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
                val charging = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) bm.isCharging else false
                val cm = getSystemService(CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
                val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                val wifi = caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true
                var cellular = caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) == true
                var label = ""
                try {
                    val tm = getSystemService(TELEPHONY_SERVICE) as android.telephony.TelephonyManager
                    // 系统状态栏只要插卡就一直显示信号，不看当前数据走的是 wifi 还是流量
                    if (tm.simState == android.telephony.TelephonyManager.SIM_STATE_READY) {
                        cellular = true
                    }
                    label = when (tm.dataNetworkType) {
                        android.telephony.TelephonyManager.NETWORK_TYPE_NR -> "5G"
                        android.telephony.TelephonyManager.NETWORK_TYPE_LTE -> "4G"
                        android.telephony.TelephonyManager.NETWORK_TYPE_UMTS,
                        android.telephony.TelephonyManager.NETWORK_TYPE_HSPA,
                        android.telephony.TelephonyManager.NETWORK_TYPE_HSDPA,
                        android.telephony.TelephonyManager.NETWORK_TYPE_HSPAP -> "3G"
                        android.telephony.TelephonyManager.NETWORK_TYPE_EDGE,
                        android.telephony.TelephonyManager.NETWORK_TYPE_GPRS -> "2G"
                        else -> ""
                    }
                } catch (_: Exception) {
                    // 没有 READ_PHONE_STATE 权限时拿不到网络制式，留空
                }
                val resId = resources.getIdentifier("status_bar_height", "dimen", "android")
                val px = if (resId > 0) resources.getDimensionPixelSize(resId) else 0
                res.success(mapOf(
                    "level" to level, "charging" to charging, "wifi" to wifi,
                    "cellular" to cellular, "label" to label, "heightPx" to px))
                return@setMethodCallHandler
            }
            if (call.method == "statusBarHeight") {
                val resId = resources.getIdentifier("status_bar_height", "dimen", "android")
                val px = if (resId > 0) resources.getDimensionPixelSize(resId) else 0
                res.success(mapOf("px" to px))
                return@setMethodCallHandler
            }
            val bm = getSystemService(BATTERY_SERVICE) as android.os.BatteryManager
            val level = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
            val charging = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) bm.isCharging else false
            res.success(mapOf("level" to level, "charging" to charging))
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
