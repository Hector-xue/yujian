package com.ivyea.yujian

/** 支付成功页的文字 → 金额 + 商户。纯 Kotlin，不碰 Android，方便单测。 */
object PaymentScreenParser {
    data class Found(val amount: String, val merchant: String?)

    private val SUCCESS = Regex("支付成功|付款成功|交易成功|支付完成|已支付|付款完成")
    // 金额节点：可带 ¥ / 前导减号（支付宝有的页面写 -13.80）/ 后缀「元」
    private val AMOUNT_NODE = Regex("^[-−]?\\s*[¥￥]?\\s*[-−]?\\s*(\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?)\\s*元?$")
    private val AMOUNT_INLINE = Regex("[¥￥]\\s*(\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?)")
    private val LABEL = Regex("^(收款方|收款商户|收款人|商户|商户全称|商家|店铺|付款给|向|收款方全称|订单|商品|付款商户)[:：]?\\s*(.*)$")
    private val NOISE = Regex("支付成功|付款成功|交易成功|支付完成|完成|返回|关闭|查看|账单|详情|再付一笔|去看看|领取|红包|奖励|优惠|会员|积分|分享|立即|开通|余额|零钱|银行卡|花呗|信用卡|扣款|付款方式|支付方式|订单|时间|备注|实付|付款|金额|合计|应付|优惠|抵扣|¥|￥")

    /** 这段文字算不算「支付成功」提示（服务的诊断日志用它区分「没到成功页」和「到了但没读到金额」）。 */
    fun isSuccessText(t: String): Boolean = SUCCESS.containsMatchIn(t)

    /** 页面文字 → 金额 + 商户。没有「支付成功」字样或没有像样的金额就返回 null。 */
    fun extract(texts: List<String>): Found? {
        val successAt = texts.indexOfFirst { SUCCESS.containsMatchIn(it) }
        if (successAt < 0) return null
        var amount: String? = null
        // 先找独立的金额节点：带 ¥、或带两位小数、或前一个节点就是 ¥
        for (i in texts.indices) {
            val t = texts[i]
            val m = AMOUNT_NODE.find(t) ?: continue
            val v = m.groupValues[1]
            val strong = t.contains('¥') || t.contains('￥') || v.matches(Regex(".*\\.\\d{2}$")) || (i > 0 && texts[i - 1].trim().let { it == "¥" || it == "￥" })
            if (!strong) continue
            if (v.replace(",", "").toDoubleOrNull()?.let { it > 0 } != true) continue
            amount = v.replace(",", "")
            break
        }
        if (amount == null) {
            val m = texts.asSequence().mapNotNull { AMOUNT_INLINE.find(it) }.firstOrNull() ?: return null
            amount = m.groupValues[1].replace(",", "")
        }
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
            // 微信的成功页：商户名就写在「支付成功」下面一行
            for (j in successAt + 1 until minOf(texts.size, successAt + 5)) {
                val c = texts[j].trim()
                if (c.length in 2..30 && !AMOUNT_NODE.matches(c) && !NOISE.containsMatchIn(c) && !c.contains(Regex("\\d{4,}"))) {
                    merchant = c
                    break
                }
            }
        }
        return Found(amount, merchant)
    }
}
