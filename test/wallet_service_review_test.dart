import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/coin/coins.dart';
import 'package:zipher/services/wallet_service.dart';

void main() {
  test('nonpositive exact amounts fail before preparing a proposal', () async {
    for (final amount in [0, -1, 2100000000000001]) {
      await expectLater(WalletService.instance.proposeSend('unused', amount),
          throwsArgumentError);
    }
    expect(WalletService.instance.isBusy, false);
  });
  test('empty direct payments fail before key access', () async {
    await expectLater(WalletService.instance.send([]), throwsArgumentError);
    expect(WalletService.instance.isBusy, false);
  });
  test(
      'shielding reserves the payment path and invalidates reviews even when key access fails',
      () async {
    final wallet = WalletService.instance;
    final revision = wallet.proposalRevision;
    final result = expectLater(wallet.shieldFunds(), throwsException);
    expect(wallet.isBusy, true);
    await expectLater(wallet.proposeSend('unused', 1), throwsException);
    await result;
    expect(wallet.isBusy, false);
    expect(wallet.proposalRevision, revision + 2);
    await expectLater(
        wallet.confirmSend(expectedRevision: revision), throwsStateError);
  });
  // These must fail before any Rust initialization or secure-storage read.
  test('rejects a superseded proposal before accessing signing keys', () async {
    await expectLater(WalletService.instance.confirmSend(expectedRevision: -1),
        throwsStateError);
  });
  test('rejects a review from another wallet before accessing signing keys',
      () async {
    await expectLater(
        WalletService.instance.confirmSend(expectedWalletId: 'other-wallet'),
        throwsStateError);
  });
  test('rejects a review from another network before accessing signing keys',
      () async {
    await expectLater(
        WalletService.instance.confirmSend(expectedTestnet: !isTestnet),
        throwsStateError);
  });
}
