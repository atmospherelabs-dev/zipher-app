import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/near_intents.dart';
import 'package:zipher/services/wallet_swap_tracker.dart';

StoredSwap swap(String deposit,
        {String? owner = 'one',
        bool? testnet = false,
        String? txid,
        String? status}) =>
    StoredSwap(
        walletId: owner,
        testnet: testnet,
        status: status,
        provider: 'near_intents',
        depositAddress: deposit,
        timestamp: 1,
        fromCurrency: 'ZEC',
        fromAmount: '1',
        toCurrency: 'ETH',
        toAmount: '0.2',
        toAddress: 'recipient',
        txId: txid);
NearSwapStatus state(String value) => NearSwapStatus(status: value, raw: {});

void main() {
  test('restores only this wallet and exact-matched legacy deposits', () async {
    final polled = <String>[];
    final tracker = WalletSwapTracker(
        walletId: 'one',
        testnet: false,
        transactionIds: () => {'legacy-tx'},
        canPoll: () => true,
        load: () async => [
              swap('own'),
              swap('foreign', owner: 'two'),
              swap('wrong-network', testnet: true),
              swap('legacy', owner: null, txid: 'legacy-tx'),
              swap('unknown', owner: null),
              swap('done', status: 'SUCCESS')
            ],
        readStatus: (address) async {
          polled.add(address);
          return state('PROCESSING');
        },
        saveStatus: (_, __) async {});
    await tracker.refresh();
    expect(tracker.entries.map((e) => e.swap.depositAddress).toSet(),
        {'own', 'legacy', 'done'});
    expect(polled.toSet(), {'own', 'legacy'});
    tracker.dispose();
  });
  test('provider outages stay live, recover, and persist completion', () async {
    var fail = true;
    final saved = <String>[];
    final tracker = WalletSwapTracker(
        walletId: 'one',
        testnet: false,
        transactionIds: () => {},
        canPoll: () => true,
        load: () async => [swap('own')],
        readStatus: (_) async {
          if (fail) throw StateError('offline');
          return state('SUCCESS');
        },
        saveStatus: (_, status) async => saved.add(status));
    await tracker.refresh();
    expect(tracker.entries.single.isLive, isTrue);
    expect(tracker.entries.single.label, 'Status unavailable · retrying');
    fail = false;
    await tracker.refresh();
    expect(tracker.entries.single.isLive, isFalse);
    expect(tracker.entries.single.label, 'Completed');
    expect(saved, ['SUCCESS']);
    tracker.dispose();
  });
  test('late provider response cannot publish after switching wallets',
      () async {
    final response = Completer<NearSwapStatus>();
    final started = Completer<void>();
    var saved = false;
    final tracker = WalletSwapTracker(
        walletId: 'one',
        testnet: false,
        transactionIds: () => {},
        canPoll: () => true,
        load: () async => [swap('own')],
        readStatus: (_) {
          started.complete();
          return response.future;
        },
        saveStatus: (_, __) async {
          saved = true;
        });
    final pending = tracker.refresh();
    await started.future;
    tracker.dispose();
    response.complete(state('SUCCESS'));
    await pending;
    expect(saved, isFalse);
  });

  test('a swap with no recorded deposit stops counting as in progress', () {
    var clock = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
    StoredSwap started({String? txid}) => StoredSwap(
        walletId: 'one',
        testnet: false,
        provider: 'near_intents',
        depositAddress: 'deposit',
        timestamp: 1000,
        fromCurrency: 'ZEC',
        fromAmount: '1.5',
        toCurrency: 'USDC',
        toAmount: '1185.82',
        toAddress: 'recipient',
        txId: txid);
    final unfunded = WalletSwapActivity(started(), now: () => clock);
    expect(unfunded.isLive, isTrue);
    clock = clock.add(const Duration(minutes: 31));
    expect(unfunded.neverFunded, isFalse,
        reason: 'an unread status is not evidence of anything');
    unfunded.status = state('PENDING_DEPOSIT');
    expect(unfunded.neverFunded, isTrue);
    expect(unfunded.isLive, isFalse);
    expect(unfunded.label, 'No deposit was sent');
    expect(unfunded.isOpen, isTrue, reason: 'a late deposit is still noticed');
    // Evidence of a deposit, from the wallet or the provider, keeps it live.
    unfunded.status = state('KNOWN_DEPOSIT_TX');
    expect(unfunded.isLive, isTrue);
    expect(unfunded.label, 'Confirming deposit');
    final funded = WalletSwapActivity(started(txid: 'tx'), now: () => clock);
    expect(funded.isLive, isTrue);
    expect(funded.label, 'Checking status…');
  });
}
