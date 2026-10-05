package uk.pixxula.habytes

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Reminders: a notification at a habit's chosen time of day if it is not done
 * yet. One alarm per habit, set again each time it goes off and whenever the
 * cache is refreshed.
 */
object Reminders {
    private const val CHANNEL = "reminders"
    private const val PREFS = "habitd-reminders"
    private const val SCHEDULED = "scheduled"
    const val EXTRA_HABIT = "habit_id"

    /** Sets an alarm for every habit with a reminder, and drops the ones no longer wanted. */
    fun schedule(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val sync = Widgets.sync(context)
        val habits = if (sync.signedIn) sync.snapshot()?.habits.orEmpty() else emptyList()
        val wanted = habits.filter { it.reminderTime != null }

        val before = prefs.getStringSet(SCHEDULED, emptySet()).orEmpty()
        for (id in before - wanted.map { it.id }.toSet()) {
            alarms.cancel(alarmIntent(context, id))
        }
        val now = LocalDateTime.now()
        for (habit in wanted) {
            val at = nextReminder(now, habit.reminderTime!!)
            val millis = at.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
            // Not exact to the second, which needs no special permission.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, alarmIntent(context, habit.id))
        }
        prefs.edit().putStringSet(SCHEDULED, wanted.map { it.id }.toSet()).apply()
    }

    private fun alarmIntent(context: Context, habitId: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            habitId.hashCode(),
            Intent(context, ReminderReceiver::class.java).putExtra(EXTRA_HABIT, habitId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** Shows the reminder for [habit], with a button that logs it. */
    fun notify(context: Context, habit: Habit) {
        val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) return

        val manager = NotificationManagerCompat.from(context)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Reminders", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "Habits that are not done yet at their reminder time" },
        )
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val log = PendingIntent.getBroadcast(
            context,
            habit.id.hashCode(),
            Intent(context, ReminderActionReceiver::class.java).putExtra(EXTRA_HABIT, habit.id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(habit.name)
            .setContentText(habit.progress.ifEmpty { "Not done yet today" })
            .setContentIntent(open)
            .setAutoCancel(true)
            .addAction(0, if (habit.kind == Kind.BOOLEAN) "Done" else "Add 1", log)
            .build()
        manager.notify(habit.id.hashCode(), notification)
    }

    fun dismiss(context: Context, habitId: String) {
        NotificationManagerCompat.from(context).cancel(habitId.hashCode())
    }
}

/** A reminder's alarm went off: check the habit and say so if it is still open. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val habitId = intent.getStringExtra(Reminders.EXTRA_HABIT) ?: return
        val app = context.applicationContext
        val pending = goAsync()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                // It may have been done elsewhere: ask the server, but not for long.
                withTimeoutOrNull(8_000) { Widgets.syncNow(app) }
                val habit = withContext(Dispatchers.IO) { Widgets.sync(app).snapshot()?.habit(habitId) }
                if (habit != null && habit.needsReminder(LocalDate.now())) {
                    Reminders.notify(app, habit)
                }
                // Tomorrow's.
                Reminders.schedule(app)
            } finally {
                pending.finish()
            }
        }
    }
}

/** The button on a reminder: logs the habit like a widget tap. */
class ReminderActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val habitId = intent.getStringExtra(Reminders.EXTRA_HABIT) ?: return
        val app = context.applicationContext
        val pending = goAsync()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                withContext(Dispatchers.IO) {
                    val sync = Widgets.sync(app)
                    val habit = sync.snapshot()?.habit(habitId)
                    // A boolean that is already checked must not be toggled back off.
                    if (habit != null && !(habit.kind == Kind.BOOLEAN && habit.checkedToday)) {
                        sync.tap(habitId)
                    }
                }
                Reminders.dismiss(app, habitId)
                Widgets.redraw(app)
                Widgets.scheduleFlush(app)
            } finally {
                pending.finish()
            }
        }
    }
}

/** Alarms do not survive a restart. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) Reminders.schedule(context.applicationContext)
    }
}
