package uk.pixxula.habytes

import java.time.LocalDate
import java.time.LocalTime
import org.json.JSONArray
import org.json.JSONObject

/** JSON for the stored state and for the API. Field names follow the API. */

/**
 * A target's running period. A cache stored before periods were sent has
 * none; all targets were weekly then, so theirs is the cache's week.
 */
private fun periodFromJson(json: JSONObject, schedule: Schedule, weekStart: LocalDate): Period? = when {
    !schedule.isTarget -> null
    !json.isNull("period_start") && !json.isNull("period_end") ->
        Period(LocalDate.parse(json.getString("period_start")), LocalDate.parse(json.getString("period_end")))
    else -> Period(weekStart, weekStart.plusDays(6))
}

private fun habitFromJson(json: JSONObject, weekStart: LocalDate) = Habit(
    id = json.getString("id"),
    name = json.getString("name"),
    kind = Kind.valueOf(json.getString("kind").uppercase()),
    schedule = Schedule.valueOf(json.getString("schedule").uppercase()),
    weekdays = json.optJSONArray("weekdays")?.let { days -> List(days.length(), days::getInt) },
    goal = json.getInt("goal"),
    value = json.getInt("value"),
    periodValue = json.getInt("period_value"),
    streak = json.optInt("streak", 0),
    unit = json.optString("unit", ""),
    skipped = json.optBoolean("skipped", false),
    categoryId = json.optString("category_id").takeIf { it.isNotEmpty() && !json.isNull("category_id") },
    reminders = (json.optJSONArray("reminders") ?: JSONArray()).let { list ->
        List(list.length()) { list.getJSONObject(it) }.mapNotNull { reminder ->
            val time = runCatching { LocalTime.parse(reminder.getString("time")) }.getOrNull()
            val days = reminder.optJSONArray("days")?.let { days -> List(days.length(), days::getInt) }
            time?.let { Reminder(it, days) }
        }
    },
    every = json.optInt("every", 1),
    dueFrom = json.optString("due_from").takeIf { it.isNotEmpty() && !json.isNull("due_from") }?.let(LocalDate::parse),
    period = periodFromJson(json, Schedule.valueOf(json.getString("schedule").uppercase()), weekStart),
)

private fun Habit.toJson() = JSONObject()
    .put("id", id)
    .put("name", name)
    .put("kind", kind.name.lowercase())
    .put("schedule", schedule.name.lowercase())
    .put("every", every)
    .put("due_from", dueFrom?.toString() ?: JSONObject.NULL)
    .put("period_start", period?.start?.toString() ?: JSONObject.NULL)
    .put("period_end", period?.end?.toString() ?: JSONObject.NULL)
    .put("weekdays", weekdays?.let(::JSONArray) ?: JSONObject.NULL)
    .put("goal", goal)
    .put("value", value)
    .put("period_value", periodValue)
    .put("streak", streak)
    .put("unit", unit)
    .put("skipped", skipped)
    .put("category_id", categoryId ?: JSONObject.NULL)
    .put(
        "reminders",
        JSONArray(
            reminders.map {
                JSONObject()
                    .put("time", it.time.toString())
                    .put("days", it.days?.let(::JSONArray) ?: JSONObject.NULL)
            },
        ),
    )

/** Reads a stored cache, or the body of `GET /today` (which has no `fetched_at`). */
fun cacheFromJson(text: String, fetchedAt: Long? = null): Cache {
    val json = JSONObject(text)
    val habits = json.getJSONArray("habits")
    val categories = json.optJSONArray("categories") ?: JSONArray()
    val weekStart = LocalDate.parse(json.getString("week_start_date"))
    return Cache(
        date = LocalDate.parse(json.getString("date")),
        weekStartDate = weekStart,
        fetchedAt = fetchedAt ?: json.getLong("fetched_at"),
        habits = List(habits.length()) { habitFromJson(habits.getJSONObject(it), weekStart) },
        categories = List(categories.length()) {
            val category = categories.getJSONObject(it)
            Category(
                id = category.getString("id"),
                name = category.getString("name"),
                collapsed = category.optBoolean("collapsed", false),
            )
        },
    )
}

fun Cache.toJson(): String = JSONObject()
    .put("date", date.toString())
    .put("week_start_date", weekStartDate.toString())
    .put("fetched_at", fetchedAt)
    .put("habits", JSONArray(habits.map { it.toJson() }))
    .put(
        "categories",
        JSONArray(
            categories.map {
                JSONObject().put("id", it.id).put("name", it.name).put("collapsed", it.collapsed)
            },
        ),
    )
    .toString()

fun outboxFromJson(text: String): List<Op> {
    val array = JSONArray(text)
    return List(array.length()) {
        val json = array.getJSONObject(it)
        val opId = json.getString("op_id")
        val habitId = json.getString("habit_id")
        val date = LocalDate.parse(json.getString("date"))
        when (val type = json.getString("type")) {
            "increment" -> Op.Increment(opId, habitId, date, json.getInt("delta"))
            "set" -> Op.Set(opId, habitId, date, json.getInt("value"))
            else -> throw IllegalArgumentException("unknown operation type $type")
        }
    }
}

fun List<Op>.toJson(): String = JSONArray(
    map { op ->
        val json = JSONObject()
            .put("op_id", op.opId)
            .put("habit_id", op.habitId)
            .put("date", op.date.toString())
        when (op) {
            is Op.Increment -> json.put("type", "increment").put("delta", op.delta)
            is Op.Set -> json.put("type", "set").put("value", op.value)
        }
    },
).toString()

/** The request body that sends [op] to the server. */
fun Op.requestBody(): String = when (this) {
    is Op.Increment -> JSONObject().put("op_id", opId).put("delta", delta)
    is Op.Set -> JSONObject().put("value", value)
}.toString()
