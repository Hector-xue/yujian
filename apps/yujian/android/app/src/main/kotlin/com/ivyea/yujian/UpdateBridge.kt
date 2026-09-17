package com.ivyea.yujian

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** 应用内更新的最后一步：把下载好的 apk 交给系统安装器。 */
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
                else -> result.notImplemented()
            }
        }
    }
}
