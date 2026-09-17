package com.ivyea.yujian

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject

/**
 * 支付页识别（可选，用户在系统「无障碍」里显式打开）：
 * 微信 / 支付宝付款时手机不会弹系统通知（App 在前台），通知监听抓不到；这里在「支付成功」页面出现的那一刻
 * 把金额和商户读出来，走和通知完全相同的队列与模板，进收件箱或按模式自动入账。
 *
 * 只看名单里的支付 / 购物 App，只在页面里有「支付成功」字样时读一次，读到的文字不出本机。
 * 用户在余见里关掉开关（screen_wanted=false）后即使系统服务还绑着也什么都不做。
 */
class PaymentScreenService : AccessibilityService() {
    private var lastScanAt = 0L
    private var lastSig = ""
    private var lastSigAt = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        if (pkg !in APP_NAMES) return
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) return
        if (!isWanted(applicationContext)) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastScanAt < 600) return // 内容变化事件一秒能来几十次，限频
        lastScanAt = now
        val root = rootInActiveWindow ?: return
        val texts = ArrayList<String>(64)
        collect(root, texts, 0)
        val found = PaymentScreenParser.extract(texts) ?: return
        val sig = "$pkg:${found.amount}"
        if (sig == lastSig && now - lastSigAt < 120_000) return // 同一页面反复触发
        lastSig = sig
        lastSigAt = now
        val wall = System.currentTimeMillis()
        val json = JSONObject()
            .put("package", pkg)
            .put("title", "${APP_NAMES[pkg]} 支付成功页")
            .put("text", "支付成功 ¥${found.amount}" + (found.merchant?.let { " 商户：$it" } ?: ""))
            .put("posted_at_ms", wall)
            .put("key", "screen:$pkg:${found.amount}:${wall / 60000}")
            .put("source", "screen")
        YujianNotificationListener.enqueue(applicationContext, json)
        NotificationBridge.push(json.toString())
    }

    override fun onInterrupt() {}

    private fun collect(node: AccessibilityNodeInfo, out: MutableList<String>, depth: Int) {
        if (depth > 40 || out.size > 400) return
        val t = node.text?.toString()?.trim()
        if (!t.isNullOrEmpty()) out.add(t)
        else {
            val d = node.contentDescription?.toString()?.trim()
            if (!d.isNullOrEmpty()) out.add(d)
        }
        for (i in 0 until node.childCount) {
            val c = node.getChild(i) ?: continue
            collect(c, out, depth + 1)
        }
    }

    companion object {
        const val PREFS = "yujian_automation"
        const val KEY_WANTED = "screen_wanted"

        /** 监听名单：支付 App + 常见购物 / 外卖 / 出行 App（它们的支付成功页也在自己 App 里）。 */
        val APP_NAMES = mapOf(
            "com.tencent.mm" to "微信支付",
            "com.eg.android.AlipayGphone" to "支付宝",
            "com.unionpay" to "云闪付",
            "com.taobao.taobao" to "淘宝",
            "com.tmall.wireless" to "天猫",
            "com.jingdong.app.mall" to "京东",
            "com.xunmeng.pinduoduo" to "拼多多",
            "com.sankuai.meituan" to "美团",
            "com.sankuai.meituan.takeoutnew" to "美团外卖",
            "me.ele" to "饿了么",
            "com.ss.android.ugc.aweme" to "抖音",
            "com.xingin.xhs" to "小红书",
            "com.sdu.didi.psnger" to "滴滴",
            "com.MobileTicket" to "12306",
            "ctrip.android.view" to "携程",
            "com.dianping.v1" to "大众点评",
        )

        fun isWanted(ctx: Context): Boolean = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_WANTED, false)
        fun setWanted(ctx: Context, v: Boolean) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_WANTED, v).apply()

        fun isEnabled(ctx: Context): Boolean {
            val flat = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
            val me = ComponentName(ctx, PaymentScreenService::class.java)
            return flat.split(":").any { ComponentName.unflattenFromString(it) == me }
        }

    }
}
