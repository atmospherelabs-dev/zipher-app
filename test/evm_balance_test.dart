import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/services/chain_config.dart';
import 'package:zipher/services/evm_portfolio_balance.dart';

void main() {
  final address = '0x${'1' * 40}';
  test(
      'one failed chain preserves successful chains and marks subtotal incomplete',
      () async {
    final reader = EvmBalanceReader(
        readPrices: () async => {'ETH': 2000},
        readAsset: (chain, _, token) async {
          if (chain == ChainConfig.polygon) throw StateError('offline');
          return chain == ChainConfig.ethereum && token == null ? 2 : 0;
        });
    final result = await reader.fetch(address);
    expect(result.unavailableChains, {'Polygon'});
    expect(result.tokens.single.balance, 2);
    expect(result.evmTotalUsd, 4000);
    expect(result.complete, false);
  });
  test('missing prices never become fixed native or stablecoin prices',
      () async {
    final reader = EvmBalanceReader(
        readPrices: () async => {},
        readAsset: (chain, _, token) async => chain == ChainConfig.bsc ? 1 : 0);
    final result = await reader.fetch(address);
    expect(result.tokens.length, 2);
    expect(result.fullyPriced, false);
    expect(result.evmTotalUsd, 0);
    expect(result.tokens.every((t) => !t.priceAvailable), true);
  });
  test(
      'concurrent reads coalesce; fresh cache avoids RPC; force refresh bypasses cache',
      () async {
    var priceReads = 0;
    final gate = Completer<Map<String, double>>();
    final reader = EvmBalanceReader(
        readPrices: () {
          priceReads++;
          return gate.future;
        },
        readAsset: (_, __, ___) async => 0);
    final a = reader.fetch(address);
    final b = reader.fetch(address);
    expect(identical(a, b), true);
    gate.complete({});
    await a;
    await reader.fetch(address);
    expect(priceReads, 1);
    await reader.fetch(address, force: true);
    expect(priceReads, 2);
  });
  test('old wallet completion cannot replace new wallet cache', () async {
    final gate = Completer<double>();
    final reader = EvmBalanceReader(
        readPrices: () async => {},
        readAsset: (_, owner, __) =>
            owner == address ? gate.future : Future.value(0));
    final old = reader.fetch(address);
    final other = '0x${'2' * 40}';
    final current = await reader.fetch(other);
    gate.complete(1);
    await old;
    expect(identical(await reader.fetch(other), current), true);
    expect(current.tokens, isEmpty);
  });
  test('hung chains time out with explicit failure instead of zero', () async {
    final reader = EvmBalanceReader(
        timeout: const Duration(milliseconds: 10),
        readPrices: () async => {},
        readAsset: (_, __, ___) => Completer<double>().future);
    final result = await reader.fetch(address);
    expect(result.unavailableChains.length, 6);
    expect(result.complete, false);
  });
  test('stale or invalid prices are excluded', () {
    final now = DateTime.utc(2026, 9, 9);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final result = EvmPortfolioBalance.parsePrices({
      'ethereum': {'usd': 2000, 'last_updated_at': seconds},
      'binancecoin': {'usd': 600, 'last_updated_at': seconds - 301},
      'tether': {'usd': -1, 'last_updated_at': seconds},
      'usd-coin': {'usd': 1},
    }, now);
    expect(result, {'ETH': 2000});
  });
  test('invalid addresses fail before network access', () async {
    final reader = EvmBalanceReader(
        readPrices: () => throw StateError('unexpected call'),
        readAsset: (_, __, ___) => throw StateError('unexpected call'));
    await expectLater(reader.fetch('not an address'), throwsArgumentError);
  });
}
