package com.fanfq.flutter_smsforward

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class SmsForwardApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val flutterEngine = FlutterEngine(this)
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
    }

    companion object {
        const val ENGINE_ID = "sms_forward_engine"
    }
}
