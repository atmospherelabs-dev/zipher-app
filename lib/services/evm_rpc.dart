import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import '../src/rust/api/engine_api.dart' as rust_engine;
import 'tx_builder.dart';

final _log = Logger();

const bscRpc = 'https://bsc-dataseed1.binance.org';
const polygonRpc = 'https://polygon-bor-rpc.publicnode.com';
const usdtBsc = '0x55d398326f99059fF775485246999027B3197955';
/// Bridged USDC from Ethereum (USDC.e) — Polymarket and many DEX pools use this.
const usdcPolygon = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';
/// Native USDC issued by Circle on Polygon PoS (bridges / onramps often credit this).
const usdcPolygonNative = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359';

/// Public BSC JSON-RPC mirrors (read path). Used when no Alchemy key; `bsc-dataseed1` often returns HTML from some networks.
const List<String> bscRpcReadEndpoints = [
  'https://bsc-dataseed1.binance.org',
  'https://bsc-dataseed2.binance.org',
  'https://bsc-dataseed3.binance.org',
  'https://bsc-dataseed4.binance.org',
];

/// Polygon read mirrors — `polygon-rpc.com` is now Ankr-backed and requires an API key.
const List<String> polygonRpcReadEndpoints = [
  'https://polygon-bor-rpc.publicnode.com',
  'https://polygon.drpc.org',
  'https://1rpc.io/matic',
];

class Eip1559Fees {
  final int maxPriorityFeePerGas;
  final int maxFeePerGas;

  const Eip1559Fees({
    required this.maxPriorityFeePerGas,
    required this.maxFeePerGas,
  });
}

/// Lightweight JSON-RPC client for any EVM chain.
class EvmRpc {
  final String rpcUrl;
  const EvmRpc(this.rpcUrl);

  static const bsc = EvmRpc(bscRpc);
  static const polygon = EvmRpc(polygonRpc);

  List<String> _readEndpoints() {
    if (rpcUrl == bscRpc) return bscRpcReadEndpoints;
    if (rpcUrl == polygonRpc) return polygonRpcReadEndpoints;
    return [rpcUrl];
  }

  /// JSON-RPC call to a single endpoint (no fallback).
  Future<Map<String, dynamic>> _callDirect(String url, String method, List<dynamic> params) async {
    final payload = jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params, 'id': 1});
    final resp = await http
        .post(Uri.parse(url), headers: const {'Content-Type': 'application/json'}, body: payload)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode} from $url');
    }
    final raw = resp.body.trim();
    if (raw.isEmpty || (!raw.startsWith('{') && !raw.startsWith('['))) {
      throw FormatException('non-JSON from $url: ${raw.length > 120 ? '${raw.substring(0, 120)}…' : raw}');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) throw FormatException('unexpected JSON shape from $url');
    return Map<String, dynamic>.from(decoded);
  }

  /// JSON-RPC call with fallback across read endpoints.
  Future<Map<String, dynamic>> _call(String method, List<dynamic> params) async {
    Object? lastErr;
    for (final url in _readEndpoints()) {
      try {
        return await _callDirect(url, method, params);
      } catch (e) {
        lastErr = e;
      }
    }
    throw Exception('EVM JSON-RPC failed after ${_readEndpoints().length} endpoints: $lastErr');
  }

  int? _parseRpcInt(dynamic value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('0x') || raw.startsWith('0X')) {
      return int.tryParse(raw.substring(2), radix: 16);
    }
    return int.tryParse(raw);
  }

  Future<Eip1559Fees?> _polygonGasStationFees({required bool urgent}) async {
    try {
      final resp = await http
          .get(Uri.parse('https://gasstation.polygon.technology/v2'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('unexpected gas station JSON shape');
      }
      final tier = decoded[urgent ? 'fast' : 'standard'];
      if (tier is! Map<String, dynamic>) {
        throw const FormatException('missing gas tier');
      }
      final priorityGwei = ((tier['maxPriorityFee'] as num?)?.toDouble() ?? 0).clamp(25, double.infinity);
      final maxFeeGwei = ((tier['maxFee'] as num?)?.toDouble() ?? 0).clamp(priorityGwei, double.infinity);
      return Eip1559Fees(
        maxPriorityFeePerGas: (priorityGwei * 1e9).ceil(),
        maxFeePerGas: (maxFeeGwei * 1e9).ceil(),
      );
    } catch (e) {
      _log.w('[EvmRpc] polygon gas station failed: $e');
      return null;
    }
  }

  Future<Eip1559Fees> suggestEip1559Fees({bool urgent = false}) async {
    if (rpcUrl == polygonRpc) {
      final polygonFees = await _polygonGasStationFees(urgent: urgent);
      if (polygonFees != null) return polygonFees;
    }

    try {
      final priorityResp = await _call('eth_maxPriorityFeePerGas', []);
      final feeHistoryResp = await _call('eth_feeHistory', ['0x1', 'latest', []]);

      final priority = _parseRpcInt(priorityResp['result']) ?? 0;
      final baseFees = feeHistoryResp['baseFeePerGas'] as List<dynamic>?;
      final latestBaseFee = baseFees == null || baseFees.isEmpty
          ? 0
          : (_parseRpcInt(baseFees.last) ?? 0);

      final minPriority = rpcUrl == polygonRpc ? 25000000000 : 0;
      final resolvedPriority = math.max(priority, minPriority);
      final resolvedMaxFee = math.max(resolvedPriority, latestBaseFee * 2 + resolvedPriority);

      return Eip1559Fees(
        maxPriorityFeePerGas: resolvedPriority,
        maxFeePerGas: resolvedMaxFee,
      );
    } catch (e) {
      _log.w('[EvmRpc] dynamic fee lookup failed: $e');
      if (rpcUrl == polygonRpc) {
        return const Eip1559Fees(
          maxPriorityFeePerGas: 50000000000,
          maxFeePerGas: 150000000000,
        );
      }
      return const Eip1559Fees(
        maxPriorityFeePerGas: 1000000000,
        maxFeePerGas: 5000000000,
      );
    }
  }

  /// ERC-1155 `isApprovedForAll(account, operator)` — returns whether `operator` may move any token id.
  Future<bool> erc1155IsApprovedForAll({
    required String owner,
    required String tokenContract,
    required String operator,
  }) async {
    try {
      final ownerPadded = owner.replaceFirst('0x', '').toLowerCase().padLeft(64, '0');
      final opPadded = operator.replaceFirst('0x', '').toLowerCase().padLeft(64, '0');
      final data = '0xe985e9c5$ownerPadded$opPadded';
      final res = await _call('eth_call', [
        {'to': tokenContract, 'data': data},
        'latest',
      ]);
      final hex = res['result'] as String? ?? '0x';
      if (hex.length < 66) return false;
      final v = BigInt.parse(hex.substring(2, 66), radix: 16);
      return v != BigInt.zero;
    } catch (e) {
      _log.w('[EvmRpc] erc1155IsApprovedForAll failed: $e');
      return false;
    }
  }

  /// ERC-1155 `setApprovalForAll(operator, approved)` — one-time approval for CLOB sells.
  Future<String> erc1155SetApprovalForAll({
    required String seed,
    required String ownerAddress,
    required String tokenContract,
    required String operator,
    required bool approved,
    required int chainId,
    int? maxPriorityFee,
    int? maxFee,
    int gasLimit = 120000,
  }) async {
    final opPadded = operator.replaceFirst('0x', '').toLowerCase().padLeft(64, '0');
    final approvedWord =
        approved ? '0000000000000000000000000000000000000000000000000000000000000001' : '0000000000000000000000000000000000000000000000000000000000000000';
    final calldata = '0xa22cb465$opPadded$approvedWord';

    final fees = (maxPriorityFee == null || maxFee == null)
        ? await suggestEip1559Fees()
        : Eip1559Fees(maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee);
    final nonce = await getNonce(ownerAddress);
    final unsignedTxHex = TxBuilder.buildUnsignedEip1559(
      chainId: chainId,
      nonce: nonce,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
      maxFeePerGas: fees.maxFeePerGas,
      gasLimit: gasLimit,
      to: tokenContract,
      value: BigInt.zero,
      data: calldata,
    );

    final txHash = await rust_engine.engineSignAndBroadcastEvmTx(
      seedPhrase: seed,
      unsignedTxHex: unsignedTxHex,
      rpcUrl: rpcUrl,
    );
    await waitForReceipt(txHash);
    return txHash;
  }

  /// Native token balance (ETH / BNB / POL) in human units.
  Future<double> getNativeBalance(String address) async {
    try {
      final data = await _call('eth_getBalance', [address, 'latest']);
      final hex = data['result'] as String? ?? '0x0';
      final raw = BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);
      return raw / BigInt.from(10).pow(18);
    } catch (e) {
      _log.w('[EvmRpc] getNativeBalance failed: $e');
      return 0;
    }
  }

  /// ERC-20 balance in human units.
  Future<double> getErc20Balance(String owner, String contract, {int decimals = 18}) async {
    try {
      final paddedAddr = owner.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');
      final calldata = '0x70a08231000000000000000000000000$paddedAddr';
      final data = await _call('eth_call', [{'to': contract, 'data': calldata}, 'latest']);
      final hex = data['result'] as String? ?? '0x0';
      if (hex == '0x' || hex == '0x0') return 0;
      final raw = BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);
      return raw / BigInt.from(10).pow(decimals);
    } catch (e) {
      _log.w('[EvmRpc] getErc20Balance failed: $e');
      return 0;
    }
  }

  /// Pending transaction count.
  Future<int> getNonce(String address, {String block = 'pending'}) async {
    try {
      final data = await _call('eth_getTransactionCount', [address, block]);
      final hex = data['result'] as String? ?? '0x0';
      return int.parse(hex.replaceFirst('0x', ''), radix: 16);
    } catch (_) {
      return 0;
    }
  }

  /// Poll `eth_getTransactionReceipt` until mined, then verify status.
  ///
  /// Uses the primary RPC (the same node we broadcast to) to avoid
  /// receipt-lag issues with load-balanced read endpoints.
  Future<void> waitForReceipt(String txHash, {int maxAttempts = 45, int delayMs = 2000}) async {
    for (var i = 0; i < maxAttempts; i++) {
      await Future.delayed(Duration(milliseconds: delayMs));
      try {
        final data = await _callDirect(rpcUrl, 'eth_getTransactionReceipt', [txHash]);
        final receipt = data['result'];
        if (receipt == null) continue;

        final status = receipt['status'] as String? ?? '0x0';
        if (status == '0x1') return;

        final gasUsed = receipt['gasUsed'] as String? ?? '?';
        throw Exception('Transaction reverted (status=0x0, gasUsed=$gasUsed). TX: $txHash');
      } catch (e) {
        if (e.toString().contains('reverted')) rethrow;
      }
    }
    throw Exception('Transaction receipt timeout after ${maxAttempts * delayMs ~/ 1000}s. TX: $txHash');
  }

  /// Approve ERC-20 spend, sign via Rust, broadcast, wait for receipt.
  Future<String> approveErc20({
    required String seed,
    required String ownerAddress,
    required String tokenAddress,
    required String spenderAddress,
    required BigInt amount,
    required int chainId,
    int? maxPriorityFee,
    int? maxFee,
    int gasLimit = 100000,
  }) async {
    final fees = (maxPriorityFee == null || maxFee == null)
        ? await suggestEip1559Fees()
        : Eip1559Fees(maxPriorityFeePerGas: maxPriorityFee, maxFeePerGas: maxFee);
    final nonce = await getNonce(ownerAddress);
    final spenderPadded = spenderAddress.replaceAll('0x', '').padLeft(64, '0');
    final amountHex = amount.toRadixString(16).padLeft(64, '0');
    final calldata = '0x095ea7b3000000000000000000000000$spenderPadded$amountHex';

    final unsignedTxHex = TxBuilder.buildUnsignedEip1559(
      chainId: chainId, nonce: nonce,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas, maxFeePerGas: fees.maxFeePerGas,
      gasLimit: gasLimit, to: tokenAddress, value: BigInt.zero, data: calldata,
    );

    final txHash = await rust_engine.engineSignAndBroadcastEvmTx(
      seedPhrase: seed, unsignedTxHex: unsignedTxHex, rpcUrl: rpcUrl,
    );
    await waitForReceipt(txHash);
    return txHash;
  }

  /// Sign and broadcast any pre-built unsigned transaction, wait for receipt.
  Future<String> signBroadcastAndWait({
    required String seed,
    required String unsignedTxHex,
  }) async {
    final txHash = await rust_engine.engineSignAndBroadcastEvmTx(
      seedPhrase: seed, unsignedTxHex: unsignedTxHex, rpcUrl: rpcUrl,
    );
    await waitForReceipt(txHash);
    return txHash;
  }
}
