package uk.pixxula.habytes

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
    private val scope = MainScope()

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
                        scope.launch {
                            Widgets.redraw(context)
                            result.success(null)
                        }
                    }
                    "refreshWidgets" -> scope.launch {
                        Widgets.syncNow(context)
                        result.success(null)
                    }
                    "getTimeZone" -> result.success(ZoneId.systemDefault().id)
                    "getDeviceName" -> result.success(
                        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
                            ?: Build.MODEL,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
