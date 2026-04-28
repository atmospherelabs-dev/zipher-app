/// Thin Dart wrapper over the Rust engine's EVM module.
///
/// All actual RPC calls go through Rust's `reqwest` client, which avoids
/// iOS-specific issues with Dart's HTTP stack returning stale zero balances.

import 'package:logger/logger.dart';

import '../src/rust/api/engine_api.dart' as rust_engine;

final _log = Logger();

const bscRpc = 'https://bsc-dataseed1.binance.org';
const polygonRpc = 'https://polygon-bor-rpc.publicnode.com';
const usdtBsc = '0x55d398326f99059fF775485246999027B3197955';
/// Bridged USDC from Ethereum (USDC.e) — Polymarket and many DEX pools use this.
const usdcPolygon = '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174';
/// Native USDC issued by Circle on Polygon PoS (bridges / onramps often credit this).
const usdcPolygonNative = '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359';

/// Lightweight wrapper around the Rust engine's EVM RPC functions.
///
/// Holds a single `rpcUrl` and delegates every call to Rust via FFI.
class EvmRpc {
  final String rpcUrl;
  const EvmRpc(this.rpcUrl);

  static const bsc = EvmRpc(bscRpc);
  static const polygon = EvmRpc(polygonRpc);

  // ── Balance queries ────────────────────────────────────────────────────

  /// Native token balance (ETH / BNB / POL) in human units.
  Future<double> getNativeBalance(String address) async {
    try {
      final rawStr = await rust_engine.engineGetNativeBalance(
        rpcUrl: rpcUrl,
        address: address,
      );
      final raw = BigInt.parse(rawStr);
      return raw / BigInt.from(10).pow(18);
    } catch (e) {
      _log.w('[EvmRpc] getNativeBalance failed: $e');
      return 0;
    }
  }

  /// ERC-20 balance in human units.
  Future<double> getErc20Balance(String owner, String contract, {int decimals = 18}) async {
    try {
      final rawStr = await rust_engine.engineGetErc20Balance(
        rpcUrl: rpcUrl,
        tokenContract: contract,
        ownerAddress: owner,
      );
      final raw = BigInt.parse(rawStr);
      final bal = raw / BigInt.from(10).pow(decimals);
      _log.i('[EvmRpc] balanceOf($contract) -> $rawStr ($bal)');
      return bal;
    } catch (e) {
      _log.w('[EvmRpc] getErc20Balance($contract) failed: $e');
      return 0;
    }
  }

  // ── Transaction helpers ────────────────────────────────────────────────

  /// Pending transaction count.
  Future<int> getNonce(String address, {String block = 'pending'}) async {
    try {
      final n = await rust_engine.engineGetNonce(
        rpcUrl: rpcUrl,
        address: address,
      );
      return n.toInt();
    } catch (e) {
      _log.w('[EvmRpc] getNonce failed: $e');
      return 0;
    }
  }

  /// Suggested EIP-1559 gas fees.
  Future<Eip1559Fees> suggestEip1559Fees({bool urgent = false, int? chainId}) async {
    try {
      final cid = chainId ?? _inferChainId();
      final fees = await rust_engine.engineSuggestEip1559Fees(
        rpcUrl: rpcUrl,
        chainId: BigInt.from(cid),
      );
      return Eip1559Fees(
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas.toInt(),
        maxFeePerGas: fees.maxFeePerGas.toInt(),
      );
    } catch (e) {
      _log.w('[EvmRpc] suggestEip1559Fees failed: $e');
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

  // ── ERC-20 approve ─────────────────────────────────────────────────────

  /// Approve ERC-20 spend via Rust: sign + broadcast + wait for receipt.
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
    return rust_engine.engineApproveErc20(
      rpcUrl: rpcUrl,
      seedPhrase: seed,
      ownerAddress: ownerAddress,
      tokenAddress: tokenAddress,
      spenderAddress: spenderAddress,
      amountRaw: amount.toString(),
      chainId: BigInt.from(chainId),
    );
  }

  // ── ERC-1155 ───────────────────────────────────────────────────────────

  /// ERC-1155 `isApprovedForAll(account, operator)`.
  Future<bool> erc1155IsApprovedForAll({
    required String owner,
    required String tokenContract,
    required String operator,
  }) async {
    try {
      return await rust_engine.engineErc1155IsApprovedForAll(
        rpcUrl: rpcUrl,
        owner: owner,
        tokenContract: tokenContract,
        operator_: operator,
      );
    } catch (e) {
      _log.w('[EvmRpc] erc1155IsApprovedForAll failed: $e');
      return false;
    }
  }

  /// ERC-1155 `setApprovalForAll(operator, approved)` — sign + broadcast + wait.
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
    return rust_engine.engineErc1155SetApprovalForAll(
      rpcUrl: rpcUrl,
      seedPhrase: seed,
      ownerAddress: ownerAddress,
      tokenContract: tokenContract,
      operator_: operator,
      approved: approved,
      chainId: BigInt.from(chainId),
    );
  }

  // ── Receipt polling ────────────────────────────────────────────────────

  /// Wait for a transaction receipt. Throws if reverted or timed out.
  Future<void> waitForReceipt(String txHash, {int maxAttempts = 45, int delayMs = 2000}) async {
    final receipt = await rust_engine.engineWaitForReceipt(
      rpcUrl: rpcUrl,
      txHash: txHash,
    );
    if (!receipt.success) {
      throw Exception('Transaction reverted (gasUsed=${receipt.gasUsed}). TX: $txHash');
    }
  }

  /// Sign and broadcast any pre-built unsigned transaction, wait for receipt.
  Future<String> signBroadcastAndWait({
    required String seed,
    required String unsignedTxHex,
  }) async {
    final txHash = await rust_engine.engineSignAndBroadcastEvmTx(
      seedPhrase: seed,
      unsignedTxHex: unsignedTxHex,
      rpcUrl: rpcUrl,
    );
    await waitForReceipt(txHash);
    return txHash;
  }

  // ── Internal ───────────────────────────────────────────────────────────

  int _inferChainId() {
    if (rpcUrl == polygonRpc) return 137;
    if (rpcUrl == bscRpc) return 56;
    return 1;
  }
}

class Eip1559Fees {
  final int maxPriorityFeePerGas;
  final int maxFeePerGas;

  const Eip1559Fees({
    required this.maxPriorityFeePerGas,
    required this.maxFeePerGas,
  });
}
