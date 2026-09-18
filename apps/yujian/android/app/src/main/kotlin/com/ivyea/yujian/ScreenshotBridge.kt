package com.ivyea.yujian

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Flutter ↔ 截图自动记账。
 * 前台引擎在（Dart 侧订阅了事件通道）就直推；没有就拉一个无头引擎跑 `screenshotBackground` 入口把队列处理掉——
 * 这样通知监听 / 无障碍把进程留着的时候，用户不开 App 截图也能静默记。
 */
object ScreenshotBridge {
    private const val METHODS = "yujian/screenshots"
    private const val EVENTS = "yujian/screenshots/stream"
    private const val PERMISSION_REQ = 0x5c11
    private const val ENTRYPOINT = "screenshotBackground"
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var headless: FlutterEngine? = null
    private var headlessSince = 0L

    /** [activity] 为 null 是无头引擎：不能申请权限，其余一样。 */
    fun register(ctx: Context, engine: FlutterEngine, activity: Activity?) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(mapOf(
                    "permitted" to ScreenshotWatcher.isPermitted(ctx),
                    "partial" to ScreenshotWatcher.isPartial(ctx),
                    "wanted" to ScreenshotWatcher.isWanted(ctx),
                ))
                "requestPermission" -> {
                    if (activity == null) { result.success(false); return@setMethodCallHandler }
                    if (ScreenshotWatcher.isPermitted(ctx)) { result.success(true); return@setMethodCallHandler }
                    pendingPermission?.success(false)
                    pendingPermission = result
                    ActivityCompat.requestPermissions(activity, arrayOf(ScreenshotWatcher.permission()), PERMISSION_REQ)
                }
                "setWanted" -> {
                    ScreenshotWatcher.setWanted(ctx, call.arguments as? Boolean ?: false)
                    result.success(null)
                }
                "drain" -> result.success(ScreenshotWatcher.drain(ctx))
                "catchUp" -> result.success(ScreenshotWatcher.catchUp(ctx, (call.arguments as? Number)?.toLong() ?: 0L))
                "readImage" -> {
                    val uri = call.arguments as? String
                    if (uri == null) { result.error("bad_args", "uri required", null); return@setMethodCallHandler }
                    Thread { val b = ScreenshotWatcher.readJpeg(ctx, uri); main.post { result.success(b) } }.start()
                }
                "diagnostics" -> result.success(ScreenshotWatcher.diagnostics(ctx))
                "log" -> {
                    val m = call.arguments as? Map<*, *>
                    val j = org.json.JSONObject()
                    m?.forEach { (k, v) -> j.put(k.toString(), v) }
                    ScreenshotWatcher.log(ctx, j)
                    result.success(null)
                }
                // 无头引擎处理完队列后调这个，原生把引擎销毁
                "backgroundDone" -> {
                    result.success(null)
                    if (activity == null) main.post { destroyHeadless() }
                }
                else -> result.notImplemented()
            }
        }
        if (activity != null) {
            EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(args: Any?) { sink = null }
            })
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQ) return false
        val ok = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(ok)
        pendingPermission = null
        return true
    }

    /** 队列里有新截图：前台引擎在就叫它 drain；不在就起无头引擎。 */
    fun onNewScreenshots(ctx: Context) {
        val s = sink
        if (s != null) {
            main.post { s.success("new") }
            return
        }
        main.post { startHeadless(ctx.applicationContext) }
    }

    private fun startHeadless(ctx: Context) {
        val existing = headless
        if (existing != null) {
            // 一个还在跑就不再起；跑超过 3 分钟当挂了，销毁重来
            if (System.currentTimeMillis() - headlessSince < 3 * 60 * 1000L) return
            destroyHeadless()
        }
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            if (!loader.initialized()) {
                loader.startInitialization(ctx)
                loader.ensureInitializationComplete(ctx, null)
            }
            val engine = FlutterEngine(ctx)
            GeneratedPluginRegistrant.registerWith(engine)
            register(ctx, engine, null)
            WidgetBridge.register(ctx, engine)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT))
            headless = engine
            headlessSince = System.currentTimeMillis()
            ScreenshotWatcher.log(ctx, org.json.JSONObject().put("what", "headless_started"))
        } catch (e: Exception) {
            ScreenshotWatcher.log(ctx, org.json.JSONObject().put("what", "headless_failed").put("err", e.toString()))
        }
    }

    private fun destroyHeadless() {
        headless?.destroy()
        headless = null
    }
}
