package com.ivyea.yujian

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * 支付页识别（可选，用户在系统「无障碍」里显式打开）：
 * 微信 / 支付宝付款时手机不会弹系统通知（App 在前台），通知监听抓不到；这里在「支付成功」页面出现的那一刻
 * 把金额和商户读出来，走和通知完全相同的队列与模板，进收件箱或按模式自动入账。
 *
 * 只看名单里的支付 / 购物 App，只在页面里有「支付成功」字样时读一次，读到的文字不出本机。
 * 用户在余见里关掉开关（screen_wanted=false）后即使系统服务还绑着也什么都不做。
 *
 * 扫描时机：事件来了不是立刻扫也不是丢掉，而是延后一小段再扫（页面刚出现时节点还没铺满；内容变化事件一秒几十次，
 * 合并成最后一次）；窗口切换事件另外再补扫一次。每一步都记到诊断日志里（[log]），App 的「自动记账」页能看，
 * 没识别到时能说出卡在哪一环：服务没绑上 / 事件没来 / 页面里没「支付成功」/ 有字样但没读到金额 / 已入队。
 *
 * 读不到节点文字（微信全线自绘）时截屏 + 本机 OCR。截屏只在两种时机：窗口切换后的补扫；以及窗口切换后 8 秒「就绪窗」内的
 * 内容变化（成功页有时不是新窗口而是同一 Activity 里换页，只发内容变化事件；付款前必经密码弹窗，那就是一次窗口切换）。
 * 限速内到来的截屏请求延后到限速到期再截，不丢（此前是直接丢掉：密码窗那一帧刚截完，成功页那一帧就被限速吃掉了）。
 * 是不是成功页由 [PaymentScreenParser.analyze] 按页面结构判，翻聊天记录 / 账单不会被当成付款。
 */
class PaymentScreenService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private var lastSig = ""
    private var lastSigAt = 0L
    private var pendingPkg: String? = null
    private var pendingClass: String? = null
    private var lastMarkAt = 0L
    private var lastShotAt = 0L
    private var lastWindowChangeAt = 0L
    private var shotPending = false
    private val scanNow = Runnable { pendingPkg?.let { scan(it, pendingClass) } }
    private val scanLate = Runnable { pendingPkg?.let { scan(it, pendingClass, late = true) } }
    private val shotDeferred = Runnable {
        shotPending = false
        pendingPkg?.let { shotAndRead(it, pendingClass, JSONObject().put("pkg", it).put("cls", pendingClass ?: "").put("late", true)) }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        prefs(this).edit().putLong(KEY_CONNECTED_AT, System.currentTimeMillis()).apply()
        log(this, JSONObject().put("what", "connected"))
        ScreenshotWatcher.ensureStarted(applicationContext) // 常驻服务，顺手挂截图观察者
    }

    override fun onUnbind(intent: Intent?): Boolean {
        prefs(this).edit().putLong(KEY_CONNECTED_AT, 0L).apply()
        log(this, JSONObject().put("what", "unbound"))
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        if (pkg !in APP_NAMES) return
        val type = event.eventType
        if (type != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && type != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED && type != AccessibilityEvent.TYPE_WINDOWS_CHANGED) return
        val cls = event.className?.toString()
        // 「最近一次事件」落盘限到 2 秒一次：微信聊天页滚动一秒能来几十个内容变化事件，别让它刷磁盘
        val now = SystemClock.elapsedRealtime()
        val mark = now - lastMarkAt > 2000
        if (mark) {
            lastMarkAt = now
            prefs(this).edit().putLong(KEY_LAST_EVENT_AT, System.currentTimeMillis()).putString(KEY_LAST_EVENT_PKG, pkg).apply()
        }
        if (!isWanted(applicationContext)) {
            if (mark) log(this, JSONObject().put("what", "not_wanted").put("pkg", pkg))
            return
        }
        pendingPkg = pkg
        if (cls != null && type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) pendingClass = cls
        main.removeCallbacks(scanNow)
        main.postDelayed(scanNow, 350)
        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            lastWindowChangeAt = now
            main.removeCallbacks(scanLate)
            main.postDelayed(scanLate, 1500)
        }
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    /** 窗口切换后 8 秒内算「就绪」：这段时间里内容变化事件也允许截屏（成功页可能只是同一窗口里换页）。 */
    private fun armed(): Boolean = SystemClock.elapsedRealtime() - lastWindowChangeAt < PaymentScreenParser.ARMED_WINDOW_MS

    private fun scan(pkg: String, cls: String?, late: Boolean = false) {
        val lines = ArrayList<PaymentScreenParser.Line>(128)
        var roots = 0
        // 先遍历该 App 的所有窗口（支付成功页可能不是活动窗口），再兜底活动窗口
        try {
            for (w in windows) {
                val root = w.root ?: continue
                if (root.packageName?.toString() != pkg) continue
                roots++
                collect(root, lines, 0)
            }
        } catch (_: Throwable) {}
        if (roots == 0) {
            val root = rootInActiveWindow
            if (root != null && root.packageName?.toString() == pkg) {
                roots++
                collect(root, lines, 0)
            }
        }
        val entry = JSONObject().put("pkg", pkg).put("cls", cls ?: "").put("n", lines.size).put("late", late)
        if (roots == 0) {
            log(this, entry.put("what", "no_root"))
            if (late || armed()) shotAndRead(pkg, cls, entry) // 拿不到窗口：也截一帧试试
            return
        }
        if (lines.isEmpty()) {
            // 有窗口却一段文字都没有：微信的支付页是自绘界面，节点树本来就没字（声明成无障碍工具也一样）。
            // 记一类，然后走截屏 + 本机 OCR 这条路：补扫那次一定截；就绪窗内的内容变化也截（页面刚出现的 350ms 那次可能只是还没铺完，
            // 但成功页若不是新窗口就只有这种事件，不能等）
            log(this, entry.put("what", "empty_tree").put("sdk", Build.VERSION.SDK_INT))
            if (late || armed()) shotAndRead(pkg, cls, entry)
            return
        }
        handleLines(pkg, lines, screenHeight(), entry, how = "tree")
    }

    private fun screenHeight(): Int = try { resources.displayMetrics.heightPixels } catch (_: Throwable) { 0 }

    /**
     * 节点树读不到字：截一帧屏幕、本机 OCR。位图只在内存里，识别完即丢。API 30+ 才有截屏能力。
     * 限速（[SHOT_INTERVAL_MS]）内的请求不丢，延后到限速到期再截一次（多次请求合并成一次）。
     */
    private fun shotAndRead(pkg: String, cls: String?, entry: JSONObject) {
        if (Build.VERSION.SDK_INT < 30) return
        val now = SystemClock.elapsedRealtime()
        val wait = SHOT_INTERVAL_MS - (now - lastShotAt)
        if (wait > 0) {
            if (!shotPending) {
                shotPending = true
                main.postDelayed(shotDeferred, wait)
                log(this, JSONObject().put("what", "shot_deferred").put("pkg", pkg).put("cls", cls ?: "").put("ms", wait))
            }
            return
        }
        lastShotAt = now
        try {
            takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(result: AccessibilityService.ScreenshotResult) {
                    val hw = result.hardwareBuffer
                    val bmp = try {
                        Bitmap.wrapHardwareBuffer(hw, result.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false)
                    } catch (_: Throwable) { null } finally { hw.close() }
                    if (bmp == null) {
                        log(this@PaymentScreenService, JSONObject().put("what", "shot_failed").put("pkg", pkg).put("err", "bitmap"))
                        return
                    }
                    val shotH = bmp.height
                    Ocr.recognize(bmp) { ocrLines, err ->
                        bmp.recycle()
                        if (ocrLines == null) {
                            log(this@PaymentScreenService, JSONObject().put("what", "shot_failed").put("pkg", pkg).put("err", err ?: ""))
                            return@recognize
                        }
                        val lines = ocrLines.mapNotNull {
                            val t = (it["text"] as? String ?: "").trim()
                            if (t.isEmpty()) null else PaymentScreenParser.Line(t, top = (it["top"] as? Int) ?: -1, height = (it["height"] as? Int) ?: -1)
                        }
                        val e2 = JSONObject().put("pkg", pkg).put("cls", cls ?: "").put("n", lines.size).put("late", true)
                        if (lines.isEmpty()) {
                            log(this@PaymentScreenService, e2.put("what", "shot_empty"))
                            return@recognize
                        }
                        handleLines(pkg, lines, shotH, e2, how = "ocr")
                    }
                }

                override fun onFailure(errorCode: Int) {
                    log(this@PaymentScreenService, JSONObject().put("what", "shot_failed").put("pkg", pkg).put("err", "code $errorCode"))
                }
            })
        } catch (e: Throwable) {
            log(this, JSONObject().put("what", "shot_failed").put("pkg", pkg).put("err", e.toString()))
        }
    }

    /** 一页文字（来自节点树或 OCR，带位置）→ 结构门禁 → 金额 + 商户 → 入队。 */
    private fun handleLines(pkg: String, lines: List<PaymentScreenParser.Line>, screenHeight: Int, entry: JSONObject, how: String) {
        entry.put("how", how)
        val r = PaymentScreenParser.analyze(lines, screenHeight)
        val found = r.found
        if (found == null) {
            when (r.reason) {
                "no_success_text" -> log(this, entry.put("what", "no_success_text"))
                "no_amount" -> {
                    // 有「支付成功」字样却没读到金额：把页面开头几段（截短）留在本机日志里，方便对着补规则
                    entry.put("sample", JSONArray(lines.take(12).map { it.text.take(24) }))
                    log(this, entry.put("what", "no_amount"))
                }
                // 有「支付成功」但页面结构不像刚付完款的那一页（聊天记录 / 账单 / 历史详情）
                else -> log(this, entry.put("what", "rejected").put("reason", r.reason ?: ""))
            }
            return
        }
        val now = SystemClock.elapsedRealtime()
        val sig = "$pkg:${found.amount}"
        if (sig == lastSig && now - lastSigAt < 120_000) {
            log(this, entry.put("what", "dup").put("amount", found.amount))
            return // 同一页面反复触发
        }
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
        log(this, entry.put("what", "enqueued").put("amount", found.amount).put("merchant", found.merchant ?: ""))
    }

    private fun collect(node: AccessibilityNodeInfo, out: MutableList<PaymentScreenParser.Line>, depth: Int) {
        if (depth > 48 || out.size > 600) return
        val t = node.text?.toString()?.trim().let { if (it.isNullOrEmpty()) node.contentDescription?.toString()?.trim() else it }
        if (!t.isNullOrEmpty()) {
            val rect = Rect()
            try { node.getBoundsInScreen(rect) } catch (_: Throwable) {}
            // 滚到屏幕上方外面的节点 top 为负，按 0 算（仍在上半区）；没有边界的按未知
            val top = if (rect.isEmpty) -1 else maxOf(0, rect.top)
            out.add(PaymentScreenParser.Line(t, top = top, height = if (rect.isEmpty) -1 else rect.height()))
        }
        for (i in 0 until node.childCount) {
            val c = node.getChild(i) ?: continue
            collect(c, out, depth + 1)
        }
    }

    companion object {
        const val PREFS = "yujian_automation"
        const val KEY_WANTED = "screen_wanted"
        const val KEY_CONNECTED_AT = "screen_connected_at"
        const val KEY_LAST_EVENT_AT = "screen_last_event_at"
        const val KEY_LAST_EVENT_PKG = "screen_last_event_pkg"
        const val KEY_LOG = "screen_log"
        private const val LOG_CAP = 40
        private const val SHOT_INTERVAL_MS = 1000L // 系统 takeScreenshot 自身约 333ms 一次；OCR 一两百毫秒

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

        private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun isWanted(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_WANTED, false)
        fun setWanted(ctx: Context, v: Boolean) = prefs(ctx).edit().putBoolean(KEY_WANTED, v).apply()

        /** 系统当前记录的服务信息里 isAccessibilityTool 是否为真：老版本升上来系统可能还缓存着旧声明，要关一下再开。 */
        fun isTool(ctx: Context): Boolean {
            if (android.os.Build.VERSION.SDK_INT < 33) return true // 33 以下没有这个概念，也没有 dataSensitive 屏蔽
            return try {
                val am = ctx.getSystemService(Context.ACCESSIBILITY_SERVICE) as android.view.accessibility.AccessibilityManager
                val me = ComponentName(ctx, PaymentScreenService::class.java)
                am.getEnabledAccessibilityServiceList(android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
                    .firstOrNull { ComponentName.unflattenFromString(it.id) == me }?.isAccessibilityTool ?: true
            } catch (_: Throwable) { true }
        }

        fun isEnabled(ctx: Context): Boolean {
            val flat = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
            val me = ComponentName(ctx, PaymentScreenService::class.java)
            return flat.split(":").any { ComponentName.unflattenFromString(it) == me }
        }

        /**
         * 诊断日志：环形 40 条，连续同类（同 what+pkg）的只在最后一条上累加 count，微信聊天页几十次「没有支付成功字样」不会把日志刷穿。
         * 不记页面全文；只有「有支付成功字样但没读到金额」时留截短的开头几段，方便补规则。
         */
        @Synchronized
        fun log(ctx: Context, entry: JSONObject) {
            val p = prefs(ctx)
            val arr = try { JSONArray(p.getString(KEY_LOG, "[]")) } catch (_: Throwable) { JSONArray() }
            val now = System.currentTimeMillis()
            val last = if (arr.length() > 0) arr.optJSONObject(arr.length() - 1) else null
            if (last != null && last.optString("what") == entry.optString("what") && last.optString("pkg") == entry.optString("pkg") && last.optString("reason") == entry.optString("reason") && entry.optString("what") in setOf("no_success_text", "no_root", "empty_tree", "not_wanted", "dup", "rejected", "shot_deferred")) {
                last.put("count", last.optInt("count", 1) + 1).put("t", now)
                p.edit().putString(KEY_LOG, arr.toString()).apply()
                return
            }
            entry.put("t", now)
            arr.put(entry)
            val trimmed = if (arr.length() > LOG_CAP) JSONArray().also { out -> for (i in arr.length() - LOG_CAP until arr.length()) out.put(arr.get(i)) } else arr
            p.edit().putString(KEY_LOG, trimmed.toString()).apply()
        }

        /** 给 App 看的诊断快照：系统是否已开、余见开关、服务是否绑着、最近事件、日志。 */
        fun diagnostics(ctx: Context): String {
            val p = prefs(ctx)
            return JSONObject()
                .put("enabled", isEnabled(ctx))
                .put("wanted", isWanted(ctx))
                .put("connected_at", p.getLong(KEY_CONNECTED_AT, 0L))
                .put("last_event_at", p.getLong(KEY_LAST_EVENT_AT, 0L))
                .put("last_event_pkg", p.getString(KEY_LAST_EVENT_PKG, "") ?: "")
                .put("sdk", android.os.Build.VERSION.SDK_INT)
                .put("tool", isTool(ctx))
                .put("log", try { JSONArray(p.getString(KEY_LOG, "[]")) } catch (_: Throwable) { JSONArray() })
                .toString()
        }

        @Synchronized
        fun clearLog(ctx: Context) = prefs(ctx).edit().remove(KEY_LOG).apply()
    }
}
