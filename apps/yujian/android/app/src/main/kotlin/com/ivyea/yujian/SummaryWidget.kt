package com.ivyea.yujian

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import java.util.Calendar

/**
 * 桌面小部件（六种共用一套数据）。数字由 Flutter 侧算好经 WidgetBridge 存进 SharedPreferences，这里只负责画。
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
            for ((cls, layout) in listOf(SummaryWidget::class.java to R.layout.widget_summary, LargeWidget::class.java to R.layout.widget_large, CompactWidget::class.java to R.layout.widget_compact, MiniWidget::class.java to R.layout.widget_mini, CalendarWidget::class.java to R.layout.widget_calendar, GoalsWidget::class.java to R.layout.widget_goals, GoalsSmallWidget::class.java to R.layout.widget_goals_small)) {
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
                    title(v, p)
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                }
                R.layout.widget_large -> {
                    v.setTextViewText(R.id.widget_today, p.getString("today", "¥ 0.00"))
                    // 2×2 头行让给称号胶囊，月份并进支出那行：「9 月支出 ¥ …」；App 还没推过月份就退回「本月支出」
                    val month = p.getString("month", "") ?: ""
                    v.setTextViewText(R.id.widget_expense, (if (month.isEmpty()) "本月" else month) + "支出 " + p.getString("expense", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_balance, "余额 " + p.getString("balance", "¥ 0.00"))
                    title(v, p)
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                }
                R.layout.widget_compact -> {
                    v.setTextViewText(R.id.widget_balance, p.getString("balance", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_expense, "本月支出 " + p.getString("expense", "¥ 0.00"))
                    title(v, p)
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                }
                R.layout.widget_calendar -> {
                    v.setTextViewText(R.id.widget_expense, "支出 " + p.getString("expense", "¥ 0.00"))
                    v.setTextViewText(R.id.widget_income, "收入 " + p.getString("income", "¥ 0.00"))
                    title(v, p)
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                    v.setOnClickPendingIntent(R.id.widget_grid, open(context, "yujian://records", 3))
                    fillCalendar(context, v, p.getString("cal_ym", "") ?: "", p.getString("cal_exp", "") ?: "", p.getString("cal_inc", "") ?: "")
                }
                R.layout.widget_goals -> {
                    v.setTextViewText(R.id.widget_disposable, p.getString("disposable", "¥ 0.00"))
                    title(v, p)
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://goals", 4))
                    v.setOnClickPendingIntent(R.id.widget_head, open(context, "yujian://home", 1))
                    v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
                    fillGoals(context, v, p.getString("goals", "") ?: "")
                }
                R.layout.widget_goals_small -> {
                    v.setTextViewText(R.id.widget_disposable, p.getString("disposable", "¥ 0.00"))
                    v.setOnClickPendingIntent(R.id.widget_root, open(context, "yujian://goals", 4))
                    fillGoalsSmall(context, v, p.getString("goals", "") ?: "")
                }
                else -> v.setOnClickPendingIntent(R.id.widget_add, open(context, "yujian://chat", 2))
            }
            return v
        }

        /**
         * 铺目标行。App 推的是 JSON 数组 [{e: emoji, n: 名字, p: 0–100, t: 尾巴文案, s: 已攒/目标 一行, d: 攒够了/还清了}]，最多 3 条；
         * 空数组 / 没推过 → 显示「还没有目标」那句 + 记一笔。行是 addView 动态加的（和日历格子一个做法），每行 weight=1 平分高度；
         * 少于 3 条时行里再露一行「已攒 / 目标」、少于 2 条时底部放「记一笔」——别让 4×2 空一大块。
         */
        private fun fillGoals(context: Context, v: RemoteViews, json: String) {
            v.removeAllViews(R.id.widget_goal_list)
            val arr = try { if (json.isEmpty()) JSONArray() else JSONArray(json) } catch (_: Exception) { JSONArray() }
            val n = minOf(arr.length(), 3)
            v.setViewVisibility(R.id.widget_add, if (n <= 1) View.VISIBLE else View.GONE)
            if (n == 0) {
                v.setViewVisibility(R.id.widget_goals_empty, View.VISIBLE)
                v.setViewVisibility(R.id.widget_goal_list, View.GONE)
                return
            }
            v.setViewVisibility(R.id.widget_goals_empty, View.GONE)
            v.setViewVisibility(R.id.widget_goal_list, View.VISIBLE)
            for (i in 0 until n) {
                val o = arr.optJSONObject(i) ?: continue
                // 攒够了 / 还清了的换绿条：RemoteViews 不能换 progressDrawable，用另一份布局最稳
                val row = RemoteViews(context.packageName, if (o.optBoolean("d", false)) R.layout.widget_goal_row_done else R.layout.widget_goal_row)
                row.setTextViewText(R.id.widget_goal_emoji, o.optString("e", "🎯"))
                row.setTextViewText(R.id.widget_goal_name, o.optString("n", ""))
                row.setTextViewText(R.id.widget_goal_tail, o.optString("t", ""))
                val detail = o.optString("s", "")
                if (n < 3 && detail.isNotEmpty()) {
                    row.setTextViewText(R.id.widget_goal_detail, detail)
                    row.setViewVisibility(R.id.widget_goal_detail, View.VISIBLE)
                }
                val pct = o.optInt("p", 0).coerceIn(0, 100)
                row.setProgressBar(R.id.widget_goal_bar, 100, pct, false)
                v.addView(R.id.widget_goal_list, row)
            }
        }

        /** 2×2 目标：最多 2 条，尾巴（还差多少）和百分比放到进度条下面那行，名字独占一行。 */
        private fun fillGoalsSmall(context: Context, v: RemoteViews, json: String) {
            v.removeAllViews(R.id.widget_goal_list)
            val arr = try { if (json.isEmpty()) JSONArray() else JSONArray(json) } catch (_: Exception) { JSONArray() }
            val n = minOf(arr.length(), 2)
            v.setViewVisibility(R.id.widget_goals_empty, if (n == 0) View.VISIBLE else View.GONE)
            v.setViewVisibility(R.id.widget_goal_list, if (n == 0) View.GONE else View.VISIBLE)
            for (i in 0 until n) {
                val o = arr.optJSONObject(i) ?: continue
                val row = RemoteViews(context.packageName, if (o.optBoolean("d", false)) R.layout.widget_goal_row_s_done else R.layout.widget_goal_row_s)
                row.setTextViewText(R.id.widget_goal_emoji, o.optString("e", "🎯"))
                row.setTextViewText(R.id.widget_goal_name, o.optString("n", ""))
                val pct = o.optInt("p", 0).coerceIn(0, 100)
                row.setTextViewText(R.id.widget_goal_detail, "$pct% · " + o.optString("t", ""))
                row.setProgressBar(R.id.widget_goal_bar, 100, pct, false)
                v.addView(R.id.widget_goal_list, row)
            }
        }

        /** 财富称号胶囊（贫困户 / 月光族 / …）：App 没推过或没数据就是空串，整个胶囊藏掉，不留空壳。 */
        private fun title(v: RemoteViews, p: android.content.SharedPreferences) {
            val t = p.getString("title", "") ?: ""
            v.setTextViewText(R.id.widget_title_badge, t)
            v.setViewVisibility(R.id.widget_title_badge, if (t.isEmpty()) View.GONE else View.VISIBLE)
        }

        /**
         * 铺月历格子。App 推的是「哪个月 + 每天支出 / 收入（分，逗号分隔）」；月份对不上（跨月后 App 还没打开过）就只画空格子，
         * 不拿上个月的数字冒充这个月。「今」由这里按当前时间算，配合 updatePeriodMillis 过零点会挪。
         */
        private fun fillCalendar(context: Context, v: RemoteViews, ym: String, expCsv: String, incCsv: String) {
            val cal = Calendar.getInstance()
            val year = cal.get(Calendar.YEAR)
            val month = cal.get(Calendar.MONTH) + 1
            val today = cal.get(Calendar.DAY_OF_MONTH)
            val days = cal.getActualMaximum(Calendar.DAY_OF_MONTH)
            cal.set(Calendar.DAY_OF_MONTH, 1)
            val leading = cal.get(Calendar.DAY_OF_WEEK) - 1 // 周日开头
            val fresh = ym == String.format(java.util.Locale.ROOT, "%04d-%02d", year, month)
            val exp = if (fresh) parseCsv(expCsv, days) else LongArray(days)
            val inc = if (fresh) parseCsv(incCsv, days) else LongArray(days)
            v.setTextViewText(R.id.widget_month, "$month 月")
            v.removeAllViews(R.id.widget_grid)
            val rows = (leading + days + 6) / 7
            for (r in 0 until rows) {
                val row = RemoteViews(context.packageName, R.layout.widget_cal_row)
                for (c in 0 until 7) {
                    val d = r * 7 + c - leading + 1
                    val cell = RemoteViews(context.packageName, R.layout.widget_cal_cell)
                    if (d < 1 || d > days) {
                        cell.setTextViewText(R.id.widget_cell_day, "")
                    } else {
                        val e = exp[d - 1]
                        val i = inc[d - 1]
                        cell.setTextViewText(R.id.widget_cell_day, if (d == today) "今" else d.toString())
                        cell.setTextColor(R.id.widget_cell_day, if (d == today) 0xFF1B6BC7.toInt() else 0xFF1C2430.toInt())
                        if (e > 0) { cell.setTextViewText(R.id.widget_cell_exp, "-" + short(e)); cell.setViewVisibility(R.id.widget_cell_exp, View.VISIBLE) }
                        if (i > 0) { cell.setTextViewText(R.id.widget_cell_inc, "+" + short(i)); cell.setViewVisibility(R.id.widget_cell_inc, View.VISIBLE) }
                        // 有账的天按净值上色（花得多粉红、进得多浅绿），今天再加蓝框；没账的天留白
                        val bg = when {
                            e == 0L && i == 0L -> if (d == today) R.drawable.widget_cell_today_bg else 0
                            i >= e -> if (d == today) R.drawable.widget_cell_today_inc_bg else R.drawable.widget_cell_inc_bg
                            else -> if (d == today) R.drawable.widget_cell_today_exp_bg else R.drawable.widget_cell_exp_bg
                        }
                        if (bg != 0) cell.setInt(R.id.widget_cell, "setBackgroundResource", bg)
                    }
                    row.addView(R.id.widget_cal_row, cell)
                }
                v.addView(R.id.widget_grid, row)
            }
        }

        private fun parseCsv(csv: String, days: Int): LongArray {
            val out = LongArray(days)
            if (csv.isEmpty()) return out
            csv.split(',').forEachIndexed { i, t -> if (i < days) out[i] = t.trim().toLongOrNull() ?: 0L }
            return out
        }

        /** 格子里放不下小数：整数元，上万用 w（和 App 日历页同一规则）。 */
        fun short(minor: Long): String {
            val yuan = minor / 100.0
            if (yuan >= 10000) return String.format(java.util.Locale.ROOT, "%.1fw", yuan / 10000)
            if (yuan >= 100) return String.format(java.util.Locale.ROOT, "%.0f", yuan)
            return if (yuan == Math.rint(yuan)) String.format(java.util.Locale.ROOT, "%.0f", yuan) else String.format(java.util.Locale.ROOT, "%.1f", yuan)
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

class CalendarWidget : SummaryWidget() {
    override val layout: Int get() = R.layout.widget_calendar
}

class GoalsWidget : SummaryWidget() {
    override val layout: Int get() = R.layout.widget_goals
}

class GoalsSmallWidget : SummaryWidget() {
    override val layout: Int get() = R.layout.widget_goals_small
}
