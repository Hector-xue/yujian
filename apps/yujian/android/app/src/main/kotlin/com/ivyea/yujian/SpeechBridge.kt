package com.ivyea.yujian

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 语音输入的第二条路：系统「语音识别」Activity（RecognizerIntent）。
 * SpeechRecognizer 在不少国产 ROM 上要么没有、要么 ERROR_AUDIO，但系统/输入法/厂商助手往往还提供这个弹窗式识别。
 */
object SpeechBridge {
    private const val CHANNEL = "yujian/speech"
    private const val REQ = 0x5EEC
    private var pending: MethodChannel.Result? = null

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "intentAvailable" -> result.success(intent().resolveActivity(activity.packageManager) != null)
                "recognizeIntent" -> {
                    if (pending != null) { result.error("busy", "recognition already running", null); return@setMethodCallHandler }
                    val i = intent()
                    if (i.resolveActivity(activity.packageManager) == null) { result.success(null); return@setMethodCallHandler }
                    pending = result
                    try {
                        activity.startActivityForResult(i, REQ)
                    } catch (e: Exception) {
                        pending = null
                        result.error("launch", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun intent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
        putExtra(RecognizerIntent.EXTRA_PROMPT, "说一句要记的账")
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
    }

    /** MainActivity.onActivityResult 转发过来；返回 true 表示吃掉了。 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ) return false
        val r = pending ?: return true
        pending = null
        val text = if (resultCode == Activity.RESULT_OK) data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull() else null
        r.success(text)
        return true
    }
}
