package uk.pixxula.habytes

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Receives a scanned habit tag (`habitd://habit/<id>`), logs the habit through
 * the same outbox the widget uses, and finishes. It has no UI of its own.
 */
class NfcScanActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val habitId = intent?.data
            ?.takeIf { it.scheme == "habitd" && it.host == "habit" }
            ?.lastPathSegment
        if (habitId == null) {
            finish()
            return
        }
        val context = applicationContext
        // Outlives the activity on purpose: the scan must be recorded even if
        // this window is already gone.
        CoroutineScope(Dispatchers.Main).launch {
            val result = withContext(Dispatchers.IO) { Widgets.sync(context).scan(habitId) }
            when (result) {
                ScanResult.SignedOut ->
                    startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                ScanResult.UnknownHabit -> toast("Unknown habit")
                is ScanResult.Ignored -> toast(describe(result.habit))
                is ScanResult.Logged -> {
                    vibrate()
                    toast(describe(result.habit))
                    Widgets.redraw(context)
                    Widgets.scheduleFlush(context)
                }
            }
            finish()
        }
    }

    /** `Drink water 4/8`, `Gym 2/3 this week`, `Meditate ✓`. */
    private fun describe(habit: Habit): String =
        "${habit.name} ${habit.progress.ifEmpty { "✓" }}"

    private fun toast(text: String) {
        Toast.makeText(applicationContext, text, Toast.LENGTH_SHORT).show()
    }

    private fun vibrate() {
        @Suppress("DEPRECATION")
        val vibrator = getSystemService(VIBRATOR_SERVICE) as? Vibrator ?: return
        vibrator.vibrate(VibrationEffect.createOneShot(60, VibrationEffect.DEFAULT_AMPLITUDE))
    }
}
