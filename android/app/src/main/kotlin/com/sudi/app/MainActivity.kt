package com.sudi.app

import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The trusted clock (lib/src/core/clock/trusted_clock.dart): time since
        // boot, which never jumps when somebody changes the phone's date and
        // keeps counting in deep sleep, plus which boot this is -- so a pin to
        // the server's time is only trusted until the phone restarts.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sudi/clock")
            .setMethodCallHandler { call, result ->
                if (call.method == "read") {
                    val boot = if (Build.VERSION.SDK_INT >= 24) {
                        Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT, -1)
                    } else {
                        -1
                    }
                    result.success(mapOf("elapsed" to SystemClock.elapsedRealtime(), "boot" to boot))
                } else {
                    result.notImplemented()
                }
            }
    }
}
