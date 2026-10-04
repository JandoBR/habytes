package uk.pixxula.habytes

import android.content.Context
import android.content.SharedPreferences

/**
 * The native store: credentials, cache and outbox in app-private preferences
 * (excluded from backups in the manifest). Kotlin owns it so the widget works
 * without a Flutter engine.
 */
class PrefsStore(context: Context) : StateStore {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("habitd", Context.MODE_PRIVATE)

    // Writes are committed before returning so a tap survives the process being killed.
    private fun write(edit: SharedPreferences.Editor.() -> Unit) {
        prefs.edit().apply(edit).commit()
    }

    override var credentials: Credentials?
        get() {
            val serverUrl = prefs.getString("server_url", null) ?: return null
            val token = prefs.getString("token", null) ?: return null
            return Credentials(serverUrl, token)
        }
        set(value) = write {
            putString("server_url", value?.serverUrl)
            putString("token", value?.token)
        }

    override var signedOut: Boolean
        get() = prefs.getBoolean("signed_out", false)
        set(value) = write { putBoolean("signed_out", value) }

    private var cachedCache: Cache? =
        prefs.getString("cache", null)?.let { runCatching { cacheFromJson(it) }.getOrNull() }

    override var cache: Cache?
        get() = cachedCache
        set(value) {
            cachedCache = value
            write { putString("cache", value?.toJson()) }
        }

    private var cachedOutbox: List<Op> =
        prefs.getString("outbox", null)?.let { runCatching { outboxFromJson(it) }.getOrNull() }
            ?: emptyList()

    override var outbox: List<Op>
        get() = cachedOutbox
        set(value) {
            cachedOutbox = value
            write { putString("outbox", value.toJson()) }
        }

    // Only matters for a few seconds, so it is not worth persisting.
    override var lastScan: Pair<String, Long>? = null
}
