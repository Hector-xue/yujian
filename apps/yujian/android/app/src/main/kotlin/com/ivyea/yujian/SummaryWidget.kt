package com.ivyea.yujian

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

/**
 * 桌面小部件（四个尺寸共用一套数据）。数字由 Flutter 侧算好经 WidgetBridge 存进 SharedPreferences，这里只负责画。
 * 点整块 → 首页；点「记一笔」→ 直接进对话。
 */
open class SummaryWidget : AppWidgetProvider() {
    open val layout: Int get() = R.layout.widget_summary

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, build(context, layout))
    }

    companion object {
        const val PREFS = "yujian_widget"

        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            for ((cls, layout) in listOf(SummaryWidget::class.java to R.layout.widget_summary, LargeWidget::class.java to R.layout.widget_large, CompactWidget::class.java to R.layout.widget_compact, MiniWidget::class.java to R.layout.widget_mini)) {
                val ids = manager.getAppWidgetIds(ComponentName(context, cls))
                if (ids.isEmpty()) continue
                val views = build(context, layout)
                for (id in ids) manager.updateAppWidget(id, views)
            }
        }

        private fun build(context: Context, layout: Int): RemoteViews {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(context.packageName, layout)
            when (layout) {
                R.layout.widget_summary -> {
                    v.setTextViewText(R.id.widget_balance, p.getString("balance", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_expense, p.getString("expense", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_income, p.getString("income", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_month, p.getString("month", ""))
                    v.setTextViewText(R.id.widget_recent, p.getString("recent", ""))
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                }
                R.layout.widget_large -> {
                    v.setTextViewText(R.id.widget_today, p.getString("today", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_month, p.getString("month", ""))
                    v.setTextViewText(R.id.widget_expense, "本月支出 " + p.getString("expense", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_balance, "余额 " + p.getString("balance", "¥ 0.00"))
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                }
                R.layout.widget_compact -> {
                    v.setTextViewText(R.id.widget_balance, p.getString("balance", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_expense, "本月支出 " + p.getString("expense", "¥ 0.00"))
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                }
                else -> v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
            }
            return v
        }

        private fun open(context: Context, uri: String, code: Int): PendingIntent {
            val i = Intent(Intent.ACTION_VIEW, Uri.parse(uri), context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(context, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}

class LargeWidget : SummaryWidget() {
    override val layout: Int get() = R.layout.widget_large
}

class CompactWidget : SummaryWidget() {
    override val layout: Int get() = R.layout.widget_compact
}

class MiniWidget : SummaryWidget() {
    override val layout: Int get() = R.layout.widget_mini
}
