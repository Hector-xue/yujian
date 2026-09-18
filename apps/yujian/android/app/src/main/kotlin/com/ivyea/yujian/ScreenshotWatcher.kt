package com.ivyea.yujian

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * 截图自动记账的原生半边：盯着相册（MediaStore）里新出现的截图，攒进队列，交给 Dart 侧（前台引擎或后台无头引擎）用视觉模型判断是不是交易。
 * 只在用户打开开关且授予了相册读权限后工作；进程活着（App 在前后台、或通知监听 / 无障碍服务把进程留着）观察者就在。
 * 进程被杀期间的截图，App 下次打开时 [catchUp] 按时间补扫。
 */
object ScreenshotWatcher {
    private const val PREFS = "yujian_screenshots"
    private const val KEY_WANTED = "wanted"
    private const val KEY_QUEUE = "queue"
    private const val KEY_HANDLED = "handled" // 最近处理过的 MediaStore id，避免观察者与补扫重复
    private const val KEY_LOG = "log"
    private const val QUEUE_CAP = 20
    private const val HANDLED_CAP = 80
    private const val LOG_CAP = 30
    private const val DEBOUNCE_MS = 1200L // 一张截图会触发好几次 onChange（插入、写完、更新元数据），合并到最后一次
    private const val RECENT_WINDOW_S = 30L
    private const val MAX_SIDE = 1280

    private val main = Handler(Looper.getMainLooper())
    private var observer: ContentObserver? = null
    private var appCtx: Context? = null
    private val scanRunnable = Runnable { appCtx?.let { scan(it, "observer") } }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isWanted(ctx: Context) = prefs(ctx).getBoolean(KEY_WANTED, false)
    fun setWanted(ctx: Context, v: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_WANTED, v).apply()
        if (v) ensureStarted(ctx) else stop()
    }

    /** 相册读权限：13+ 是 READ_MEDIA_IMAGES，以下是 READ_EXTERNAL_STORAGE。 */
    fun permission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE

    fun isPermitted(ctx: Context) = ContextCompat.checkSelfPermission(ctx, permission()) == PackageManager.PERMISSION_GRANTED

    /** Android 14 的「只允许部分照片」：拿不到全量，新截图看不见，得让用户改成全部允许。 */
    fun isPartial(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && !isPermitted(ctx) &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED

    /** 开关开着且有权限就挂观察者；重复调用无副作用。各常驻组件（Activity / 通知监听 / 无障碍）起来时都调一下。 */
    @Synchronized
    fun ensureStarted(ctx: Context) {
        val app = ctx.applicationContext
        appCtx = app
        if (!isWanted(app) || !isPermitted(app)) return
        if (observer != null) return
        val obs = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                main.removeCallbacks(scanRunnable)
                main.postDelayed(scanRunnable, DEBOUNCE_MS)
            }
        }
        app.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, obs)
        observer = obs
        log(app, JSONObject().put("what", "observer_started"))
    }

    @Synchronized
    fun stop() {
        val obs = observer ?: return
        appCtx?.contentResolver?.unregisterContentObserver(obs)
        observer = null
    }

    /** 观察者触发：查最近 30 秒内新增的图，路径 / 文件名带 screenshot 的才算截图。 */
    private fun scan(ctx: Context, why: String) {
        val since = System.currentTimeMillis() / 1000 - RECENT_WINDOW_S
        val found = query(ctx, since, 5)
        var n = 0
        for (item in found) if (enqueue(ctx, item)) n++
        if (n > 0) {
            log(ctx, JSONObject().put("what", "found").put("n", n).put("why", why))
            ScreenshotBridge.onNewScreenshots(ctx)
        }
    }

    /** App 打开时补扫：[sinceMs] 之后新增的截图（最多 24 小时、10 张），进程被杀期间的不至于全漏。返回入队数。 */
    fun catchUp(ctx: Context, sinceMs: Long): Int {
        if (!isWanted(ctx) || !isPermitted(ctx)) return 0
        val floor = maxOf(sinceMs, System.currentTimeMillis() - 24L * 3600 * 1000) / 1000
        var n = 0
        for (item in query(ctx, floor, 10)) if (enqueue(ctx, item)) n++
        if (n > 0) log(ctx, JSONObject().put("what", "found").put("n", n).put("why", "catch_up"))
        return n
    }

    private fun query(ctx: Context, sinceS: Long, limit: Int): List<JSONObject> {
        val out = ArrayList<JSONObject>()
        val proj = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.DATA)
        val sel = "${MediaStore.Images.Media.DATE_ADDED} >= ?"
        try {
            ctx.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, proj, sel, arrayOf(sinceS.toString()), "${MediaStore.Images.Media.DATE_ADDED} DESC")?.use { c ->
                val iId = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val iName = c.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val iAdded = c.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                val iData = c.getColumnIndex(MediaStore.Images.Media.DATA)
                while (c.moveToNext() && out.size < limit) {
                    val name = c.getString(iName) ?: ""
                    val path = if (iData >= 0) c.getString(iData) ?: "" else ""
                    val hay = (name + " " + path).lowercase()
                    if (!hay.contains("screenshot") && !hay.contains("截屏") && !hay.contains("截图")) continue
                    val id = c.getLong(iId)
                    out.add(JSONObject()
                        .put("id", id)
                        .put("uri", ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id).toString())
                        .put("name", name)
                        .put("added_ms", c.getLong(iAdded) * 1000))
                }
            }
        } catch (e: Exception) {
            log(ctx, JSONObject().put("what", "query_failed").put("err", e.toString()))
        }
        return out
    }

    /** 没处理过的才入队；返回是否新入队。 */
    @Synchronized
    private fun enqueue(ctx: Context, item: JSONObject): Boolean {
        val p = prefs(ctx)
        val id = item.getLong("id")
        val handled = JSONArray(p.getString(KEY_HANDLED, "[]"))
        for (i in 0 until handled.length()) if (handled.getLong(i) == id) return false
        handled.put(id)
        val trimmedHandled = if (handled.length() > HANDLED_CAP) JSONArray().also { o -> for (i in handled.length() - HANDLED_CAP until handled.length()) o.put(handled.get(i)) } else handled
        val q = JSONArray(p.getString(KEY_QUEUE, "[]"))
        q.put(item)
        val trimmedQ = if (q.length() > QUEUE_CAP) JSONArray().also { o -> for (i in q.length() - QUEUE_CAP until q.length()) o.put(q.get(i)) } else q
        p.edit().putString(KEY_HANDLED, trimmedHandled.toString()).putString(KEY_QUEUE, trimmedQ.toString()).apply()
        return true
    }

    @Synchronized
    fun drain(ctx: Context): String {
        val p = prefs(ctx)
        val s = p.getString(KEY_QUEUE, "[]") ?: "[]"
        p.edit().putString(KEY_QUEUE, "[]").apply()
        return s
    }

    @Synchronized
    fun pendingCount(ctx: Context): Int = try { JSONArray(prefs(ctx).getString(KEY_QUEUE, "[]")).length() } catch (_: Exception) { 0 }

    /** 读一张图并缩到长边 ≤ 1280 的 JPEG（省 token，也别把整张原图塞进内存）。图没了（被删）返回 null。 */
    fun readJpeg(ctx: Context, uri: String): ByteArray? {
        val u = Uri.parse(uri)
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            // 只量尺寸：这一步 decodeStream 恒返回 null，别拿返回值判断
            ctx.contentResolver.openInputStream(u)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_SIDE) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val bmp = ctx.contentResolver.openInputStream(u)?.use { BitmapFactory.decodeStream(it, null, opts) } ?: return null
            val scale = MAX_SIDE.toFloat() / maxOf(bmp.width, bmp.height)
            val fitted = if (scale < 1f) Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt().coerceAtLeast(1), (bmp.height * scale).toInt().coerceAtLeast(1), true) else bmp
            val bos = ByteArrayOutputStream()
            fitted.compress(Bitmap.CompressFormat.JPEG, 85, bos)
            if (fitted !== bmp) fitted.recycle()
            bmp.recycle()
            bos.toByteArray()
        } catch (e: Exception) {
            log(ctx, JSONObject().put("what", "read_failed").put("err", e.toString()))
            null
        }
    }

    /** 诊断日志（环形 30 条）：只记事件，不记图。 */
    @Synchronized
    fun log(ctx: Context, entry: JSONObject) {
        val p = prefs(ctx)
        val arr = JSONArray(p.getString(KEY_LOG, "[]"))
        entry.put("at", System.currentTimeMillis())
        arr.put(entry)
        val trimmed = if (arr.length() > LOG_CAP) JSONArray().also { o -> for (i in arr.length() - LOG_CAP until arr.length()) o.put(arr.get(i)) } else arr
        p.edit().putString(KEY_LOG, trimmed.toString()).apply()
    }

    fun diagnostics(ctx: Context): String = JSONObject()
        .put("wanted", isWanted(ctx))
        .put("permitted", isPermitted(ctx))
        .put("partial", isPartial(ctx))
        .put("observing", observer != null)
        .put("pending", pendingCount(ctx))
        .put("log", JSONArray(prefs(ctx).getString(KEY_LOG, "[]")))
        .toString()
}
