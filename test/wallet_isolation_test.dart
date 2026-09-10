import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/accounts.dart';
import 'package:zipher/appsettings.dart';
import 'package:zipher/services/wallet_service.dart';
import 'package:zipher/services/wallet_registry.dart';
import 'package:zipher/src/rust/frb_generated.dart';
import 'package:zipher/src/rust/api/wallet.dart';

class DelayedWalletApi implements RustLibApi {
  final balance = Completer<WalletBalance>();
  int balanceReads = 0;
  @override
  Future<WalletBalance> crateApiEngineApiEngineGetWalletBalance() {
    balanceReads++;
    return balance.future;
  }

  @override
  Future<void> crateApiEngineApiEngineCloseWallet() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WalletBalance testBalance(int amount) => WalletBalance(
    transparent: BigInt.zero,
    sapling: BigInt.zero,
    orchard: BigInt.from(amount),
    ironwood: BigInt.zero,
    unconfirmedSapling: BigInt.zero,
    unconfirmedOrchard: BigInt.zero,
    unconfirmedIronwood: BigInt.zero,
    unconfirmedTransparent: BigInt.zero,
    totalTransparent: BigInt.zero,
    totalSapling: BigInt.zero,
    totalOrchard: BigInt.from(amount),
    totalIronwood: BigInt.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = DelayedWalletApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  test('a delayed balance cannot survive a native wallet close/reopen boundary',
      () async {
    appSettings.defaults();
    aa = ActiveAccount2(
        coin: 0, id: 1, name: 'Old wallet', address: '', canPay: false);
    aa.poolBalances = PoolBalance(totalOrchard: 123);
    final refreshing = aa.updateBalance();
    await Future<void>.delayed(Duration.zero);
    expect(api.balanceReads, 1);
    await WalletService.instance.closeWallet();
    api.balance.complete(testBalance(999));
    await refreshing;
    expect(aa.poolBalances.total, 123);
    aa = nullAccount;
  });

  test(
      'an account belonging to another wallet never requests the current balance',
      () async {
    appSettings.defaults();
    final before = api.balanceReads;
    aa = ActiveAccount2(
        coin: 0,
        id: 1,
        name: 'Old wallet',
        address: '',
        canPay: false,
        walletId: 'different-wallet');
    await aa.updateBalance();
    expect(api.balanceReads, before);
    aa = nullAccount;
  });

  test(
      'picker snapshots cannot reuse mainnet amounts on testnet or wallet totals for derived accounts',
      () {
    final row = FlatAccount(
        walletId: 'a',
        walletName: 'A',
        walletBalance: 500,
        snapshotTestnet: false,
        snapshotAt: DateTime(2026),
        flatIndex: 0,
        account:
            AccountEntry(accountIndex: 1, name: 'Second', lastBalance: 25));
    expect(row.lastBalance, 25);
    expect(row.hasSnapshot(false), isFalse);
    final primary = FlatAccount(
        walletId: 'a',
        walletName: 'A',
        walletBalance: 500,
        snapshotTestnet: false,
        snapshotAt: DateTime(2026),
        flatIndex: 0,
        account: AccountEntry(accountIndex: 0, name: 'First'));
    expect(primary.hasSnapshot(false), isTrue);
    expect(primary.hasSnapshot(true), isFalse);
  });
}
