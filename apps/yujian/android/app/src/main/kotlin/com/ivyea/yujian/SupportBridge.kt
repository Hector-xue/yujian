package com.ivyea.yujian

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 「支持余见」页：把二维码 PNG 存进系统相册（Pictures/余见），微信扫一扫从相册里选。
 * Android 10+ 走 MediaStore，不需要任何存储权限；更老的系统写公共目录要 WRITE_EXTERNAL_STORAGE，
 * 为了 1 块钱不值得多要一个权限——直接返回 false，Dart 侧改提示「截图保存」。
 */
object SupportBridge {
    private const val TAG = "SupportBridge"
    private const val CHANNEL = "yujian/support"

    fun register(ctx: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name") ?: "yujian.png"
                    if (bytes == null || bytes.isEmpty()) {
                        result.error("bad_args", "bytes required", null)
                        return@setMethodCallHandler
                    }
                    result.success(saveImage(ctx, bytes, name))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveImage(ctx: Context, bytes: ByteArray, name: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val resolver = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/余见")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = try {
            resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        } catch (e: Exception) {
            Log.w(TAG, "insert failed", e)
            null
        } ?: return false
        return try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IllegalStateException("no stream")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            true
        } catch (e: Exception) {
            Log.w(TAG, "write failed", e)
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            false
        }
    }
}
