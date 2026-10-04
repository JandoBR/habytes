package uk.pixxula.habytes

import android.content.Context
import androidx.glance.appwidget.updateAll
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.time.LocalDate
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext

/** What the app, the widget, the worker and the NFC activity share in this process. */
object Widgets {
    private const val FLUSH_WORK = "habitd-flush"
    private const val REFRESH_WORK = "habitd-refresh"

    @Volatile private var instance: Pair<PrefsStore, HabitSync>? = null

    private fun instance(context: Context): Pair<PrefsStore, HabitSync> =
        instance ?: synchronized(this) {
            instance ?: PrefsStore(context).let { store ->
                val sync = HabitSync(
                    store = store,
                    api = HttpApi(),
                    today = LocalDate::now,
                    nowMillis = System::currentTimeMillis,
                    newOpId = { UUID.randomUUID().toString() },
                )
                (store to sync).also { instance = it }
            }
        }

    fun store(context: Context): PrefsStore = instance(context).first

    fun sync(context: Context): HabitSync = instance(context).second

    /** Bumped on every change, so a widget that is already composed redraws. */
    val version = MutableStateFlow(0)

    suspend fun redraw(context: Context) {
        version.value++
        HabitWidget().updateAll(context)
    }

    /** Flushes the outbox, refreshes the cache and redraws. */
    suspend fun syncNow(context: Context): SyncResult {
        val result = withContext(Dispatchers.IO) { sync(context).sync() }
        redraw(context)
        return result
    }

    private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    /** Sends the outbox as soon as there is a connection, retrying until it works. */
    fun scheduleFlush(context: Context) {
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(online)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        // Replacing a running flush is safe: operations are idempotent on the server.
        WorkManager.getInstance(context)
            .enqueueUniqueWork(FLUSH_WORK, ExistingWorkPolicy.REPLACE, request)
    }

    fun scheduleRefresh(context: Context) {
        val request = PeriodicWorkRequestBuilder<SyncWorker>(30, TimeUnit.MINUTES)
            .setConstraints(online)
            .build()
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(REFRESH_WORK, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    fun cancelFlush(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(FLUSH_WORK)
    }
}

class SyncWorker(context: Context, parameters: WorkerParameters) :
    CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result =
        when (Widgets.syncNow(applicationContext)) {
            SyncResult.RETRY -> Result.retry()
            else -> Result.success()
        }
}
