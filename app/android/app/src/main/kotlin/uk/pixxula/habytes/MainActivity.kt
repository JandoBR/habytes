package uk.pixxula.habytes

import android.Manifest
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.time.ZoneId
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    companion object {
        /** A screen of the app to open, e.g. `/habits/new`. */
        const val EXTRA_ROUTE = "route"
    }

    private val scope = MainScope()

    /** The screen asked for by whoever launched the app, until Dart collects it. */
    private var launchRoute: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        launchRoute = intent?.getStringExtra(EXTRA_ROUTE)
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_ROUTE)?.let { launchRoute = it }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = Widgets.store(this)
        val context = applicationContext

        // The Dart side of the native store: see `lib/platform/native.dart`.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "habitd/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveCredentials" -> {
                        val credentials = Credentials(
                            call.argument<String>("serverUrl")!!,
                            call.argument<String>("token")!!,
                        )
                        synchronized(store) {
                            // Another account's habits must not show while the first fetch runs.
                            if (store.credentials != credentials) store.cache = null
                            store.credentials = credentials
                            store.signedOut = false
                        }
                        Widgets.scheduleRefresh(context)
                        result.success(null)
                    }
                    "getCredentials" -> result.success(
                        synchronized(store) { store.credentials }
                            ?.let { mapOf("serverUrl" to it.serverUrl, "token" to it.token) },
                    )
                    "clearCredentials" -> {
                        synchronized(store) {
                            store.credentials = null
                            store.signedOut = false
                            store.cache = null
                            store.outbox = emptyList()
                        }
                        Widgets.cancelFlush(context)
                        Reminders.schedule(context)
                        scope.launch {
                            Widgets.redraw(context)
                            result.success(null)
                        }
                    }
                    "refreshWidgets" -> scope.launch {
                        Widgets.syncNow(context)
                        result.success(null)
                    }
                    // Reminders are notifications, which Android 13 and later ask about.
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                        }
                        result.success(null)
                    }
                    "takeLaunchRoute" -> {
                        result.success(launchRoute)
                        launchRoute = null
                    }
                    "getTimeZone" -> result.success(ZoneId.systemDefault().id)
                    "getDeviceName" -> result.success(deviceName())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * What the user calls this device, for the list of signed-in devices. Some
     * makers only put a model code in the usual place, so the Bluetooth name is
     * tried first.
     */
    private fun deviceName(): String {
        val candidates = listOf(
            runCatching { Settings.Secure.getString(contentResolver, "bluetooth_name") }.getOrNull(),
            runCatching { Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) }
                .getOrNull(),
        )
        return candidates.firstOrNull { !it.isNullOrBlank() && it != Build.MODEL }
            ?: listOf(Build.MANUFACTURER, Build.MODEL).joinToString(" ") { it.orEmpty() }.trim()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
