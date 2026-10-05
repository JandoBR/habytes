package uk.pixxula.habytes

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.EditText
import android.widget.RadioGroup
import android.widget.TextView
import android.widget.Toast
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The widget's `+`: a small sheet over the home screen that creates a habit
 * without opening the app. It covers the common case (a name, yes/no or a
 * daily counter); everything else is one tap away in the app's own editor.
 */
class QuickAddActivity : Activity() {
    private val scope = CoroutineScope(Dispatchers.Main)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Widgets.sync(this).signedIn) {
            openApp(route = null)
            return
        }
        setContentView(R.layout.quick_add)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE)

        val name = findViewById<EditText>(R.id.name)
        val kind = findViewById<RadioGroup>(R.id.kind)
        val counterFields = findViewById<View>(R.id.counter_fields)
        val goal = findViewById<EditText>(R.id.goal)
        val unit = findViewById<EditText>(R.id.unit)
        val add = findViewById<TextView>(R.id.add)

        kind.setOnCheckedChangeListener { _, checked ->
            counterFields.visibility = if (checked == R.id.kind_counter) View.VISIBLE else View.GONE
        }
        findViewById<View>(R.id.cancel).setOnClickListener { finish() }
        findViewById<View>(R.id.more).setOnClickListener { openApp(route = "/habits/new") }
        add.setOnClickListener {
            val title = name.text.toString().trim()
            if (title.isEmpty()) {
                name.error = "Give the habit a name"
                return@setOnClickListener
            }
            val counter = kind.checkedRadioButtonId == R.id.kind_counter
            val body = JSONObject()
                .put("name", title)
                .put("kind", if (counter) "counter" else "boolean")
                .put("schedule", "daily")
            if (counter) {
                body.put("goal", goal.text.toString().toIntOrNull()?.coerceAtLeast(1) ?: 1)
                body.put("unit", unit.text.toString().trim())
            }
            add.isEnabled = false
            create(body) { add.isEnabled = true }
        }
        name.requestFocus()
    }

    private fun create(body: JSONObject, onFailure: () -> Unit) {
        val app = applicationContext
        scope.launch {
            val credentials = Widgets.store(app).credentials
            val response = withContext(Dispatchers.IO) {
                try {
                    credentials?.let { HttpApi().createHabit(it, body.toString()) }
                } catch (_: IOException) {
                    null
                }
            }
            when {
                response == null -> toast("Could not reach the server. Try again when online.")
                response.status == 401 -> {
                    openApp(route = null)
                    return@launch
                }
                response.status !in 200..299 -> toast(errorMessage(response.body))
                else -> {
                    toast("Added ${body.getString("name")}")
                    finish()
                    // Bring it into the widget.
                    Widgets.syncNow(app)
                    return@launch
                }
            }
            onFailure()
        }
    }

    /** The server's own explanation, when it gave one. */
    private fun errorMessage(body: String): String =
        runCatching { JSONObject(body).getJSONObject("error").getString("message") }
            .getOrDefault("The habit could not be added.")

    /** Leaves for the app: its sign-in when [route] is null, otherwise that screen. */
    private fun openApp(route: String?) {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(MainActivity.EXTRA_ROUTE, route),
        )
        finish()
    }

    private fun toast(text: String) {
        Toast.makeText(applicationContext, text, Toast.LENGTH_SHORT).show()
    }
}
