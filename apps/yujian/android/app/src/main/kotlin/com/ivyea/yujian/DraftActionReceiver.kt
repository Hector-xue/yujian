package com.ivyea.yujian

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 记账通知上的按钮（确认 / 忽略 / 撤销）。只收自己发的（exported=false），活交给 [DraftNotifier.onAction]。 */
class DraftActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != DraftNotifier.ACTION) return
        val op = intent.getStringExtra("op") ?: return
        val tag = intent.getStringExtra("tag") ?: return
        val target = intent.getStringExtra("target") ?: tag
        DraftNotifier.onAction(ctx.applicationContext, op, tag, target)
    }
}
