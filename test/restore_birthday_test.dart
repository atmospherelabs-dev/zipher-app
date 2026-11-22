import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/restore_birthday.dart';

void main() {
  test('date-only restores never infer a later height from average block time',
      () {
    // Both mainnet and testnet, before/after their NU7 eras and a date far
    // before either upgrade, use complete history. No network heights or block
    // spacing constants are duplicated by the date selector.
    for (final date in [
      DateTime.utc(2018, 10, 29),
      DateTime.utc(2026, 9, 1),
      DateTime.utc(2026, 10, 6),
      DateTime.utc(2026, 11, 6),
      DateTime.utc(2027, 1, 1),
    ]) {
      expect(
        restoreBirthdayFromInput(blockHeight: '', selectedDate: date),
        fullHistoryRestoreBirthday,
      );
    }
    expect(restoreBirthdayFromInput(blockHeight: '   '),
        fullHistoryRestoreBirthday);
    expect(fullHistoryRestoreBirthday, 0);
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
