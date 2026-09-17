package com.ivyea.yujian

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 系统分享进余见：文字 → 对话；图片 → 截图识别。启动时和运行中新 intent 都走这里。 */
object ShareBridge {
    private const val CHANNEL = "yujian/share"
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null

    fun register(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialShare" -> { result.success(pending); pending = null }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun handle(activity: MainActivity, intent: Intent?) {
        if (intent == null) return
        // 内部跳转（快捷方式 / 小部件）：yujian://chat 这类，交给 Flutter 切页
        if (intent.action == Intent.ACTION_VIEW && intent.data?.scheme == "yujian") {
            val route = intent.data?.host ?: return
            deliver(mapOf("kind" to "route", "text" to route))
            return
        }
        if (intent.action != Intent.ACTION_SEND) return
        val type = intent.type ?: return
        val payload: Map<String, Any?>? = when {
            type.startsWith("text/") -> intent.getStringExtra(Intent.EXTRA_TEXT)?.let { mapOf("kind" to "text", "text" to it) }
            type.startsWith("image/") -> {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return
                val bytes = activity.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return
                mapOf("kind" to "image", "mime" to type, "bytes" to bytes)
            }
            else -> null
        } ?: return
        deliver(payload)
    }

    private fun deliver(payload: Map<String, Any?>) {
        val ch = channel
        if (ch != null) ch.invokeMethod("onShare", payload) else pending = payload
    }
}
