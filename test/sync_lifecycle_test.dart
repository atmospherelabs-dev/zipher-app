import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/store2.dart';

void main() {
  test('wallet switch clears the previous network heights and pause state', () {
    syncStatus2.latestHeight = 9000000;
    syncStatus2.syncedHeight = 8900000;
    syncStatus2.blocksTotal = 100;
    syncStatus2.blocksScanned = 50;
    syncStatus2.paused = true;
    syncStatus2.connected = false;
    syncStatus2.resetForWalletSwitch();
    expect(syncStatus2.latestHeight, isNull);
    expect(syncStatus2.syncedHeight, 0);
    expect(syncStatus2.blocksTotal, 0);
    expect(syncStatus2.paused, false);
    expect(syncStatus2.connected, true);
  });
  test('receive polling does not rearm timers without an open wallet',
      () async {
    boostSyncPolling();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(syncTimer, isNull);
    syncStatus2.resetForWalletSwitch();
    expect(isSyncBoosted(), false);
  });
}
