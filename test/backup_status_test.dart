import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/services/backup_status.dart';

void main() {
  final status = BackupStatus.instance;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('backing up one wallet never marks another', () async {
    await status.markBackedUp('wallet-a', testnet: false);
    expect(await BackupStatus.isBackedUp('wallet-a', testnet: false), isTrue);
    expect(await BackupStatus.isBackedUp('wallet-b', testnet: false), isFalse);
    await status.load('wallet-b', testnet: false);
    expect(status.needsReminder.value, isTrue);
  });

  test('mainnet and testnet phrases are tracked separately', () async {
    await status.markBackedUp('wallet-a', testnet: false);
    expect(await BackupStatus.isBackedUp('wallet-a', testnet: true), isFalse);
    await status.load('wallet-a', testnet: true);
    expect(status.needsReminder.value, isTrue);
  });

  test('the old shared flag does not count as backed up', () async {
    SharedPreferences.setMockInitialValues({'seed_verified_0_1': true});
    await status.load('wallet-new', testnet: false);
    expect(status.needsReminder.value, isTrue);
  });

  test('Later hides the reminder for a day, then it returns', () async {
    final t0 = DateTime(2026, 11, 23, 12);
    await status.load('wallet-a', testnet: false, now: () => t0);
    await status.remindLater('wallet-a', testnet: false, now: () => t0);
    expect(status.needsReminder.value, isFalse);
    await status.load('wallet-a',
        testnet: false, now: () => t0.add(const Duration(hours: 23)));
    expect(status.needsReminder.value, isFalse);
    await status.load('wallet-a',
        testnet: false, now: () => t0.add(const Duration(hours: 25)));
    expect(status.needsReminder.value, isTrue);
  });
}
