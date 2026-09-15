package com.ivyea.yujian

import android.content.Context
import android.content.Intent
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
                "drain" -> result.success(YujianNotificationListener.drain(ctx))
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
