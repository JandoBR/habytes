package uk.pixxula.habytes

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.lazy.items
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontFamily
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import java.time.format.DateTimeFormatter
import java.util.Locale

private val habitIdKey = ActionParameters.Key<String>("habit_id")

// The app's palette (lib/theme.dart), light and dark. The stamps are drawables
// and take the same colours from res/values/colors.xml.
private val paper = ColorProvider(day = Color(0xFFF2EEE3), night = Color(0xFF0E1330))
private val ink = ColorProvider(day = Color(0xFF1E2C74), night = Color(0xFFEDE8DA))
private val muted = ColorProvider(day = Color(0xFF666C8E), night = Color(0xFF9A9FC0))
private val line = ColorProvider(day = Color(0xFFD6D0BF), night = Color(0xFF2B3263))
private val highlight = ColorProvider(day = Color(0xFFFFD23F), night = Color(0xFFFFD23F))
private val onHighlight = ColorProvider(day = Color(0xFF17225C), night = Color(0xFF17225C))

/** The list of habits due today. Tapping a row logs it. */
class HabitWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val sync = Widgets.sync(context)
        provideContent {
            // Every change to the store bumps the version, which recomposes the widget.
            val version by Widgets.version.collectAsState()
            val signedIn = remember(version) { sync.signedIn }
            val cache = remember(version) { sync.snapshot() }
            Box(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .appWidgetBackground()
                    .background(paper)
                    .cornerRadius(14.dp),
            ) {
                Content(signedIn, cache)
            }
        }
    }
}

@Composable
private fun Content(signedIn: Boolean, cache: Cache?) {
    when {
        !signedIn -> Message("Sign in")
        cache == null -> Message("Open HaBytes to load your habits")
        else -> Column(modifier = GlanceModifier.fillMaxSize()) {
            Header(cache)
            Box(modifier = GlanceModifier.fillMaxWidth().height(1.dp).background(line)) {}
            val sections = cache.sections
            if (sections.isEmpty()) {
                Message("Nothing due today")
            } else {
                LazyColumn(modifier = GlanceModifier.fillMaxSize()) {
                    for (section in sections) {
                        section.category?.let { category ->
                            item(itemId = category.id.hashCode().toLong()) {
                                CategoryRow(category, section.habits)
                            }
                        }
                        items(section.visible, itemId = { it.id.hashCode().toLong() }) { HabitRow(it) }
                    }
                }
            }
        }
    }
}

/** The day and how much of it is done. Opens the app. */
@Composable
private fun Header(cache: Cache) {
    val due = cache.countedHabits
    val day = cache.date.format(DateTimeFormatter.ofPattern("EEEE d MMM", Locale.ENGLISH))
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 12.dp, top = 9.dp, bottom = 8.dp)
            .clickable(actionStartActivity<MainActivity>()),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = day,
            maxLines = 1,
            style = TextStyle(color = ink, fontSize = 15.sp, fontWeight = FontWeight.Bold),
            modifier = GlanceModifier.defaultWeight(),
        )
        if (due.isNotEmpty()) {
            Text(
                text = "${due.count { it.done }}/${due.size} done",
                maxLines = 1,
                style = TextStyle(color = muted, fontSize = 12.sp, fontFamily = FontFamily.Monospace),
            )
        }
        Spacer(GlanceModifier.width(10.dp))
        // Quick add: a small sheet over the home screen.
        Box(
            modifier = GlanceModifier
                .size(28.dp)
                .background(ink)
                .cornerRadius(5.dp)
                .clickable(actionStartActivity<QuickAddActivity>()),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "+",
                style = TextStyle(color = paper, fontSize = 18.sp, fontWeight = FontWeight.Bold),
            )
        }
    }
}

/** A category's name and count. Folding is done in the app, which this opens. */
@Composable
private fun CategoryRow(category: Category, habits: List<Habit>) {
    val counted = habits.filter { it.inTally }
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 9.dp, bottom = 3.dp)
            .clickable(actionStartActivity<MainActivity>()),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = category.name.uppercase(Locale.ENGLISH),
            maxLines = 1,
            style = TextStyle(color = muted, fontSize = 11.sp, fontWeight = FontWeight.Bold),
            modifier = GlanceModifier.defaultWeight(),
        )
        Text(
            // Nothing to count when all of them are skipped or long targets.
            text = (if (counted.isEmpty()) "" else "${counted.count { it.done }}/${counted.size}") +
                if (category.collapsed) "  ▸" else "",
            maxLines = 1,
            style = TextStyle(color = muted, fontSize = 11.sp, fontFamily = FontFamily.Monospace),
        )
    }
}

/** A line of text that opens the app. */
@Composable
private fun Message(text: String) {
    Box(
        modifier = GlanceModifier.fillMaxSize().padding(16.dp).clickable(actionStartActivity<MainActivity>()),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = TextStyle(color = ink, fontSize = 15.sp, textAlign = TextAlign.Center),
        )
    }
}

@Composable
private fun HabitRow(habit: Habit) {
    val boolean = habit.kind == Kind.BOOLEAN
    // A target can be checked today without being done for its period.
    val marked = if (boolean) habit.checkedToday else habit.done
    val stamp = when {
        habit.excused && !marked -> R.drawable.widget_stamp_skipped
        boolean && marked -> R.drawable.widget_stamp_marked
        boolean -> R.drawable.widget_stamp_empty
        marked -> R.drawable.widget_round_marked
        else -> R.drawable.widget_round_empty
    }
    val detail = listOf(if (habit.excused) "skipped" else "", habit.progress, habit.streakText)
        .filter { it.isNotEmpty() }
        .joinToString(" · ")
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clickable(actionRunCallback<TapAction>(actionParametersOf(habitIdKey to habit.id))),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Image(
            provider = ImageProvider(stamp),
            contentDescription = if (marked) "Logged" else "Not logged",
            modifier = GlanceModifier.size(24.dp),
        )
        Spacer(GlanceModifier.width(12.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            // The highlighter: a stroke behind the name of what is done.
            Box(
                modifier = if (habit.done) {
                    GlanceModifier.background(highlight).cornerRadius(3.dp).padding(horizontal = 4.dp)
                } else {
                    GlanceModifier
                },
            ) {
                Text(
                    text = habit.name,
                    maxLines = 1,
                    style = TextStyle(
                        color = if (habit.done) onHighlight else if (habit.excused) muted else ink,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                    ),
                )
            }
            if (detail.isNotEmpty()) {
                Text(
                    text = detail,
                    maxLines = 1,
                    style = TextStyle(color = muted, fontSize = 12.sp, fontFamily = FontFamily.Monospace),
                )
            }
        }
    }
}

class TapAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val habitId = parameters[habitIdKey] ?: return
        Widgets.sync(context).tap(habitId)
        Widgets.redraw(context)
        Widgets.scheduleFlush(context)
    }
}

class HabitWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = HabitWidget()

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        Widgets.scheduleRefresh(context)
        Widgets.scheduleFlush(context)
    }
}
