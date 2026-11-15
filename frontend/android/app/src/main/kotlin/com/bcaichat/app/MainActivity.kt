package com.bcaichat.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

/**
 * Push for PushService (lib/services/push_service.dart), channel "bcaichat/push".
 * Firebase is on only when android/app/google-services.json was there at build
 * time; otherwise getToken answers null and BcRealtimeAlertService keeps
 * self-hosted WebSocket alerts running even when closed or screen-off.
 * Tapping a push starts this activity with the message data as extras.
 */
class MainActivity : FlutterActivity() {
    companion object {
        @Volatile
        var activeChannel: MethodChannel? = null

        @Volatile
        var isForegroundResumed: Boolean = false
    }

    private var channel: MethodChannel? = null
    private var openedConversation: String? = null
    private var initialTestUserSlot: Int = 0
    private var initialApiBaseUrl: String? = null

    private fun extractTestUserSlot(src: Intent?): Int {
        if (src == null) return 0
        val asInt = src.getIntExtra("test_user_slot", 0)
        if (asInt in 1..5) return asInt
        val asStr = src.getStringExtra("test_user_slot")?.trim()?.toIntOrNull() ?: 0
        return if (asStr in 1..5) asStr else 0
    }

    private fun extractApiBaseUrl(src: Intent?): String? {
        val raw = src?.getStringExtra("api_base_url")?.trim() ?: return null
        if (raw.startsWith("http://") || raw.startsWith("https://")) {
            return raw.trimEnd('/')
        }
        return null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        openedConversation = intent?.getStringExtra("conversation_id")
        val slot = extractTestUserSlot(intent)
        if (slot in 1..5) {
            initialTestUserSlot = slot
        }
        val apiUrl = extractApiBaseUrl(intent)
        if (apiUrl != null) {
            initialApiBaseUrl = apiUrl
        }
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        isForegroundResumed = true
    }

    override fun onPause() {
        isForegroundResumed = false
        super.onPause()
    }

    override fun onStop() {
        isForegroundResumed = false
        super.onStop()
    }

    override fun onDestroy() {
        isForegroundResumed = false
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bcaichat/push").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getToken" ->
                        if (FirebaseApp.getApps(applicationContext).isEmpty()) {
                            result.success(null)
                        } else {
                            FirebaseMessaging.getInstance().token
                                .addOnSuccessListener { result.success(it) }
                                .addOnFailureListener { result.success(null) }
                        }
                    "takeOpenedConversation" -> {
                        result.success(openedConversation)
                        openedConversation = null
                    }
                    "takeInitialTestUserSlot" -> {
                        val slot = if (initialTestUserSlot in 1..5) initialTestUserSlot else null
                        initialTestUserSlot = 0
                        result.success(slot)
                    }
                    "takeInitialApiBaseUrl" -> {
                        val url = initialApiBaseUrl
                        initialApiBaseUrl = null
                        result.success(url)
                    }
                    "startBackgroundService", "syncBackgroundSettings" -> {
                        result.success(BcRealtimeAlertService.startOrSync(applicationContext))
                    }
                    "stopBackgroundService" -> {
                        result.success(BcRealtimeAlertService.stop(applicationContext))
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val ignoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            pm.isIgnoringBatteryOptimizations(packageName)
                        } else {
                            true
                        }
                        result.success(ignoring)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        val launched = try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                                startActivity(intent)
                            }
                            true
                        } catch (_: Throwable) {
                            false
                        }
                        result.success(launched)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        activeChannel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        isForegroundResumed = false
        if (activeChannel === channel) {
            activeChannel = null
        }
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val apiUrl = extractApiBaseUrl(intent)
        if (apiUrl != null) {
            val ch = channel
            if (ch != null) {
                ch.invokeMethod("switchApiBaseUrl", apiUrl)
            } else {
                initialApiBaseUrl = apiUrl
            }
        }
        val slot = extractTestUserSlot(intent)
        if (slot in 1..5) {
            val ch = channel
            if (ch != null) {
                ch.invokeMethod("switchTestUserSlot", slot)
            } else {
                initialTestUserSlot = slot
            }
        }
        val id = intent.getStringExtra("conversation_id")
        if (id != null && id.isNotEmpty()) {
            val ch = channel
            if (ch != null) {
                ch.invokeMethod("openConversation", id)
            } else {
                openedConversation = id
            }
        }
    }
}

/**
 * Receives FCM token rotations even when the app is closed and syncs the new
 * token to the backend (/api/devices) immediately without waiting for the next
 * app launch. When the Flutter engine is alive, forwards onNewToken over
 * MethodChannel("bcaichat/push") as well.
 */
class BcPushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        if (token.isEmpty()) return
        val ch = MainActivity.activeChannel
        if (ch != null) {
            Handler(Looper.getMainLooper()).post {
                ch.invokeMethod("onNewToken", token)
            }
            return
        }
        val appContext = applicationContext
        Thread {
            sendTokenToBackend(appContext, token)
        }.start()
    }

    private fun sendTokenToBackend(context: Context, token: String) {
        try {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE
            )
            val jwt = prefs.getString("flutter.bcaichat_jwt_token", null)
            val deviceId = prefs.getString("flutter.bcaichat_device_id", null)
            if (jwt.isNullOrEmpty() || deviceId.isNullOrEmpty()) return
            val apiBase = prefs.getString("flutter.bcaichat_effective_api_base", null)
                ?: prefs.getString("flutter.bcaichat_api_base", null)
                ?: "http://10.0.2.2:8096"
            val popup = prefs.getBoolean("flutter.bcaichat_alert_popup", true)
            val sound = prefs.getBoolean("flutter.bcaichat_alert_sound", true)
            val sounds = JSONObject()
                .put("normal", prefs.getString("flutter.bcaichat_alert_sound_normal", "ting") ?: "ting")
                .put("urgent", prefs.getString("flutter.bcaichat_alert_sound_urgent", "urgent") ?: "urgent")
                .put("ai", prefs.getString("flutter.bcaichat_alert_sound_ai", "robot") ?: "robot")
            val body = JSONObject()
                .put("device_id", deviceId)
                .put("token", token)
                .put("platform", "android")
                .put("popup", popup)
                .put("sound", sound)
                .put("sounds", sounds)
                .toString()
                .toByteArray(Charsets.UTF_8)

            val conn = (URL("$apiBase/api/devices").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 5000
                readTimeout = 5000
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("Authorization", "Bearer $jwt")
            }
            conn.outputStream.use { it.write(body) }
            conn.responseCode
            conn.disconnect()
        } catch (_: Exception) {
        }
    }
}
