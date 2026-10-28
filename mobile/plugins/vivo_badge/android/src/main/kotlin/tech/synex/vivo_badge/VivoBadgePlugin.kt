package tech.synex.vivo_badge

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** The app icon's number on Vivo / iQOO phones: their launcher's own broadcast (see README.md). */
class VivoBadgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "tech.synex/vivo_badge")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "set") return result.notImplemented()
        val brand = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        if (!brand.contains("vivo") && !brand.contains("iqoo")) return result.success(false)
        try {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.component?.className
            val intent = Intent("launcher.action.CHANGE_APPLICATION_NOTIFICATION_NUM")
                .putExtra("packageName", context.packageName)
                .putExtra("className", launch)
                .putExtra("notificationNum", maxOf(0, call.argument<Int>("count") ?: 0))
                .addFlags(0x01000000) // FLAG_RECEIVER_INCLUDE_BACKGROUND: the launcher's receiver is declared in its manifest
            context.sendBroadcast(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("badge", e.message, null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
