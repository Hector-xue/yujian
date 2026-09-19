package com.ivyea.yujian

/**
 * 支付成功页的文字 → 金额 + 商户。纯 Kotlin，不碰 Android，方便单测。
 *
 * 只认「支付成功」字样和一个金额远远不够：微信聊天页里的支付凭证卡片、账单列表、账单详情页也满屏都是「支付成功 + ¥xx」。
 * 所以先按页面结构判「这是不是刚付完款的那一页」（[analyze]），任一条不像就整页拒掉并说明原因（进诊断日志）：
 * - 独立的「支付成功」短行出现两次以上 → 聊天页 / 账单列表（一屏多张凭证卡）；
 * - 「支付成功」不在屏幕上半区 → 不是成功页的标题；
 * - 上半区里像金额的数超过 3 个 → 列表页（成功页只有金额 / 优惠 / 实付；下半区的推荐商品价不算）；
 * - 页面上有早于 10 分钟前的完整日期时间 → 账单详情这类历史页（真成功页要么没时间、要么就是现在）；
 * - 有聊天 / 账单页的标志（多条独立 HH:MM、「按住 说话」「全部账单」…）。
 * 金额取上半区里字最高的那一行（成功页的大字），不再取「全页第一个」。
 */
object PaymentScreenParser {
    /** 一段文字 + 屏幕位置（节点树的 boundsInScreen 或 OCR 的行框；未知时 -1）。 */
    data class Line(val text: String, val top: Int = -1, val height: Int = -1)

    data class Found(val amount: String, val merchant: String?)

    /** [found] 为空时 [reason] 说明拒在哪一条：no_success_text / multi_success / success_low / history / chat_markers / many_amounts / amount_small / no_amount。 */
    data class Result(val found: Found?, val reason: String?)

    const val ARMED_WINDOW_MS = 8_000L

    private val SUCCESS = Regex("支付成功|付款成功|交易成功|支付完成|已支付|付款完成")
    // 金额节点：可带 ¥ / 前导减号（支付宝有的页面写 -13.80）/ 后缀「元」
    private val AMOUNT_NODE = Regex("^[-−]?\\s*[¥￥]?\\s*[-−]?\\s*(\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?)\\s*元?$")
    private val AMOUNT_INLINE = Regex("[¥￥]\\s*(\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?)")
    private val TWO_DECIMALS = Regex(".*\\.\\d{2}$")
    private val LABEL = Regex("^(收款方全称|收款商户|收款方|收款人|商户全称|付款商户|商户|商家|店铺|付款给|向|订单|商品)[:：]?\\s*(.*)$")
    private val NOISE = Regex("支付成功|付款成功|交易成功|支付完成|完成|返回|关闭|查看|账单|详情|再付一笔|去看看|领取|红包|奖励|优惠|会员|积分|分享|立即|开通|余额|零钱|银行卡|花呗|信用卡|扣款|付款方式|支付方式|订单|时间|备注|实付|付款|金额|合计|应付|优惠|抵扣|猜你喜欢|为你推荐|推荐|¥|￥")
    private val CLOCK_LINE = Regex("^\\d{1,2}:\\d{2}$")
    private val CHAT_MARKER = Regex("按住\\s*说话|全部账单|交易记录|账单明细|收支明细")
    private val DATE_TIME = Regex("(20\\d{2})[-/.年]\\s*(\\d{1,2})[-/.月]\\s*(\\d{1,2})日?\\s*[ T]?(\\d{1,2})[:：](\\d{2})")

    private const val HISTORY_MS = 10 * 60_000L
    private const val SUCCESS_TOP_RATIO = 0.45
    private const val AMOUNT_TOP_RATIO = 0.5
    private const val MAX_UPPER_AMOUNTS = 3
    private const val BUSY_PAGE_LINES = 12
    private const val BIG_AMOUNT_RATIO = 1.2

    /** 这段文字算不算「支付成功」提示（服务的诊断日志用它区分「没到成功页」和「到了但没读到金额」）。 */
    fun isSuccessText(t: String): Boolean = SUCCESS.containsMatchIn(t)

    /** 没有位置信息的兼容入口（老单测 / 只有文字的调用方）：按行序做门禁。 */
    fun extract(texts: List<String>, nowMs: Long = System.currentTimeMillis()): Found? =
        analyze(texts.map { Line(it) }, screenHeight = 0, nowMs = nowMs).found

    /**
     * 页面 → 金额 + 商户，或拒绝原因。[screenHeight] ≤ 0 或行没有 top 时退化成按行序判位置。
     * [nowMs] 只用于「页面上的时间是不是历史」。
     */
    fun analyze(lines: List<Line>, screenHeight: Int, nowMs: Long = System.currentTimeMillis()): Result {
        val texts = lines.map { it.text.trim() }
        val successIdx = texts.indices.filter { SUCCESS.containsMatchIn(texts[it]) }
        if (successIdx.isEmpty()) return Result(null, "no_success_text")

        // 独立短行「支付成功」两次以上 = 一屏多张凭证卡 / 列表；正文里夹带的（「您的订单已支付成功」）不算
        val standalone = successIdx.count { texts[it].length <= 6 }
        if (standalone >= 2) return Result(null, "multi_success")

        val hasPos = screenHeight > 0 && lines.any { it.top >= 0 }
        val first = successIdx.first()
        val successLow = if (hasPos && lines[first].top >= 0) lines[first].top >= screenHeight * SUCCESS_TOP_RATIO
        else first > maxOf(3, (texts.size * 0.4).toInt())
        if (successLow) return Result(null, "success_low")

        // 历史页：有早于 10 分钟前的完整日期时间（账单详情的「支付时间 2026-09-18 20:15」）
        for (t in texts) {
            val m = DATE_TIME.find(t) ?: continue
            val at = toEpochMs(m) ?: continue
            if (nowMs - at > HISTORY_MS) return Result(null, "history")
        }

        if (texts.count { CLOCK_LINE.matches(it) } >= 3 || texts.any { CHAT_MARKER.containsMatchIn(it) }) return Result(null, "chat_markers")

        // 强金额候选：带 ¥、或两位小数、或前一行就是 ¥
        data class Cand(val idx: Int, val value: String)
        val cands = ArrayList<Cand>()
        for (i in texts.indices) {
            val t = texts[i]
            val m = AMOUNT_NODE.find(t) ?: continue
            val v = m.groupValues[1]
            val strong = t.contains('¥') || t.contains('￥') || TWO_DECIMALS.matches(v) || (i > 0 && texts[i - 1].let { it == "¥" || it == "￥" })
            if (!strong) continue
            if (v.replace(",", "").toDoubleOrNull()?.let { it > 0 } != true) continue
            cands.add(Cand(i, v.replace(",", "")))
        }
        val upper = if (hasPos) cands.filter { lines[it.idx].top < 0 || lines[it.idx].top < screenHeight * AMOUNT_TOP_RATIO }
        else cands.filter { it.idx <= maxOf(6, (texts.size * AMOUNT_TOP_RATIO).toInt()) }
        if (upper.size > MAX_UPPER_AMOUNTS) return Result(null, "many_amounts")

        // 页面很满时（聊天页里夹一张凭证卡）要求金额确实是大字：至少比行高中位数高两成；稀疏页（成功页本身）不套这条
        val median = if (hasPos && texts.size >= BUSY_PAGE_LINES) lines.map { it.height }.filter { it > 0 }.sorted().let { if (it.isEmpty()) 0 else it[it.size / 2] } else 0
        fun tooSmall(idx: Int): Boolean = median > 0 && lines[idx].height > 0 && lines[idx].height < median * BIG_AMOUNT_RATIO

        var amount: String? = null
        if (upper.isNotEmpty()) {
            // 字最高的那一行（成功页的大字金额）；高度未知时取第一个
            val best = upper.maxByOrNull { lines[it.idx].height }!!
            if (tooSmall(best.idx)) return Result(null, "amount_small")
            amount = best.value
        } else if (cands.isEmpty()) {
            // 没有独立金额节点：只在上半区找行内的「¥xx」（「本次消费¥45.5」）
            val limit = if (hasPos) texts.size else maxOf(6, (texts.size * AMOUNT_TOP_RATIO).toInt())
            for (i in texts.indices) {
                if (i > limit) break
                if (hasPos && lines[i].top >= 0 && lines[i].top >= screenHeight * AMOUNT_TOP_RATIO) continue
                val m = AMOUNT_INLINE.find(texts[i]) ?: continue
                if (tooSmall(i)) return Result(null, "amount_small")
                amount = m.groupValues[1].replace(",", "")
                break
            }
        }
        if (amount == null) return Result(null, "no_amount")

        var merchant: String? = null
        for (i in texts.indices) {
            val m = LABEL.find(texts[i]) ?: continue
            val inline = m.groupValues[2].trim()
            val cand = if (inline.isNotEmpty()) inline else texts.getOrNull(i + 1)?.trim() ?: ""
            if (cand.length in 2..30 && !AMOUNT_NODE.matches(cand) && !NOISE.containsMatchIn(cand)) {
                merchant = cand
                break
            }
        }
        if (merchant == null) {
            // 微信的成功页：商户名就写在「支付成功」下面一行（只看上半区，别把下半区的推荐位标题当商户）
            for (j in first + 1 until minOf(texts.size, first + 5)) {
                val c = texts[j]
                if (hasPos && lines[j].top >= 0 && lines[j].top >= screenHeight * AMOUNT_TOP_RATIO) break
                if (c.length in 2..30 && !AMOUNT_NODE.matches(c) && !NOISE.containsMatchIn(c) && !c.contains(Regex("\\d{4,}"))) {
                    merchant = c
                    break
                }
            }
        }
        return Result(Found(amount, merchant), null)
    }

    /** 页面上的「2026-09-18 20:15」→ 本地时区 epoch ms；月日时分越界返回 null。 */
    private fun toEpochMs(m: MatchResult): Long? {
        val y = m.groupValues[1].toIntOrNull() ?: return null
        val mo = m.groupValues[2].toIntOrNull() ?: return null
        val d = m.groupValues[3].toIntOrNull() ?: return null
        val h = m.groupValues[4].toIntOrNull() ?: return null
        val mi = m.groupValues[5].toIntOrNull() ?: return null
        if (mo !in 1..12 || d !in 1..31 || h !in 0..23 || mi !in 0..59) return null
        return try {
            java.util.Calendar.getInstance().apply {
                clear()
                set(y, mo - 1, d, h, mi, 0)
            }.timeInMillis
        } catch (_: Throwable) { null }
    }
}
