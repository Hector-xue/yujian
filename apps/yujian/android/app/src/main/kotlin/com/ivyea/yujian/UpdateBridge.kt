package com.ivyea.yujian

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import java.io.File
import java.security.MessageDigest

/** 应用内更新：算下载包的 SHA-256（和 version.json 对账）、报这台手机能不能装 64 位包、把 apk 交给系统安装器。 */
object UpdateBridge {
    private const val CHANNEL = "yujian/update"

    fun register(ctx: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    val f = if (path != null) File(path) else null
                    if (f == null || !f.exists()) { result.error("missing", "apk not found", null); return@setMethodCallHandler }
                    try {
                        val uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".fileprovider", f)
                        val i = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        ctx.startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install", e.message, null)
                    }
                }
                "sha256" -> {
                    val path = call.argument<String>("path")
                    val f = if (path != null) File(path) else null
                    if (f == null || !f.exists()) { result.error("missing", "file not found", null); return@setMethodCallHandler }
                    Thread {
                        try {
                            val md = MessageDigest.getInstance("SHA-256")
                            f.inputStream().use { input ->
                                val buf = ByteArray(1 shl 16)
                                while (true) {
                                    val n = input.read(buf)
                                    if (n <= 0) break
                                    md.update(buf, 0, n)
                                }
                            }
                            val hex = md.digest().joinToString("") { "%02x".format(it) }
                            android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(hex) }
                        } catch (e: Exception) {
                            android.os.Handler(android.os.Looper.getMainLooper()).post { result.error("sha256", e.message, null) }
                        }
                    }.start()
                }
                // 32 位手机（armeabi-v7a）装不了 arm64 包：让 Dart 侧选对的那个
                "is64Bit" -> result.success(Build.SUPPORTED_64_BIT_ABIS.isNotEmpty())
                else -> result.notImplemented()
            }
        }
    }
}
