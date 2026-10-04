package uk.pixxula.habytes

import java.io.IOException
import java.time.LocalDate

/** Where the credentials, the cache and the outbox are kept. */
interface StateStore {
    var credentials: Credentials?

    /** The server stopped accepting the token. Cleared by the next sign-in. */
    var signedOut: Boolean
    var cache: Cache?
    var outbox: List<Op>

    /** The last counter habit logged by an NFC scan, and when (milliseconds). */
    var lastScan: Pair<String, Long>?
}

class ApiResponse(val status: Int, val body: String)

/** The few requests the widget makes. Both throw [IOException] when the server is unreachable. */
interface Api {
    /** Sends one operation and returns the HTTP status. */
    fun send(credentials: Credentials, op: Op): Int

    /** `GET /today` for [date]. */
    fun today(credentials: Credentials, date: LocalDate): ApiResponse
}

enum class SyncResult {
    /** The outbox is empty and the cache is fresh. */
    DONE,

    /** The server could not be reached or asked to wait; try again later. */
    RETRY,
    SIGNED_OUT,
}

sealed interface ScanResult {
    data class Logged(val habit: Habit) : ScanResult

    /** A repeated scan of a counter, within [SCAN_DEBOUNCE_MS] of the last one. */
    data class Ignored(val habit: Habit) : ScanResult
    data object UnknownHabit : ScanResult
    data object SignedOut : ScanResult
}

const val SCAN_DEBOUNCE_MS = 5_000L

/**
 * Taps, NFC scans and the exchange with the server. Changes are applied to
 * the cache at once and queued in the outbox; [sync] delivers them later.
 */
class HabitSync(
    private val store: StateStore,
    private val api: Api,
    private val today: () -> LocalDate,
    private val nowMillis: () -> Long,
    private val newOpId: () -> String,
) {
    /** Only one [sync] talks to the server at a time. */
    private val syncLock = Any()

    val signedIn: Boolean
        get() = synchronized(store) { store.credentials != null && !store.signedOut }

    /** The cache as of today, redrawn from what is stored if the day has changed. */
    fun snapshot(): Cache? = synchronized(store) { store.cache?.rolledTo(today()) }

    /** A widget tap: toggles a boolean habit today, adds 1 to a counter. */
    fun tap(habitId: String): Habit? = synchronized(store) {
        val habit = snapshot()?.habit(habitId) ?: return null
        when (habit.kind) {
            Kind.BOOLEAN -> queue(Op.Set(newOpId(), habitId, today(), if (habit.checkedToday) 0 else 1))
            Kind.COUNTER -> queue(Op.Increment(newOpId(), habitId, today(), 1))
        }
    }

    /**
     * An NFC scan: checks a boolean habit today (never unchecks), adds 1 to a
     * counter. Refreshes once if the habit is not in the cache.
     */
    fun scan(habitId: String): ScanResult {
        if (!signedIn) return ScanResult.SignedOut
        if (snapshot()?.habit(habitId) == null) {
            if (sync() == SyncResult.SIGNED_OUT) return ScanResult.SignedOut
        }
        return synchronized(store) {
            val habit = snapshot()?.habit(habitId) ?: return ScanResult.UnknownHabit
            when (habit.kind) {
                Kind.BOOLEAN -> ScanResult.Logged(queue(Op.Set(newOpId(), habitId, today(), 1)))
                Kind.COUNTER -> {
                    val now = nowMillis()
                    val last = store.lastScan
                    if (last != null && last.first == habitId && now - last.second in 0 until SCAN_DEBOUNCE_MS) {
                        return ScanResult.Ignored(habit)
                    }
                    store.lastScan = habitId to now
                    ScanResult.Logged(queue(Op.Increment(newOpId(), habitId, today(), 1)))
                }
            }
        }
    }

    /** Applies [op] to the cache, adds it to the outbox, and returns the habit as it is now. */
    private fun queue(op: Op): Habit {
        val cache = store.cache!!.rolledTo(today()).applying(op)
        store.cache = cache
        store.outbox = store.outbox + op
        return cache.habit(op.habitId)!!
    }

    /** Sends the outbox in order, then replaces the cache with the server's view of today. */
    fun sync(): SyncResult = synchronized(syncLock) {
        val credentials = synchronized(store) { store.credentials } ?: return SyncResult.SIGNED_OUT

        while (true) {
            val op = synchronized(store) { store.outbox.firstOrNull() } ?: break
            val status = try {
                api.send(credentials, op)
            } catch (_: IOException) {
                return SyncResult.RETRY
            }
            when {
                status == 401 -> return signedOut(credentials)
                status == 408 || status == 429 || status >= 500 -> return SyncResult.RETRY
                // Applied, or it never can be: the habit is gone or the request is invalid.
                else -> synchronized(store) {
                    if (store.credentials == credentials) {
                        store.outbox = store.outbox.filterNot { it.opId == op.opId }
                    }
                }
            }
        }

        val response = try {
            api.today(credentials, today())
        } catch (_: IOException) {
            return SyncResult.RETRY
        }
        if (response.status == 401) return signedOut(credentials)
        if (response.status !in 200..299) return SyncResult.RETRY
        val fetched = try {
            cacheFromJson(response.body, fetchedAt = nowMillis() / 1000)
        } catch (_: Exception) {
            // Not habitd's answer (a proxy's error page, say).
            return SyncResult.RETRY
        }
        synchronized(store) {
            // Unless the user signed out or switched accounts in the meantime.
            if (store.credentials == credentials) {
                // Taps made while the request was in flight are not in the answer yet.
                store.cache = store.outbox.fold(fetched) { cache, op -> cache.applying(op) }
            }
        }
        SyncResult.DONE
    }

    private fun signedOut(credentials: Credentials): SyncResult {
        synchronized(store) {
            if (store.credentials == credentials) store.signedOut = true
        }
        return SyncResult.SIGNED_OUT
    }
}
