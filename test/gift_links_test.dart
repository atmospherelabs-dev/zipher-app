import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/gift_links.dart';

class _Secrets implements GiftSecrets {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

SentGift _gift([SentGiftStatus status = SentGiftStatus.draft]) => SentGift(
      id: 'u1fund',
      link: 'https://zipher.to/gift#v=1&key=zgift1secret&height=3500000',
      fundingAddress: 'u1fund',
      amount: 25000000,
      birthday: 3500000,
      createdAt: DateTime.utc(2026, 11, 24),
      status: status,
      testnet: false,
      message: 'Welcome!',
    );

void main() {
  group('GiftMath', () {
    test('parses exact ZEC and rejects the rest', () {
      expect(GiftMath.parseZec('0.25'), 25000000);
      expect(GiftMath.parseZec('1'), 100000000);
      expect(GiftMath.parseZec('.5'), 50000000);
      expect(GiftMath.parseZec('0.00000001'), 1);
      expect(GiftMath.parseZec(' 2.5 '), 250000000);
      for (final bad in ['', '1.', '1.123456789', '-1', '1e8', '1,5', 'abc', '1234567890']) {
        expect(GiftMath.parseZec(bad), isNull, reason: bad);
      }
    });

    test('funding adds the claim fee reserve; total adds the network fee', () {
      expect(GiftMath.claimFeeReserve, 10000);
      expect(GiftMath.fundingAmount(25000000), 25010000);
      expect(GiftMath.senderTotal(25000000, 15000), 25025000);
      expect(() => GiftMath.fundingAmount(0), throwsArgumentError);
    });

    test('limits', () {
      expect(GiftMath.reject(null), isNotNull);
      expect(GiftMath.reject(99999), isNotNull);
      expect(GiftMath.reject(100000), isNull);
      expect(GiftMath.reject(100 * 100000000 + 1), isNotNull);
      // Spendable must cover the face value plus the reserve.
      expect(GiftMath.reject(25000000, spendable: 25009999), isNotNull);
      expect(GiftMath.reject(25000000, spendable: 25010000), isNull);
      expect(GiftMath.rejectMessage('x' * 129), isNotNull);
      expect(GiftMath.rejectMessage('Welcome to Zcash!'), isNull);
      expect(GiftMath.rejectMessage(null), isNull);
    });

    test('formats', () {
      expect(GiftMath.formatZec(25010000), '0.2501');
      expect(GiftMath.formatZec(100000000), '1');
      expect(GiftMath.formatZec(1), '0.00000001');
    });
  });

  group('sent gift state machine', () {
    test('fund, share, then claimed', () {
      var g = _gift();
      expect(g.status.canFund, isTrue);
      expect(g.status.shareable, isFalse);
      g = g.apply(SentGiftEvent.approve, networkFee: 15000);
      expect(g.status.canFund, isFalse);
      g = g.apply(SentGiftEvent.broadcast, txid: 'tx1');
      expect(g.status, SentGiftStatus.funded);
      expect(g.status.shareable, isTrue);
      expect(g.txid, 'tx1');
      expect(g.networkFee, 15000);
      expect(g.apply(SentGiftEvent.foundEmpty).status, SentGiftStatus.claimed);
      expect(g.apply(SentGiftEvent.reclaimed).status, SentGiftStatus.reclaimed);
    });

    test('a failed send returns to the same draft; uncertain never re-funds', () {
      final retry = _gift().apply(SentGiftEvent.approve).apply(SentGiftEvent.notSent);
      expect(retry.status, SentGiftStatus.draft);
      expect(retry.link, _gift().link);
      final unsure = _gift().apply(SentGiftEvent.approve).apply(SentGiftEvent.sendUncertain);
      expect(unsure.status.canFund, isFalse);
      expect(unsure.status.shareable, isTrue);
      expect(() => unsure.apply(SentGiftEvent.approve),
          throwsA(isA<IllegalGiftTransition>()));
    });

    test('nothing that may be funded can be funded again or discarded', () {
      for (final from in SentGiftStatus.values.where((s) => s.mayBeFunded)) {
        for (final e in SentGiftEvent.values) {
          try {
            final next = nextSentGiftStatus(from, e);
            expect(next.canFund, from == SentGiftStatus.funding && e == SentGiftEvent.notSent,
                reason: '$from + $e');
            expect(next, isNot(SentGiftStatus.discarded));
          } on IllegalGiftTransition {
            // fine
          }
        }
      }
    });

    test('store keeps records per wallet and network', () async {
      final secrets = _Secrets();
      final store = SentGiftStore(secrets: secrets);
      await store.save('w1', _gift());
      await store.save('w1', _gift().apply(SentGiftEvent.approve));
      final list = await store.list('w1', false);
      expect(list, hasLength(1));
      expect(list.single.status, SentGiftStatus.funding);
      expect(list.single.message, 'Welcome!');
      expect(await store.list('w1', true), isEmpty);
      expect(await store.list('w2', false), isEmpty);
    });
  });

  group('claim state machine', () {
    const ready = GiftBalance(spendable: 25010000, pending: 0, fee: 10000, redeemable: 25000000);
    const pending = GiftBalance(spendable: 0, pending: 25010000, fee: 0, redeemable: 0);
    const empty = GiftBalance(spendable: 0, pending: 0, fee: 0, redeemable: 0);
    const dust = GiftBalance(spendable: 5000, pending: 0, fee: 0, redeemable: 0);

    test('balance states', () {
      expect(ready.state, GiftClaimState.ready);
      expect(pending.state, GiftClaimState.pending);
      expect(empty.state, GiftClaimState.empty);
      expect(dust.state, GiftClaimState.dust);
      // Empty only counts as claimed once the funding was seen on chain.
      expect(empty.claimed, isFalse);
      expect(const GiftBalance(spendable: 0, pending: 0, fee: 0, redeemable: 0, seenFunding: true).claimed, isTrue);
      expect(const GiftBalance(spendable: 0, pending: 5, fee: 0, redeemable: 0, seenFunding: true).claimed, isFalse);
    });

    test('check, claim, accepted', () {
      var s = nextClaimState(GiftClaimState.unchecked, GiftClaimEvent.check);
      s = nextClaimState(s, GiftClaimEvent.found, balance: ready);
      expect(s, GiftClaimState.ready);
      s = nextClaimState(s, GiftClaimEvent.approve);
      expect(s, GiftClaimState.claiming);
      expect(nextClaimState(s, GiftClaimEvent.accepted), GiftClaimState.claimed);
      // An error before a transaction exists returns to ready.
      expect(nextClaimState(s, GiftClaimEvent.notSent), GiftClaimState.ready);
    });

    test('only ready can be claimed; an unconfirmed claim can only be resent', () {
      for (final st in GiftClaimState.values.where((s) => s != GiftClaimState.ready)) {
        expect(() => nextClaimState(st, GiftClaimEvent.approve),
            throwsA(isA<IllegalGiftTransition>()), reason: '$st');
      }
      final unconfirmed = nextClaimState(GiftClaimState.claiming, GiftClaimEvent.unconfirmed);
      expect(() => nextClaimState(unconfirmed, GiftClaimEvent.check),
          throwsA(isA<IllegalGiftTransition>()));
      expect(nextClaimState(unconfirmed, GiftClaimEvent.accepted), GiftClaimState.claimed);
      expect(() => nextClaimState(GiftClaimState.claimed, GiftClaimEvent.check),
          throwsA(isA<IllegalGiftTransition>()));
    });

    test('pending can be checked again', () {
      final s = nextClaimState(
          nextClaimState(GiftClaimState.unchecked, GiftClaimEvent.check),
          GiftClaimEvent.found,
          balance: pending);
      expect(nextClaimState(s, GiftClaimEvent.check), GiftClaimState.checking);
    });
  });

  test('link routing', () {
    expect(looksLikeGiftLink('https://zipher.to/gift#v=1&key=zgift1abc&height=1'), isTrue);
    expect(looksLikeGiftLink('https://gift.zodl.com/#v=1&key=zgifttest1abc&height=1'), isTrue);
    expect(looksLikeGiftLink('https://link.vizor.cash/payment-links/open#v3=WyJ'), isTrue);
    expect(looksLikeGiftLink('https://cipherpay.app/pay/123'), isFalse);
    expect(looksLikeGiftLink('zcash:u1abc?amount=1'), isFalse);
    expect(looksLikeGiftLink('http://zipher.to/gift#v=1&key=zgift1abc'), isFalse);
  });
}
