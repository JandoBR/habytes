import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habytes/api/models.dart';
import 'package:habytes/screens/habit_editor.dart';
import 'package:habytes/screens/manage.dart';
import 'package:habytes/state/data.dart';
import 'package:habytes/theme.dart';

void main() {
  testWidgets('the schedule options show what each needs', (tester) async {
    // A narrow phone.
    tester.view.physicalSize = const Size(360, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [categoriesProvider.overrideWith((ref) => <Category>[])],
        child: MaterialApp(theme: appTheme(Brightness.light), home: const HabitEditorScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Days between'), findsNothing);

    await tester.tap(find.text('Every few days'));
    await tester.pumpAndSettle();
    expect(find.text('Days between'), findsOneWidget);

    await tester.tap(find.text('Target'));
    await tester.pumpAndSettle();
    expect(find.text('Days between'), findsNothing);
    expect(find.text('Days per week'), findsOneWidget);
    await tester.tap(find.text('Per year'));
    await tester.pumpAndSettle();
    expect(find.text('Days per year'), findsOneWidget);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(find.text('Days every 2 years'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Every'), '3');
    await tester.pumpAndSettle();
    expect(find.text('Days every 3 years'), findsOneWidget);

    await tester.tap(find.text('Counter'));
    await tester.pumpAndSettle();
    expect(find.text('Total every 3 years'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('schedules are described in words', () {
    Habit habit(Schedule schedule, {int every = 1, int goal = 1, bool counter = false}) => Habit(
      id: 'a',
      name: 'Habit',
      description: '',
      kind: counter ? HabitKind.counter : HabitKind.boolean,
      schedule: schedule,
      every: every,
      weekdays: null,
      goal: goal,
      position: 0,
      archived: false,
      webhookUrl: null,
      unit: counter ? 'km' : '',
      color: 'ink',
      categoryId: null,
      reminders: const [],
    );
    expect(describeSchedule(habit(Schedule.monthly, goal: 2)), '2 days a month');
    expect(describeSchedule(habit(Schedule.yearly, goal: 1)), '1 day a year');
    expect(describeSchedule(habit(Schedule.monthly, every: 3, goal: 1)), '1 day every 3 months');
    expect(
      describeSchedule(habit(Schedule.weekly, every: 2, goal: 30, counter: true)),
      '30 km every 2 weeks',
    );
    expect(describeSchedule(habit(Schedule.interval, every: 3)), 'Every 3 days');
    expect(describeSchedule(habit(Schedule.interval, every: 1)), 'Every day');
  });
}
