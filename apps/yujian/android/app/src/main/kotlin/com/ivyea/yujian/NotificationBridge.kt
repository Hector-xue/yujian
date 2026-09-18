package com.ivyea.yujian

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Flutter ↔ 通知监听的桥：方法通道查状态/开设置/取队列，事件通道直推。 */
object NotificationBridge {
    private const val METHODS = "yujian/notifications"
    private const val EVENTS = "yujian/notifications/stream"
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    fun register(ctx: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(YujianNotificationListener.isEnabled(ctx))
                "openSettings" -> {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(intent)
                    result.success(null)
                }
                // 应用信息页：小米/HyperOS 等对「未知来源」App 拒绝敏感权限，要在这页右上角「允许受限设置」
                "openAppInfo" -> {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(intent)
                    result.success(null)
                }
                "drain" -> result.success(YujianNotificationListener.drain(ctx))
                // 支付页识别（无障碍）
                "isScreenEnabled" -> result.success(PaymentScreenService.isEnabled(ctx))
                "setScreenWanted" -> {
                    PaymentScreenService.setWanted(ctx, call.arguments as? Boolean ?: false)
                    result.success(null)
                }
                "screenDiagnostics" -> result.success(PaymentScreenService.diagnostics(ctx))
                "clearScreenLog" -> {
                    PaymentScreenService.clearLog(ctx)
                    result.success(null)
                }
                "openAccessibilitySettings" -> {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, events: EventChannel.EventSink?) { sink = events }
            override fun onCancel(args: Any?) { sink = null }
        })
    }

    fun push(json: String) {
        val s = sink ?: return
        main.post { s.success(json) }
    }
}
