package uk.pixxula.habytes

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
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
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle

private val habitIdKey = ActionParameters.Key<String>("habit_id")

/** The list of habits due today. Tapping a row logs it. */
class HabitWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val sync = Widgets.sync(context)
        provideContent {
            // Every change to the store bumps the version, which recomposes the widget.
            val version by Widgets.version.collectAsState()
            val signedIn = remember(version) { sync.signedIn }
            val cache = remember(version) { sync.snapshot() }
            GlanceTheme {
                Box(
                    modifier = GlanceModifier
                        .fillMaxSize()
                        .appWidgetBackground()
                        .background(GlanceTheme.colors.widgetBackground)
                        .cornerRadius(20.dp)
                        .padding(vertical = 8.dp),
                ) {
                    Content(signedIn, cache)
                }
            }
        }
    }
}

@Composable
private fun Content(signedIn: Boolean, cache: Cache?) {
    when {
        !signedIn -> Message("Sign in")
        cache == null -> Message("Open HaBytes to load your habits")
        cache.dueHabits.isEmpty() -> Message("Nothing due today")
        else -> LazyColumn(modifier = GlanceModifier.fillMaxSize()) {
            items(cache.dueHabits, itemId = { it.id.hashCode().toLong() }) { HabitRow(it) }
        }
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
            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 15.sp, textAlign = TextAlign.Center),
        )
    }
}

@Composable
private fun HabitRow(habit: Habit) {
    val icon = when {
        habit.kind == Kind.BOOLEAN && habit.checkedToday -> R.drawable.ic_widget_checked
        habit.kind == Kind.BOOLEAN -> R.drawable.ic_widget_unchecked
        habit.done -> R.drawable.ic_widget_done
        else -> R.drawable.ic_widget_add
    }
    val filled = habit.done || habit.checkedToday
    val dimmed = if (habit.done) GlanceTheme.colors.onSurfaceVariant else GlanceTheme.colors.onSurface
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 9.dp)
            .clickable(actionRunCallback<TapAction>(actionParametersOf(habitIdKey to habit.id))),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Image(
            provider = ImageProvider(icon),
            contentDescription = if (habit.done) "Completed" else "Not completed",
            colorFilter = ColorFilter.tint(
                if (filled) GlanceTheme.colors.primary else GlanceTheme.colors.outline,
            ),
            modifier = GlanceModifier.size(24.dp),
        )
        Spacer(GlanceModifier.width(12.dp))
        Text(
            text = habit.name,
            maxLines = 1,
            style = TextStyle(color = dimmed, fontSize = 15.sp),
            modifier = GlanceModifier.defaultWeight(),
        )
        if (habit.progress.isNotEmpty()) {
            Spacer(GlanceModifier.width(8.dp))
            Text(
                text = habit.progress,
                maxLines = 1,
                style = TextStyle(
                    color = if (habit.done) GlanceTheme.colors.primary else GlanceTheme.colors.onSurfaceVariant,
                    fontSize = 13.sp,
                ),
            )
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
