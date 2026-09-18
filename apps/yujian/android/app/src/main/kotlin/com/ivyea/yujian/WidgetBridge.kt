package com.ivyea.yujian

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Flutter → 小部件：存几个字符串（含日历用的逐日支出 / 收入），刷新所有实例。 */
object WidgetBridge {
    private const val CHANNEL = "yujian/widget"

    fun register(ctx: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val args = call.arguments as? Map<*, *>
                    val p = ctx.getSharedPreferences(SummaryWidget.PREFS, Context.MODE_PRIVATE).edit()
                    for (k in listOf("balance", "expense", "income", "month", "recent", "today", "cal_ym", "cal_exp", "cal_inc")) p.putString(k, args?.get(k) as? String ?: "")
                    p.apply()
                    SummaryWidget.refreshAll(ctx)
                    result.success(null)
                }
                // 桌面小部件页：桌面是否支持「从 App 内添加」（Android 8+，且桌面实现了 pin）
                "pinSupported" -> result.success(pinSupported(ctx))
                // 弹系统的「添加到主屏幕」确认框；kind 是小部件种类。返回 false = 桌面不支持，让用户手动长按桌面添加
                "pin" -> {
                    val kind = (call.arguments as? Map<*, *>)?.get("kind") as? String
                    val cls = when (kind) {
                        "summary" -> SummaryWidget::class.java
                        "compact" -> CompactWidget::class.java
                        "large" -> LargeWidget::class.java
                        "mini" -> MiniWidget::class.java
                        "calendar" -> CalendarWidget::class.java
                        else -> null
                    }
                    if (cls == null) { result.error("bad_kind", "unknown widget kind: $kind", null); return@setMethodCallHandler }
                    result.success(try {
                        pinSupported(ctx) && AppWidgetManager.getInstance(ctx).requestPinAppWidget(ComponentName(ctx, cls), null, null)
                    } catch (_: Exception) { false })
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pinSupported(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && try { AppWidgetManager.getInstance(ctx).isRequestPinAppWidgetSupported } catch (_: Exception) { false }
}
