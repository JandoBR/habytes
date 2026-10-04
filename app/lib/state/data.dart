import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../platform/native.dart';
import 'auth.dart';

/// Every habit, archived ones included, in order.
final habitsProvider = FutureProvider<List<Habit>>((ref) => ref.watch(apiProvider).habits());

final tokensProvider = FutureProvider<List<TokenInfo>>((ref) => ref.watch(apiProvider).tokens());

/// The day the Today screen is showing.
final selectedDateProvider = NotifierProvider<SelectedDate, DateTime>(SelectedDate.new);

class SelectedDate extends Notifier<DateTime> {
  @override
  DateTime build() => localToday();

  void shift(int days) {
    final next = state.add(Duration(days: days));
    if (!next.isAfter(localToday())) state = next;
  }

  void reset() => state = localToday();
}

final todayProvider = AsyncNotifierProvider<TodayController, TodayView>(TodayController.new);

class TodayController extends AsyncNotifier<TodayView> {
  @override
  Future<TodayView> build() =>
      ref.watch(apiProvider).today(ymd(ref.watch(selectedDateProvider)));

  /// Checks or unchecks a boolean habit on the shown day.
  Future<void> setChecked(TodayHabit habit, bool checked) =>
      _write((api, date) => api.setValue(habit.id, date, checked ? 1 : 0));

  /// Adds [delta] to a counter habit on the shown day.
  Future<void> add(TodayHabit habit, int delta) =>
      _write((api, date) => api.increment(habit.id, date, delta));

  Future<void> _write(Future<EntryStatus> Function(ApiClient api, String date) write) async {
    final view = state.value;
    if (view == null) return;
    final status = await write(ref.read(apiProvider), view.date);
    // The user may have moved to another day while the request was in flight.
    final current = state.value;
    if (current != null && current.date == status.date) {
      state = AsyncData(current.withStatus(status));
    }
    Native.refreshWidgets();
  }
}

/// Call after habits are created, edited, reordered or removed.
void invalidateHabits(WidgetRef ref) {
  ref.invalidate(habitsProvider);
  ref.invalidate(todayProvider);
  Native.refreshWidgets();
}
