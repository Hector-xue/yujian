package com.ivyea.yujian

import android.content.Context
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
                else -> result.notImplemented()
            }
        }
    }
}
