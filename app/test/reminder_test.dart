import 'package:flutter_test/flutter_test.dart';
import 'package:habytes/api/models.dart';

void main() {
  const always = Reminder(time: '20:00');
  const some = Reminder(time: '20:00', days: [1, 3, 6]);

  test('a reminder with no days follows the habit', () {
    expect(always.daysText(), 'Every day');
    expect(always.daysText({5, 1, 3}), 'Mon, Wed, Fri');
    expect(always.fitTo({1, 3, 5}).days, isNull);
  });

  test('days the habit is not due on are left out', () {
    expect(some.daysText(), 'Mon, Wed, Sat');
    expect(some.fitTo({1, 3, 5}).days, [1, 3]);
    expect(some.daysText({1, 3, 5}), 'Mon, Wed');
  });

  test('all of the due days, or none of them, is every due day', () {
    expect(some.fitTo({1, 3}).days, isNull);
    expect(some.fitTo({2, 4}).days, isNull);
    expect(some.daysText({2, 4}), 'Tue, Thu');
  });
}
