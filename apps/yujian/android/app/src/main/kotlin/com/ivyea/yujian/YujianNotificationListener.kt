package com.ivyea.yujian

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * 只读系统通知，攒进本地队列（SharedPreferences），App 打开时 drain；App 在前台时同时通过 EventChannel 直推。
 * 不读短信、不用无障碍。用户在系统设置里授权后才会被绑定。
 */
class YujianNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val extras = sbn.notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: return
        if (text.isBlank()) return
        val json = JSONObject()
            .put("package", sbn.packageName)
            .put("title", title)
            .put("text", text)
            .put("posted_at_ms", sbn.postTime)
            .put("key", sbn.key)
        enqueue(applicationContext, json)
        NotificationBridge.push(json.toString())
    }

    companion object {
        private const val PREFS = "yujian_notifications"
        private const val KEY = "queue"
        private const val CAP = 500

        @Synchronized
        fun enqueue(ctx: Context, json: JSONObject) {
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val arr = JSONArray(prefs.getString(KEY, "[]"))
            arr.put(json)
            val trimmed = if (arr.length() > CAP) JSONArray().also { out ->
                for (i in arr.length() - CAP until arr.length()) out.put(arr.get(i))
            } else arr
            prefs.edit().putString(KEY, trimmed.toString()).apply()
        }

        @Synchronized
        fun drain(ctx: Context): String {
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val s = prefs.getString(KEY, "[]") ?: "[]"
            prefs.edit().putString(KEY, "[]").apply()
            return s
        }

        fun isEnabled(ctx: Context): Boolean {
            val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
            val me = ComponentName(ctx, YujianNotificationListener::class.java)
            return flat.split(":").any { ComponentName.unflattenFromString(it) == me }
        }
    }
}
