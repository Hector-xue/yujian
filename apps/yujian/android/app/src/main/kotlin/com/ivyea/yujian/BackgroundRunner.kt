package com.ivyea.yujian

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import org.json.JSONObject

/**
 * App 没开着（没有前台引擎）时在后台跑一次 Dart：起一个无头引擎执行 `backgroundWork` 入口，
 * 它把三个队列吃掉——付款通知 / 支付页识别、相册截图、通知栏上点的「确认 / 忽略 / 撤销」——然后叫 [done] 销毁引擎。
 *
 * 截图自动记账原来自己管一个无头引擎；现在三件事共用这一个：同一时间只跑一个，跑着的时候又来了活就记一笔，
 * 跑完立刻再跑一轮（以前跑着的时候来的截图要等下一次触发才处理）。
 */
object BackgroundRunner {
    private const val ENTRYPOINT = "backgroundWork"
    private const val PREFS = "yujian_background"
    private const val KEY_WANTED = "payments_wanted"
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var since = 0L
    private var again = false
    private var scheduled = false

    // 像一笔钱的通知：有金额（¥12 / 12.5 元）而且有钱的动作词。聊天、验证码、新闻这些不起引擎，省电
    private val amountRe = Regex("""[¥￥]\s*\d|\d+(?:\.\d{1,2})?\s*元""")
    private val moneyRe = Regex("支付|付款|收款|消费|支出|收入|入账|到账|退款|扣款|转账|还款|交易|成功")

    /** Dart 侧（前台引擎）告诉原生：付款通知要不要在后台处理（「记账后弹通知」打开 + 通知 / 支付页记账开着）。 */
    fun setPaymentsWanted(ctx: Context, v: Boolean) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_WANTED, v).apply()
    }

    private fun paymentsWanted(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_WANTED, false)

    /** 一条付款通知 / 支付页已经进了队列、前台引擎不在：像钱的话起后台跑一轮（2 秒内连着来的合成一次）。 */
    fun onPaymentQueued(ctx: Context, text: String, fromScreen: Boolean) {
        if (!paymentsWanted(ctx)) return
        if (!fromScreen && !(amountRe.containsMatchIn(text) && moneyRe.containsMatchIn(text))) return
        val app = ctx.applicationContext
        main.post {
            if (scheduled) return@post // 已经排着一轮了，这条会被它一起吃掉
            scheduled = true
            main.postDelayed({
                scheduled = false
                startOnMain(app, "payment") // 正在跑的话会记成「跑完再来一轮」，不会漏
            }, 1500) // 微信常常连发两条（付款 + 服务通知），等一下一起吃
        }
    }

    /** 起后台跑一轮；已经在跑就等它跑完再跑一轮。 */
    fun start(ctx: Context, reason: String) {
        main.post { startOnMain(ctx.applicationContext, reason) }
    }

    private fun startOnMain(ctx: Context, reason: String) {
        if (engine != null) {
            // 一个还在跑：跑超过 3 分钟当挂了，销毁重来；否则记下来，跑完再来一轮
            if (System.currentTimeMillis() - since < 3 * 60 * 1000L) {
                again = true
                return
            }
            destroy()
        }
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            if (!loader.initialized()) {
                loader.startInitialization(ctx)
                loader.ensureInitializationComplete(ctx, null)
            }
            val e = FlutterEngine(ctx)
            GeneratedPluginRegistrant.registerWith(e)
            ScreenshotBridge.register(ctx, e, null)
            NotificationBridge.register(ctx, e, foreground = false)
            DraftNotifier.register(ctx, e, null)
            WidgetBridge.register(ctx, e)
            e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT))
            engine = e
            since = System.currentTimeMillis()
            again = false
            ScreenshotWatcher.log(ctx, JSONObject().put("what", "headless_started").put("reason", reason))
        } catch (e: Exception) {
            ScreenshotWatcher.log(ctx, JSONObject().put("what", "headless_failed").put("err", e.toString()))
        }
    }

    /** 无头引擎里的 Dart 跑完了。前台引擎调到这里不会发生（只在无头引擎的通道上接）。 */
    fun done(ctx: Context) {
        main.post {
            destroy()
            if (again) {
                again = false
                startOnMain(ctx.applicationContext, "again")
            }
        }
    }

    private fun destroy() {
        engine?.destroy()
        engine = null
    }
}
