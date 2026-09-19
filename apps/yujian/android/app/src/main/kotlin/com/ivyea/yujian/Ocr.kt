package com.ivyea.yujian

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions

/**
 * 本机 OCR（ML Kit 中文模型，打进 APK，离线；不依赖 Google 服务）。
 * 截图自动记账的「仅本地」档靠它：图不出手机，读出文字交给本地规则解析。
 * 返回按从上到下排好的文字行，每行带位置和高度（字大的通常是金额）。
 */
object Ocr {
    private val recognizer by lazy { TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build()) }

    fun recognize(ctx: Context, uri: String, cb: (List<Map<String, Any>>?, String?) -> Unit) {
        val image = try {
            InputImage.fromFilePath(ctx, Uri.parse(uri))
        } catch (e: Exception) {
            cb(null, "read_failed: $e"); return
        }
        process(image, cb)
    }

    /** 内存里的位图（支付页识别截屏用）：识别完就丢，不落盘。 */
    fun recognize(bitmap: Bitmap, cb: (List<Map<String, Any>>?, String?) -> Unit) = process(InputImage.fromBitmap(bitmap, 0), cb)

    private fun process(image: InputImage, cb: (List<Map<String, Any>>?, String?) -> Unit) {
        recognizer.process(image)
            .addOnSuccessListener { vt ->
                val lines = ArrayList<Map<String, Any>>()
                for (b in vt.textBlocks) for (l in b.lines) {
                    val box = l.boundingBox
                    lines.add(mapOf(
                        "text" to l.text,
                        "top" to (box?.top ?: 0),
                        "left" to (box?.left ?: 0),
                        "height" to (box?.height() ?: 0),
                        "width" to (box?.width() ?: 0),
                    ))
                }
                lines.sortWith(compareBy({ it["top"] as Int }, { it["left"] as Int }))
                cb(lines, null)
            }
            .addOnFailureListener { e -> cb(null, "ocr_failed: $e") }
    }
}
