import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/services/near_intents.dart';

void main() {
  final now = DateTime.utc(2026, 9, 9);
  Map<String, dynamic> payload({Map<String, dynamic> overrides = const {}}) => {
        'quoteRequest': {
          'amount': '100000000',
          'deadline': now.add(const Duration(hours: 2)).toIso8601String()
        },
        'quote': {
          'depositAddress': 'test-deposit',
          'amountIn': '100000000',
          'amountOut': '1000000',
          'minAmountOut': '990000',
          'deadline': now.add(const Duration(minutes: 10)).toIso8601String(),
          ...overrides,
        },
      };
  test(
      'provider minimum is bounded and arbitrary remote text is never surfaced',
      () {
    expect(
        NearIntentsException(
                'Amount is too low for bridge, try at least 132000')
            .minimumZatoshis,
        132000);
    for (final text in [
      'amount 132000 address xyz',
      'Amount is too low for bridge, try at least -1',
      'Amount is too low for bridge, try at least 9999999999999999'
    ]) {
      expect(NearIntentsException(text).minimumZatoshis, isNull);
    }
  });
  test('every quoted asset, destination and fee must match the request', () {
    final request = <String, dynamic>{
      'dry': false,
      'swapType': 'EXACT_INPUT',
      'slippageTolerance': 100,
      'originAsset': 'nep141:zec.omft.near',
      'destinationAsset': 'nep141:sol.omft.near',
      'amount': '1000000',
      'refundTo': 'refund',
      'refundType': 'ORIGIN_CHAIN',
      'recipient': 'recipient',
      'recipientType': 'DESTINATION_CHAIN',
      'depositType': 'ORIGIN_CHAIN',
      'appFees': [
        {'recipient': 'cipherscan.near', 'fee': 50}
      ]
    };
    NearQuoteResponse quote(Map<String, dynamic> echoed) =>
        NearQuoteResponse.fromJson({...payload(), 'quoteRequest': echoed});
    expect(quote(request).matchesRequest(request), isTrue);
    const protocol =
        '5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd';
    for (final other in [protocol, 'attacker']) {
      expect(
          quote({
            ...request,
            'appFees': [
              {
                'recipient': 'cipherscan.near',
                'fee': 25,
                'limitOrderId': null
              },
              {'recipient': other, 'fee': 25, 'limitOrderId': null}
            ]
          }).matchesRequest(request),
          other == protocol);
    }
    expect(
        quote({
          ...request,
          'appFees': [
            {'recipient': 'cipherscan.near', 'fee': 25},
            {'recipient': protocol, 'fee': 26}
          ]
        }).matchesRequest(request),
        isFalse);

    for (final field in request.keys) {
      final altered = {...request, field: 'tampered'};
      expect(quote(altered).matchesRequest(request), isFalse, reason: field);
      final missing = {...request}..remove(field);
      expect(quote(missing).matchesRequest(request), isFalse, reason: field);
    }
    expect(
        quote({
          ...request,
          'appFees': [
            {'recipient': 'attacker', 'fee': 50}
          ]
        }).matchesRequest(request),
        isFalse);
  });
  test('quote must supply its actual deadline', () {
    expect(
        NearQuoteResponse.fromJson(payload(overrides: {'deadline': null}))
            .isUsableExactInput(100000000, now: now),
        isFalse);
  });
  test('valid exact-input quote is reviewable', () {
    expect(
        NearQuoteResponse.fromJson(payload())
            .isUsableExactInput(100000000, now: now),
        isTrue);
  });
  test('actual quote amount overrides echoed request amount', () {
    final quote = NearQuoteResponse.fromJson(
        payload(overrides: {'amountIn': '200000000'}));
    expect(quote.amountIn, BigInt.from(200000000));
    expect(quote.isUsableExactInput(100000000, now: now), isFalse);
  });
  test('expired actual deadline cannot be masked by requested deadline', () {
    final quote = NearQuoteResponse.fromJson(
        payload(overrides: {'deadline': now.toIso8601String()}));
    expect(quote.isUsableExactInput(100000000, now: now), isFalse);
  });
  test('reject missing amounts, missing minimums and required deposit memos',
      () {
    for (final fields in [
      {'amountIn': null},
      {'amountOut': '0'},
      {'minAmountOut': null},
      {'minAmountOut': '2000000'},
      {'depositMemo': '123'},
      {'depositAddress': ''},
      {'deadline': 'invalid'},
    ]) {
      expect(
          NearQuoteResponse.fromJson(payload(overrides: fields))
              .isUsableExactInput(100000000, now: now),
          isFalse,
          reason: '$fields');
    }
  });
  test('broadcast updates the recovery record without duplicate swaps',
      () async {
    SharedPreferences.setMockInitialValues({});
    StoredSwap record(String? txid) => StoredSwap(
        provider: 'near_intents',
        depositAddress: 'deposit',
        timestamp: 1,
        fromCurrency: 'ZEC',
        fromAmount: '1',
        toCurrency: 'BTC',
        toAmount: '0.001',
        toAddress: 'recipient',
        txId: txid);
    await SwapStore.save(record(null));
    await SwapStore.save(record('broadcast-txid'));
    final records = await SwapStore.load();
    expect(records, hasLength(1));
    expect(records.single.txId, 'broadcast-txid');
  });

  test(
      'status persistence retains wallet ownership and the funding transaction',
      () async {
    SharedPreferences.setMockInitialValues({});
    await SwapStore.save(StoredSwap(
        walletId: 'wallet-one',
        testnet: false,
        provider: 'near_intents',
        depositAddress: 'deposit',
        timestamp: 1,
        fromCurrency: 'ZEC',
        fromAmount: '1',
        toCurrency: 'ETH',
        toAmount: '.1',
        toAddress: 'recipient',
        txId: 'funding'));
    await SwapStore.updateStatus('deposit', 'SUCCESS');
    final record = (await SwapStore.load()).single;
    expect(record.walletId, 'wallet-one');
    expect(record.testnet, false);
    expect(record.txId, 'funding');
    expect(record.status, 'SUCCESS');
  });
}
