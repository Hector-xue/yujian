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
 * 桌面小部件。数字由 Flutter 侧算好（账本只有一份实现）经 WidgetBridge 存进 SharedPreferences，这里只负责画。
 * 点整块 → 打开首页；点「记一笔」→ 直接进对话。
 */
class SummaryWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, build(context))
    }

    companion object {
        const val PREFS = "yujian_widget"

        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, SummaryWidget::class.java))
            if (ids.isEmpty()) return
            val views = build(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        private fun build(context: Context): RemoteViews {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(context.packageName, R.layout.widget_summary)
            v.setTextViewText(R.id.widget_balance, p.getString("balance", "¥ 0.00"))
            v.setTextViewText(R.id.widget_expense, p.getString("expense", "¥ 0.00"))
            v.setTextViewText(R.id.widget_income, p.getString("income", "¥ 0.00"))
            v.setTextViewText(R.id.widget_month, p.getString("month", ""))
            v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
            v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
            return v
        }

        private fun open(context: Context, uri: String, code: Int): PendingIntent {
            val i = Intent(Intent.ACTION_VIEW, Uri.parse(uri), context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(context, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
