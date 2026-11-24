import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/restore_birthday.dart';

void main() {
  test('a date starts a full month earlier, at an observed block height', () {
    // First block of Feb 2025 is 2806078; March 2025 restores from there.
    expect(
        restoreBirthdayFromInput(
            blockHeight: '', selectedDate: DateTime(2025, 3, 17)),
        2806077);
    // A year means January, so scanning starts in the previous December.
    expect(restoreBirthdayFromInput(blockHeight: '', selectedDate: DateTime(2025)),
        2735019);
    // Observed heights, not spacing: November 2026 (after NU7 halved the block
    // time) still maps to the real first block of October 2026.
    expect(
        restoreBirthdayFromInput(
            blockHeight: '', selectedDate: DateTime(2026, 11, 20)),
        3501995);
  });

  test('dates the table cannot cover use complete history', () {
    for (final date in [DateTime(2018, 10, 29), DateTime(2018, 11, 3)]) {
      expect(restoreBirthdayFromInput(blockHeight: '', selectedDate: date),
          fullHistoryRestoreBirthday);
    }
    expect(
        restoreBirthdayFromInput(
            blockHeight: '', selectedDate: DateTime(2025, 3), testnet: true),
        fullHistoryRestoreBirthday);
    expect(restoreBirthdayFromInput(blockHeight: '   '),
        fullHistoryRestoreBirthday);
    expect(fullHistoryRestoreBirthday, 0);
  });

  test('dates after the table start no later than its last month', () {
    expect(
        restoreBirthdayFromInput(
            blockHeight: '', selectedDate: DateTime(2027, 6, 1)),
        3537546);
  });

  test('an explicit anchor takes priority over date without moving it forward',
      () {
    for (final height in [1, 280000, 419200, 3543404, 3543405, 4465026]) {
      expect(
        restoreBirthdayFromInput(
          blockHeight: '  $height  ',
          selectedDate: DateTime.utc(2027, 1, 1),
        ),
        height,
      );
    }
  });

  test('invalid explicit input cannot silently restore from another boundary',
      () {
    for (final input in ['0', '-1', 'unknown', '123.5', '4294967296']) {
      expect(
        () => restoreBirthdayFromInput(blockHeight: input),
        throwsFormatException,
      );
    }
  });
}
