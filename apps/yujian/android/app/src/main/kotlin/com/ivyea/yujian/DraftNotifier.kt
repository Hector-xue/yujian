package com.ivyea.yujian

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * 记账后的系统通知：「待确认 ¥28 · 午饭」带 确认 / 忽略，「已记 ¥28」带 撤销。
 * 按钮不在这里改账本——点了只是把动作排进队列（[DraftActionReceiver]），交给 Dart 用和收件箱同一套逻辑落账：
 * 前台引擎在就直推给它，不在就起后台跑一轮（[BackgroundRunner]）。队列落在 SharedPreferences 里，进程被杀了下次打开照样处理。
 */
object DraftNotifier {
    private const val METHODS = "yujian/drafts"
    private const val EVENTS = "yujian/drafts/stream"
    const val CH_PENDING = "drafts_pending"
    const val CH_AUTO = "drafts_auto"
    private const val NOTIF_ID = 0x7a1 // 同一个 id + 不同 tag（草稿 id / tx:交易 id）
    private const val GROUP = "yujian_drafts"
    private const val PREFS = "yujian_draft_actions"
    private const val KEY = "queue"
    const val ACTION = "com.ivyea.yujian.DRAFT_ACTION"
    private const val PERMISSION_REQ = 0x5c12
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null

    /** [activity] 为 null 是无头引擎：不能申请权限、没有事件流，其余一样。 */
    fun register(ctx: Context, engine: FlutterEngine, activity: Activity?) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "canPost" -> result.success(canPost(ctx))
                "requestPermission" -> {
                    if (canPost(ctx) || Build.VERSION.SDK_INT < 33) { result.success(canPost(ctx)); return@setMethodCallHandler }
                    if (activity == null) { result.success(false); return@setMethodCallHandler }
                    pendingPermission?.success(false)
                    pendingPermission = result
                    ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQ)
                }
                "post" -> {
                    val items = call.arguments as? List<*> ?: emptyList<Any>()
                    for (i in items) (i as? Map<*, *>)?.let { post(ctx, it) }
                    result.success(null)
                }
                "cancel" -> {
                    (call.arguments as? List<*>)?.forEach { t -> (t as? String)?.let { NotificationManagerCompat.from(ctx).cancel(it, NOTIF_ID) } }
                    result.success(null)
                }
                "drainActions" -> result.success(drainActions(ctx))
                "setPaymentsWanted" -> {
                    BackgroundRunner.setPaymentsWanted(ctx, call.arguments as? Boolean ?: false)
                    result.success(null)
                }
                // 无头引擎跑完了（截图 / 通知 / 按钮动作共用一个引擎）
                "backgroundDone" -> {
                    result.success(null)
                    if (activity == null) BackgroundRunner.done(ctx)
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

    /** 前台 Activity 销毁了：它的引擎也没了，别再往它推（推了也没人收，动作就只在队列里躺着）。 */
    fun detach() { sink = null }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQ) return false
        pendingPermission?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
        return true
    }

    fun canPost(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return NotificationManagerCompat.from(ctx).areNotificationsEnabled()
    }

    private fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CH_PENDING) == null) {
            nm.createNotificationChannel(NotificationChannel(CH_PENDING, "待确认的账", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "自动记账认出一笔、等你确认时提醒；通知里能直接确认或忽略"
            })
        }
        if (nm.getNotificationChannel(CH_AUTO) == null) {
            nm.createNotificationChannel(NotificationChannel(CH_AUTO, "自动记下的账", NotificationManager.IMPORTANCE_LOW).apply {
                description = "智能 / 静默模式自动入账后告诉你一声（不响铃），记错了能直接撤销"
            })
        }
    }

    /** 一条通知。item：tag（草稿 id，或 tx:交易 id）、kind（pending / committed / failed）、title、text、target、can_confirm。 */
    private fun post(ctx: Context, item: Map<*, *>) {
        if (!canPost(ctx)) return
        ensureChannels(ctx)
        val tag = item["tag"] as? String ?: return
        val kind = item["kind"] as? String ?: "pending"
        val target = item["target"] as? String ?: tag
        val auto = kind == "committed"
        val open = PendingIntent.getActivity(
            ctx, ("open:$tag").hashCode(),
            Intent(Intent.ACTION_VIEW, Uri.parse(if (auto) "yujian://records" else "yujian://inbox"), ctx, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val b = NotificationCompat.Builder(ctx, if (auto) CH_AUTO else CH_PENDING)
            .setSmallIcon(R.drawable.ic_stat_yujian)
            .setContentTitle(item["title"] as? String ?: "余见")
            .setContentText(item["text"] as? String ?: "")
            .setStyle(NotificationCompat.BigTextStyle().bigText(item["text"] as? String ?: ""))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setGroup(GROUP)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(if (auto) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_DEFAULT)
        when (kind) {
            "pending" -> {
                if (item["can_confirm"] == true) b.addAction(0, "确认", action(ctx, "confirm", tag, target))
                b.addAction(0, "忽略", action(ctx, "dismiss", tag, target))
                if (item["can_confirm"] != true) b.addAction(0, "去补全", open)
            }
            "committed" -> b.addAction(0, "撤销", action(ctx, "undo", tag, target))
        }
        try {
            NotificationManagerCompat.from(ctx).notify(tag, NOTIF_ID, b.build())
        } catch (_: SecurityException) {
            // 权限在两步之间被收回：不发
        }
    }

    private fun action(ctx: Context, op: String, tag: String, target: String): PendingIntent = PendingIntent.getBroadcast(
        ctx, ("$op:$tag").hashCode(),
        Intent(ctx, DraftActionReceiver::class.java).setAction(ACTION).putExtra("op", op).putExtra("tag", tag).putExtra("target", target),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** 通知按钮点了：先撤下这条通知（给人立刻有反馈），动作进队列，再交给 Dart。 */
    fun onAction(ctx: Context, op: String, tag: String, target: String) {
        NotificationManagerCompat.from(ctx).cancel(tag, NOTIF_ID)
        enqueue(ctx, JSONObject().put("op", op).put("tag", tag).put("target", target).put("at_ms", System.currentTimeMillis()))
        val s = sink
        if (s != null) main.post { s.success("action") } else BackgroundRunner.start(ctx, "action")
    }

    @Synchronized
    private fun enqueue(ctx: Context, j: JSONObject) {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = JSONArray(p.getString(KEY, "[]"))
        arr.put(j)
        p.edit().putString(KEY, arr.toString()).commit() // commit 不用 apply：接下来可能马上起引擎读它
    }

    @Synchronized
    private fun drainActions(ctx: Context): String {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val s = p.getString(KEY, "[]") ?: "[]"
        p.edit().putString(KEY, "[]").commit()
        return s
    }
}
