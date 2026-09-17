package com.ivyea.yujian

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NotificationBridge.register(applicationContext, flutterEngine)
        ShareBridge.register(flutterEngine)
        SpeechBridge.register(this, flutterEngine)
        WidgetBridge.register(applicationContext, flutterEngine)
        UpdateBridge.register(applicationContext, flutterEngine)
        ShareBridge.handle(this, intent)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (SpeechBridge.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        ShareBridge.handle(this, intent)
    }
}
