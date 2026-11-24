import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/services/gift_cards/gift_card_math.dart';
import 'package:zipher/services/gift_cards/gift_card_order.dart';
import 'package:zipher/services/gift_cards/gift_card_store.dart';

GiftCardOrder _order([GiftCardStatus status = GiftCardStatus.awaitingPayment]) =>
    GiftCardOrder(
      id: 'inv-1',
      provider: 'test',
      productId: 'amazon-us',
      productName: 'Amazon US',
      faceValue: const Fiat(2500, 'USD'),
      priceZatoshis: 62500000,
      paymentAddress: 'u1example',
      memo: 'order inv-1',
      status: status,
      createdAt: DateTime.utc(2026, 11, 24, 12),
      expiresAt: DateTime.utc(2026, 11, 24, 12, 30),
      walletId: 'w1',
    );

class _MemorySecrets implements GiftCardSecrets {
  final map = <String, String>{};
  @override
  Future<void> delete(String key) async => map.remove(key);
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

void main() {
  group('state machine', () {
    test('happy path', () {
      var o = _order();
      expect(o.status.canPay, isTrue);
      o = o.apply(GiftCardEvent.approve);
      expect(o.status, GiftCardStatus.paying);
      expect(o.status.canPay, isFalse);
      o = o.apply(GiftCardEvent.broadcast, txid: 'tx1', networkFeeZatoshis: 10000);
      expect(o.status, GiftCardStatus.paid);
      expect(o.txid, 'tx1');
      o = o.apply(GiftCardEvent.providerPaid);
      expect(o.status, GiftCardStatus.processing);
      o = o.apply(GiftCardEvent.delivered, hasCode: true);
      expect(o.status, GiftCardStatus.delivered);
      expect(o.status.isTerminal, isTrue);
      expect(o.hasCode, isTrue);
    });

    test('declined approval or signing error returns to not-paid, not retry', () {
      final o = _order().apply(GiftCardEvent.approve).apply(GiftCardEvent.notSent);
      expect(o.status, GiftCardStatus.cancelled);
      expect(o.status.paymentMayExist, isFalse);
      expect(() => o.apply(GiftCardEvent.approve),
          throwsA(isA<IllegalGiftCardTransition>()));
    });

    test('an uncertain send never offers to pay again', () {
      final o =
          _order().apply(GiftCardEvent.approve).apply(GiftCardEvent.sendUncertain);
      expect(o.status, GiftCardStatus.needsSupport);
      expect(o.status.canPay, isFalse);
      expect(o.status.paymentMayExist, isTrue);
      // The provider can still resolve it.
      expect(o.apply(GiftCardEvent.delivered).status, GiftCardStatus.delivered);
    });

    test('expiry before payment expires; after payment needs support', () {
      expect(_order().apply(GiftCardEvent.expired).status, GiftCardStatus.expired);
      expect(_order(GiftCardStatus.paid).apply(GiftCardEvent.expired).status,
          GiftCardStatus.needsSupport);
      expect(_order(GiftCardStatus.processing).apply(GiftCardEvent.providerFailed).status,
          GiftCardStatus.needsSupport);
    });

    test('no event moves a paid order back to awaiting payment', () {
      for (final from in GiftCardStatus.values.where((s) => s.paymentMayExist)) {
        for (final e in GiftCardEvent.values) {
          try {
            final next = nextGiftCardStatus(from, e);
            expect(next.canPay, isFalse, reason: '$from + $e');
            expect(next.paymentMayExist || next == GiftCardStatus.cancelled,
                isTrue,
                reason: '$from + $e');
            if (next == GiftCardStatus.cancelled) {
              // Only a pre-broadcast failure may cancel.
              expect(from, GiftCardStatus.paying);
            }
          } on IllegalGiftCardTransition {
            // fine
          }
        }
      }
    });

    test('terminal states reject further progress', () {
      for (final from in [
        GiftCardStatus.expired,
        GiftCardStatus.cancelled,
        GiftCardStatus.refunded
      ]) {
        for (final e in GiftCardEvent.values) {
          expect(() => nextGiftCardStatus(from, e),
              throwsA(isA<IllegalGiftCardTransition>()),
              reason: '$from + $e');
        }
      }
      // Re-reporting delivery is idempotent.
      expect(nextGiftCardStatus(GiftCardStatus.delivered, GiftCardEvent.delivered),
          GiftCardStatus.delivered);
      expect(() => nextGiftCardStatus(GiftCardStatus.delivered, GiftCardEvent.refunded),
          throwsA(isA<IllegalGiftCardTransition>()));
    });

    test('expiry check uses the invoice deadline', () {
      final o = _order();
      expect(o.isExpiredAt(DateTime.utc(2026, 11, 24, 12, 29)), isFalse);
      expect(o.isExpiredAt(DateTime.utc(2026, 11, 24, 12, 30)), isTrue);
    });
  });

  group('store', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips orders and keeps codes out of preferences', () async {
      final secrets = _MemorySecrets();
      final store = GiftCardStore(secrets: secrets);
      final o = _order().apply(GiftCardEvent.approve);
      await store.save(o);
      await store.save(o.apply(GiftCardEvent.broadcast, txid: 'tx1'));
      final list = await store.orders();
      expect(list, hasLength(1));
      expect(list.single.status, GiftCardStatus.paid);
      expect(list.single.txid, 'tx1');
      expect(list.single.faceValue, const Fiat(2500, 'USD'));
      expect(list.single.priceZatoshis, 62500000);

      await store.saveRedemption(
          list.single, const GiftCardRedemption(code: 'SECRET-CODE', pin: '1234'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gift_card_orders_v1'), isNot(contains('SECRET-CODE')));
      final r = await store.redemption(list.single);
      expect(r?.code, 'SECRET-CODE');
      expect(r?.pin, '1234');

      expect(await store.orders(walletId: 'other'), isEmpty);
      await store.remove(list.single);
      expect(await store.orders(), isEmpty);
      expect(secrets.map, isEmpty);
    });
  });
}
