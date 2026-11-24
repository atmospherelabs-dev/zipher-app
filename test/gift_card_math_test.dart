import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/gift_cards/gift_card_math.dart';

void main() {
  group('parseDecimalUnits', () {
    test('parses exact zatoshis', () {
      expect(parseZatoshis('0.12345678'), 12345678);
      expect(parseZatoshis('1'), 100000000);
      expect(parseZatoshis('21000000'), 2100000000000000);
      expect(parseZatoshis('0.00000001'), 1);
      expect(parseZatoshis('000.5'), 50000000);
    });

    test('rounds extra precision up so the provider is never underpaid', () {
      expect(parseZatoshis('0.123456781'), 12345679);
      expect(parseZatoshis('0.123456780000'), 12345678);
      expect(parseDecimalUnits('1.239', 2, roundUp: false), 123);
    });

    test('rejects anything that is not a plain decimal', () {
      for (final bad in ['', '-1', '+1', '1e8', '1,000', '.5', '5.', 'abc', '0x10']) {
        expect(parseZatoshis(bad), isNull, reason: bad);
      }
      expect(parseZatoshis('99999999999999999999'), isNull);
    });
  });

  test('formatUnits trims or fixes digits', () {
    expect(formatZatoshis(12345678), '0.12345678');
    expect(formatZatoshis(100000000), '1');
    expect(formatZatoshis(150000000), '1.5');
    expect(formatUnits(2500, 2, fixed: true), '25.00');
    expect(formatUnits(5000, 0), '5000');
    expect(Fiat(2500, 'USD').toString(), '25.00 USD');
    expect(Fiat(5000, 'JPY').toString(), '5000 JPY');
  });

  test('Fiat.parse uses the currency minor units and never rounds up', () {
    expect(Fiat.parse('25', 'usd'), const Fiat(2500, 'USD'));
    expect(Fiat.parse('25.999', 'EUR'), const Fiat(2599, 'EUR'));
    expect(Fiat.parse('1000', 'JPY'), const Fiat(1000, 'JPY'));
  });

  group('denominations', () {
    test('fixed', () {
      final d = FixedDenominations([5000, 2500, 2500, 10000]);
      expect(d.values, [2500, 5000, 10000]);
      expect(d.reject(2500), isNull);
      expect(d.reject(3000), isNotNull);
    });

    test('range with step', () {
      const d = RangeDenominations(min: 500, max: 50000, step: 100);
      expect(d.reject(500), isNull);
      expect(d.reject(50000), isNull);
      expect(d.reject(2500), isNull);
      expect(d.reject(499), isNotNull);
      expect(d.reject(50001), isNotNull);
      expect(d.reject(550), isNotNull);
      final s = d.suggestions();
      expect(s.first, 500);
      expect(s.last, 50000);
      expect(s.length, lessThanOrEqualTo(6));
      expect(s.every((v) => d.reject(v) == null), isTrue);
    });
  });

  group('GiftCardCost', () {
    test('total is price plus exact network fee', () {
      const c = GiftCardCost(
          faceValue: Fiat(2500, 'USD'),
          priceZatoshis: 62500000,
          networkFeeZatoshis: 15000);
      expect(c.totalZatoshis, 62515000);
    });

    test('markup against the market rate in basis points', () {
      // 1 ZEC = 40.00 USD; 25.00 USD face is 0.625 ZEC at market.
      const atMarket = GiftCardCost(
          faceValue: Fiat(2500, 'USD'),
          priceZatoshis: 62500000,
          networkFeeZatoshis: 10000);
      expect(atMarket.markupBps(4000), 0);
      const fee = GiftCardCost(
          faceValue: Fiat(2500, 'USD'),
          priceZatoshis: 64062500, // +2.5%
          networkFeeZatoshis: 10000);
      expect(fee.markupBps(4000), 250);
      const discount = GiftCardCost(
          faceValue: Fiat(2500, 'USD'),
          priceZatoshis: 60625000, // −3%
          networkFeeZatoshis: 10000);
      expect(discount.markupBps(4000), -300);
      expect(discount.markupBps(null), isNull);
      expect(discount.markupBps(0), isNull);
    });

    test('formatBps', () {
      expect(formatBps(250), '+2.5%');
      expect(formatBps(-300), '−3%');
      expect(formatBps(0), '0%');
      expect(formatBps(5), '+0.05%');
    });
  });

  test('estimateZatoshis rounds up', () {
    expect(estimateZatoshis(2500, 4000), 62500000);
    // 1 cent at 30.00 USD/ZEC = 33333.33… zats → 33334
    expect(estimateZatoshis(1, 3000), 33334);
    expect(() => estimateZatoshis(0, 3000), throwsArgumentError);
  });
}
