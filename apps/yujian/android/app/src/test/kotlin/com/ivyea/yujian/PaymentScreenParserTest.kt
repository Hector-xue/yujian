package com.ivyea.yujian

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 支付页识别的纯逻辑：每条拒绝规则一个用例，外加微信 / 支付宝成功页的正常路径。JVM 单测，不需要真机。 */
class PaymentScreenParserTest {
    private val now = java.util.Calendar.getInstance().apply { clear(); set(2026, 8, 26, 14, 0, 0) }.timeInMillis
    private fun L(vararg t: String) = t.map { PaymentScreenParser.Line(it) }

    @Test fun wechatSuccessPage() {
        val r = PaymentScreenParser.analyze(L("支付成功", "杨国福麻辣烫", "¥13.80", "支付方式", "零钱", "完成"), screenHeight = 0, nowMs = now)
        assertEquals("13.80", r.found?.amount)
        assertEquals("杨国福麻辣烫", r.found?.merchant)
    }

    @Test fun alipayLabelMerchantAndNegativeAmount() {
        val r = PaymentScreenParser.analyze(L("支付成功", "-9.00", "收款方 肉夹馍", "付款方式 余额宝"), screenHeight = 0, nowMs = now)
        assertEquals("9.00", r.found?.amount)
        assertEquals("肉夹馍", r.found?.merchant)
    }

    @Test fun noSuccessText() = assertEquals("no_success_text", PaymentScreenParser.analyze(L("订单详情", "¥13.80"), 0, now).reason)

    @Test fun multipleVoucherCardsAreAChatOrList() =
        assertEquals("multi_success", PaymentScreenParser.analyze(L("张三", "支付成功", "¥13.80", "李四", "支付成功", "¥9.00"), 0, now).reason)

    @Test fun successTextLowOnScreen() {
        val lines = listOf(PaymentScreenParser.Line("聊天", 100, 30), PaymentScreenParser.Line("¥13.80", 200, 30), PaymentScreenParser.Line("支付成功", 1500, 30))
        assertEquals("success_low", PaymentScreenParser.analyze(lines, screenHeight = 2000, nowMs = now).reason)
    }

    @Test fun historyPageWithOldTimestamp() =
        assertEquals("history", PaymentScreenParser.analyze(L("支付成功", "¥13.80", "支付时间 2026-09-18 20:15"), 0, now).reason)

    @Test fun chatMarkers() =
        assertEquals("chat_markers", PaymentScreenParser.analyze(L("支付成功", "¥13.80", "按住 说话"), 0, now).reason)

    @Test fun tooManyAmountsIsAList() =
        assertEquals("many_amounts", PaymentScreenParser.analyze(L("支付成功", "¥1.00", "¥2.00", "¥3.00", "¥4.00"), 0, now).reason)

    @Test fun noAmount() = assertEquals("no_amount", PaymentScreenParser.analyze(L("支付成功", "瑞幸咖啡", "完成"), 0, now).reason)

    @Test fun inlineAmountFallback() {
        val r = PaymentScreenParser.analyze(L("支付成功", "本次消费¥45.5"), 0, now)
        assertEquals("45.5", r.found?.amount)
        assertNull(r.reason)
    }

    @Test fun recentTimestampIsNotHistory() {
        // 成功页上写着刚刚的时间（5 分钟前）不算历史页
        val r = PaymentScreenParser.analyze(L("支付成功", "¥13.80", "2026-09-26 13:55"), 0, now)
        assertEquals("13.80", r.found?.amount)
    }
}
