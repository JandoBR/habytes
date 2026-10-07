import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../theme.dart';

const weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
];

const monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// `Mon 5 Oct 2026`
String formatDate(DateTime date) =>
    '${weekdayShort[date.weekday - 1]} ${date.day} ${monthShort[date.month - 1]} ${date.year}';

void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$error')));
}

void showMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [action] and reports a failure in a snackbar. Returns whether it succeeded.
Future<bool> guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } on Exception catch (error) {
    if (context.mounted) showError(context, error);
    return false;
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return result ?? false;
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$error', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

/// Shows a provider's value, or its loading and error states.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.onRetry, required this.builder});

  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final Widget Function(T value) builder;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncValue(:final value?) => builder(value),
    AsyncError(:final error) => ErrorView(error: error, onRetry: onRetry),
    _ => const Center(child: CircularProgressIndicator()),
  };
}

/// Keeps content readable on wide screens.
class Centered extends StatelessWidget {
  const Centered({super.key, required this.child, this.maxWidth = 720});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
    child: Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: AppPalette.of(context).muted),
    ),
  );
}

/// The mark that says a habit is logged: an empty outline, or filled with the
/// highlighter. Square for yes/no habits, round for counters. A skipped day
/// shows a dash instead.
class Stamp extends StatelessWidget {
  const Stamp({
    super.key,
    required this.marked,
    this.skipped = false,
    this.round = false,
    this.color,
    this.onTap,
    this.size = 28,
  });

  final bool marked;
  final bool skipped;
  final bool round;

  /// The outline; the palette's ink if not given.
  final Color? color;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final outline = skipped ? palette.line : color ?? palette.ink;
    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: marked ? palette.highlight : Colors.transparent,
        border: Border.all(color: outline, width: 1.5),
        borderRadius: BorderRadius.circular(round ? size : 5),
      ),
      child: marked
          ? Icon(Icons.check, size: size * 0.68, color: palette.onHighlight)
          : skipped
          ? Icon(Icons.remove, size: size * 0.6, color: palette.muted)
          : null,
    );
    // The same footprint with or without a tap handler, so rows line up; the
    // padding makes a finger-sized target around the small mark.
    final padded = Padding(padding: const EdgeInsets.all(8), child: box);
    if (onTap == null) return padded;
    return Semantics(
      checked: marked,
      child: InkResponse(onTap: onTap, radius: size, child: padded),
    );
  }
}

/// The shown week, one square per day: filled when the day counted, faded
/// when only partly, a dash when skipped, and faint when the habit was not due.
class WeekStrip extends StatelessWidget {
  const WeekStrip({super.key, required this.habit, required this.view, required this.color});

  final TodayHabit habit;
  final TodayView view;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (habit.weekValues.length != 7) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final start = parseYmd(view.weekStartDate);
    final shown = view.dayIndex;
    const size = 10.0;

    Widget day(int i) {
      final value = habit.weekValues[i];
      final due = habit.weekdays?.contains(start.add(Duration(days: i)).weekday) ?? true;
      // A target has no daily goal: any amount is a day that counted.
      final met = habit.schedule.isTarget ? value > 0 : value >= habit.goal;
      final Color fill;
      if (met) {
        fill = color;
      } else if (value > 0) {
        fill = color.withValues(alpha: 0.4);
      } else if (!due) {
        fill = palette.line.withValues(alpha: 0.35);
      } else {
        fill = palette.line;
      }
      return Container(
        width: size,
        height: size,
        margin: const EdgeInsets.only(right: 3),
        decoration: BoxDecoration(
          color: fill,
          border: i == shown ? Border.all(color: palette.ink, width: 1.5) : null,
        ),
        child: habit.weekSkipped[i] && value == 0
            ? Center(child: Container(width: 5, height: 1.5, color: palette.muted))
            : null,
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 7; i++) day(i)]);
  }
}

/// A line of text with a highlighter stroke behind it when [on].
class Highlighted extends StatelessWidget {
  const Highlighted(this.text, {super.key, required this.on, this.style, this.maxLines = 1});

  final String text;
  final bool on;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      // Pull the text back out so highlighted and plain names line up.
      transform: Matrix4.translationValues(-5, 0, 0),
      decoration: BoxDecoration(
        color: on ? palette.highlight : palette.highlight.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: (style ?? DefaultTextStyle.of(context).style).copyWith(
          color: on ? palette.onHighlight : palette.ink,
        ),
      ),
    );
  }
}

/// Progress towards a goal: one block per unit for small goals, a bar otherwise.
class Meter extends StatelessWidget {
  const Meter({super.key, required this.value, required this.goal, this.height = 6});

  final int value;
  final int goal;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final filled = value.clamp(0, goal);
    if (goal <= 10) {
      return Row(
        children: [
          for (var i = 0; i < goal; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Container(height: height, color: i < filled ? palette.ink : palette.line),
            ),
          ],
        ],
      );
    }
    return Stack(
      children: [
        Container(height: height, color: palette.line),
        FractionallySizedBox(
          widthFactor: filled / goal,
          child: Container(height: height, color: palette.ink),
        ),
      ],
    );
  }
}

/// The HaBytes mark: an H made of bits, its crossbar set in the highlighter.
class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final gap = size / 14;
    final block = (size - 2 * gap) / 3;
    return SizedBox(
      width: size,
      height: size,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var row = 0; row < 3; row++)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var col = 0; col < 3; col++)
                  Container(
                    width: block,
                    height: block,
                    // Both uprights, and the middle of the crossbar.
                    color: col != 1
                        ? palette.ink
                        : row == 1
                        ? palette.highlight
                        : null,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
