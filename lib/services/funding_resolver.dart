import 'dart:math' as math;

import 'package:logger/logger.dart';

import '../src/rust/api/engine_api.dart' as rust_engine;
import 'action_executor.dart' show ActionProgress, ActionResult, ActionStatus;
import 'chain_config.dart';
import 'evm_rpc.dart';
import 'evm_swap.dart' show paraswapNativeToken;
import 'near_intents.dart';
import 'secure_key_store.dart';

final _log = Logger();

/// Convert a floating-point token amount to raw wei/units as [BigInt].
///
/// `BigInt.from(x * 1e18)` silently overflows because it goes through Dart's
/// 64-bit signed `int`. This uses `toStringAsFixed(0)` → `BigInt.parse` to
/// bypass that limit entirely.
BigInt toWei(double amount, {int decimals = 18}) {
  if (amount <= 0) return BigInt.zero;
  return BigInt.parse((amount * math.pow(10, decimals)).toStringAsFixed(0));
}

/// Resolves on-chain funding for any EVM chain using a 3-case priority:
///
/// 1. Target token already sufficient → done.
/// 2. Swappable tokens on same chain → ParaSwap on-chain swap.
/// 3. Nothing available → bridge ZEC to native gas token, then swap to target.
///
/// Gas is automatically funded whenever native balance is below
/// [ChainConfig.minGasBalance].
class FundingResolver {
  FundingResolver._();
  static final instance = FundingResolver._();

  final _near = NearIntents.instance;

  /// Ensure at least [amountNeeded] of [targetToken] is available on [chain].
  ///
  /// Yields [ActionProgress] events so the UI can show each sub-step.
  /// After the stream completes, the caller should re-check balance — if it's
  /// still below [amountNeeded] the last yielded event will have
  /// [ActionStatus.failed].
  ///
  /// [stepOffset] shifts reported step numbers so this embeds cleanly inside
  /// a larger multi-step flow. [totalSteps] is the parent flow's total.
  Stream<ActionProgress> ensureFunded({
    required ChainConfig chain,
    required String walletAddress,
    required String seed,
    required String targetToken,
    required int targetDecimals,
    required double amountNeeded,
    int stepOffset = 2,
    int totalSteps = 6,
  }) async* {
    final step = stepOffset;
    final reserveUsd = await SecureKeyStore.getGasReserveUsd();

    // ── 0. Inventory: what do we have on this chain? ────────────────────
    var nativeBal = await chain.rpc.getNativeBalance(walletAddress);
    final isNativeTarget = _isNativeToken(targetToken);
    var balance = isNativeTarget
        ? nativeBal
        : await chain.rpc.getErc20Balance(walletAddress, targetToken, decimals: targetDecimals);

    // Scan known ERC-20s upfront so we can decide the best path
    final swappableTokens = <TokenInfo, double>{};
    for (final entry in chain.knownTokens.entries) {
      final info = entry.value;
      if (info.address.toLowerCase() == targetToken.toLowerCase()) continue;
      final tokenBal = await chain.rpc.getErc20Balance(walletAddress, info.address, decimals: info.decimals);
      _log.i('[FundingResolver] scan ${info.symbol} (${info.address}): $tokenBal');
      if (tokenBal >= 0.01) swappableTokens[info] = tokenBal;
    }

    _log.i('[FundingResolver] ═══ ensureFunded START ═══\n'
        '  chain=${chain.name} (${chain.chainId})\n'
        '  target=$targetToken (${isNativeTarget ? "NATIVE" : "ERC-20"}, ${targetDecimals}d)\n'
        '  needed=$amountNeeded  have=$balance  native=$nativeBal\n'
        '  swappable=${swappableTokens.map((k, v) => MapEntry(k.symbol, '\$${v.toStringAsFixed(2)}'))}');

    // ── 1. Already funded? ────────────────────────────────────────────────
    if (balance >= amountNeeded) {
      _log.i('[FundingResolver] step1: DONE — already funded ($balance >= $amountNeeded)');
      yield ActionProgress(
        step: step, totalSteps: totalSteps,
        label: 'Balance sufficient',
        detail: '\$${balance.toStringAsFixed(2)} available on ${chain.name}',
      );
      return;
    }

    // ── 2. Need gas? Fund enough for approve + swap txs ──────────────────
    // If we have swappable tokens we'll need gas for on-chain swaps, so
    // request more than the bare minimum when we know work is coming.
    final needsOnChainSwap = swappableTokens.isNotEmpty || !isNativeTarget;
    final effectiveMinGas = needsOnChainSwap
        ? math.max(chain.minGasBalance, chain.gasTarget)
        : chain.minGasBalance;

    bool gasAvailable = nativeBal >= effectiveMinGas;
    _log.i('[FundingResolver] step2: gas check — have=$nativeBal need=$effectiveMinGas '
        'needsSwap=$needsOnChainSwap gasOk=$gasAvailable');
    if (!gasAvailable) {
      yield ActionProgress(
        step: step, totalSteps: totalSteps,
        label: 'Funding ${chain.nativeSymbol} gas',
        detail: 'Bridging ZEC → ${chain.nativeSymbol} for transaction fees...',
        status: ActionStatus.waiting,
      );
      final gasResult = await _fundGas(chain: chain, walletAddress: walletAddress, seed: seed);
      if (!gasResult.success) {
        _log.w('[FundingResolver] gas funding failed: ${gasResult.message}');
      }
      nativeBal = await chain.rpc.getNativeBalance(walletAddress);
      gasAvailable = nativeBal >= chain.minGasBalance;
      _log.i('[FundingResolver] after gas funding: native=$nativeBal gasAvailable=$gasAvailable');
    }

    // ── 3. Swap same-chain tokens → target ────────────────────────────────
    if (!gasAvailable && swappableTokens.isNotEmpty) {
      _log.i('[FundingResolver] step3: SKIP same-chain swaps — no gas for on-chain txs '
          '(have ${nativeBal.toStringAsFixed(6)} ${chain.nativeSymbol})');
    } else if (swappableTokens.isNotEmpty) {
      _log.i('[FundingResolver] step3: attempting ${swappableTokens.length} same-chain swap(s)');
    }

    for (final entry in gasAvailable ? swappableTokens.entries : <MapEntry<TokenInfo, double>>[]) {
      final info = entry.key;
      final tokenBal = entry.value;
      final gap = amountNeeded - balance;
      if (gap <= 0) break;

      final swapAmount = math.min(tokenBal, gap + 0.01);
      yield ActionProgress(
        step: step, totalSteps: totalSteps,
        label: 'Swapping ${info.symbol} → target',
        detail: 'Converting \$${swapAmount.toStringAsFixed(2)} ${info.symbol} via ParaSwap on ${chain.name}...',
        status: ActionStatus.waiting,
      );
      final raw = toWei(swapAmount, decimals: info.decimals);
      final result = await evmSwap(
        rpc: chain.rpc, chainId: chain.chainId, seed: seed,
        walletAddress: walletAddress,
        srcToken: info.address, srcDecimals: info.decimals,
        destToken: targetToken, destDecimals: targetDecimals,
        srcAmountRaw: raw,
      );
      if (!result.success) {
        _log.w('[FundingResolver] ${info.symbol} swap failed: ${result.message}');
      }
      // Always recheck — tx may have succeeded despite receipt timeout
      balance = isNativeTarget
          ? await chain.rpc.getNativeBalance(walletAddress)
          : await chain.rpc.getErc20Balance(walletAddress, targetToken, decimals: targetDecimals);
      nativeBal = await chain.rpc.getNativeBalance(walletAddress);
      _log.i('[FundingResolver] after ${info.symbol} swap: balance=$balance native=$nativeBal');
      if (balance >= amountNeeded) {
        yield ActionProgress(step: step, totalSteps: totalSteps, label: 'Swap complete');
        return;
      }
      if (!result.success) {
        yield ActionProgress(
          step: step, totalSteps: totalSteps,
          label: '${info.symbol} swap failed',
          detail: 'Could not convert ${info.symbol}: ${result.message}. Trying other sources...',
          status: ActionStatus.waiting,
        );
      }
    }

    // 3b. Try native token → target (if target is ERC-20 and we have surplus native and gas)
    if (!isNativeTarget && gasAvailable) {
      nativeBal = await chain.rpc.getNativeBalance(walletAddress);
      final nativePrice = await _nativeGasTokenPriceUsd(chain.nativeSymbol, chain.nearIntentsBlockchain);
      final reserveNative = math.max(chain.minGasBalance, reserveUsd / math.max(nativePrice, 0.001));
      final spendableNative = nativeBal - reserveNative;
      final spendableUsd = spendableNative * nativePrice;
      final remainingGap = amountNeeded - balance;

      if (spendableNative > 0.0005 && spendableUsd >= remainingGap * 0.5) {
        // Only swap enough to cover the gap (+ 5% buffer), not all spendable
        final neededNative = (remainingGap * 1.05) / math.max(nativePrice, 0.001);
        final actualSwapNative = math.min(spendableNative, neededNative);
        _log.i('[FundingResolver] native swap: need=${neededNative.toStringAsFixed(4)} '
            'spendable=${spendableNative.toStringAsFixed(4)} swapping=${actualSwapNative.toStringAsFixed(4)} ${chain.nativeSymbol}');
        yield ActionProgress(
          step: step, totalSteps: totalSteps,
          label: 'Swapping ${chain.nativeSymbol} → target',
          detail: 'ParaSwap on ${chain.name} (keeping ~\$${reserveUsd.toStringAsFixed(2)} for gas)...',
          status: ActionStatus.waiting,
        );
        final nativeWei = toWei(actualSwapNative);
        final swapResult = await evmSwap(
          rpc: chain.rpc, chainId: chain.chainId, seed: seed,
          walletAddress: walletAddress,
          srcToken: paraswapNativeToken, srcDecimals: 18,
          destToken: targetToken, destDecimals: targetDecimals,
          srcAmountRaw: nativeWei,
        );
        if (!swapResult.success) {
          _log.w('[FundingResolver] native swap failed: ${swapResult.message}');
        }
        // Re-check balance — public RPC read mirrors can lag 1-2 blocks behind
        // the write node, so retry a few times with a short delay.
        for (var i = 0; i < 4; i++) {
          if (i > 0) await Future.delayed(const Duration(seconds: 2));
          balance = await chain.rpc.getErc20Balance(walletAddress, targetToken, decimals: targetDecimals);
          _log.i('[FundingResolver] after native swap (attempt ${i + 1}): balance=$balance (needed=$amountNeeded)');
          if (balance >= amountNeeded) {
            yield ActionProgress(step: step, totalSteps: totalSteps, label: 'Swap complete');
            return;
          }
        }
      }
    }

    // ── 4. Bridge ZEC → native gas token, then swap native → target ──────
    _log.i('[FundingResolver] step4: bridge needed — balance=$balance needed=$amountNeeded');
    final stillNeeded = amountNeeded - balance;
    final bridgeUsd = stillNeeded + reserveUsd + 1.0;
    yield ActionProgress(
      step: step, totalSteps: totalSteps,
      label: 'Bridging ZEC → ${chain.nativeSymbol}',
      detail: 'Need ~\$${stillNeeded.toStringAsFixed(2)} more — bridging ~\$${bridgeUsd.toStringAsFixed(2)} via NEAR Intents...',
      status: ActionStatus.waiting,
    );
    final bridgeResult = await swapZecToToken(
      evmAddress: walletAddress,
      targetSymbol: chain.nativeSymbol,
      targetBlockchain: chain.nearIntentsBlockchain,
      amountUsd: bridgeUsd,
      seed: seed,
    );
    if (!bridgeResult.success) {
      yield ActionProgress(
        step: step, totalSteps: totalSteps,
        label: 'Funding failed',
        detail: bridgeResult.message,
        status: ActionStatus.failed,
      );
      return;
    }
    await Future.delayed(const Duration(seconds: 4));

    // Swap newly-arrived native → target (keep gas reserve)
    if (!isNativeTarget) {
      nativeBal = await chain.rpc.getNativeBalance(walletAddress);
      final nativePrice = await _nativeGasTokenPriceUsd(chain.nativeSymbol, chain.nearIntentsBlockchain);
      final reserveNative = math.max(chain.minGasBalance, reserveUsd / math.max(nativePrice, 0.001));
      final spendable = nativeBal - reserveNative;

      if (spendable > 0.0005) {
        yield ActionProgress(
          step: step, totalSteps: totalSteps,
          label: 'Swapping ${chain.nativeSymbol} → target',
          detail: 'ParaSwap on ${chain.name}...',
          status: ActionStatus.waiting,
        );
        final wei = toWei(spendable);
        final swapResult = await evmSwap(
          rpc: chain.rpc, chainId: chain.chainId, seed: seed,
          walletAddress: walletAddress,
          srcToken: paraswapNativeToken, srcDecimals: 18,
          destToken: targetToken, destDecimals: targetDecimals,
          srcAmountRaw: wei,
        );
        if (!swapResult.success) {
          yield ActionProgress(
            step: step, totalSteps: totalSteps,
            label: 'On-chain swap failed',
            detail: swapResult.message,
            status: ActionStatus.failed,
          );
          return;
        }
      }
    }

    // Final balance check — retry for RPC lag after recent swaps/bridges
    for (var i = 0; i < 3; i++) {
      if (i > 0) await Future.delayed(const Duration(seconds: 2));
      balance = isNativeTarget
          ? await chain.rpc.getNativeBalance(walletAddress)
          : await chain.rpc.getErc20Balance(walletAddress, targetToken, decimals: targetDecimals);
      if (balance >= amountNeeded) break;
    }
    if (balance < amountNeeded) {
      yield ActionProgress(
        step: step, totalSteps: totalSteps,
        label: 'Insufficient balance',
        detail: 'Have \$${balance.toStringAsFixed(2)} but need \$${amountNeeded.toStringAsFixed(2)}. '
            'Try increasing gas reserve in settings or retry in a minute.',
        status: ActionStatus.failed,
      );
      return;
    }

    yield ActionProgress(
      step: step, totalSteps: totalSteps,
      label: 'Funded',
      detail: '\$${balance.toStringAsFixed(2)} ready on ${chain.name}',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Reusable helpers (moved from ActionExecutor)
  // ═══════════════════════════════════════════════════════════════════════

  /// USD price for a chain's native gas token via NEAR Intents token list.
  Future<double> _nativeGasTokenPriceUsd(String symbol, String blockchain) async {
    try {
      final tokens = await _near.getTokens();
      final t = _near.findToken(tokens, symbol, blockchain) ??
          (symbol == 'POL' ? _near.findToken(tokens, 'MATIC', blockchain) : null);
      final p = (t?['price'] as num?)?.toDouble();
      if (p != null && p > 0) return p;
    } catch (_) {}
    if (symbol == 'BNB') return 600;
    if (symbol == 'POL' || symbol == 'MATIC') return 0.085;
    return 1;
  }

  /// Same-chain swap via Rust engine (ParaSwap quote + approve + RLP + OWS sign + broadcast).
  Future<ActionResult> evmSwap({
    required EvmRpc rpc,
    required int chainId,
    required String seed,
    required String walletAddress,
    required String srcToken,
    required int srcDecimals,
    required String destToken,
    required int destDecimals,
    required BigInt srcAmountRaw,
    int slippageBps = 200,
    int? maxPriorityFee,
    int? maxFee,
  }) async {
    try {
      if (srcAmountRaw <= BigInt.zero) {
        return const ActionResult(success: false, message: 'Swap amount is zero');
      }
      _log.i('[FundingResolver] evmSwap via Rust engine: chain=$chainId '
          'src=$srcToken dst=$destToken amount=$srcAmountRaw');

      final result = await rust_engine.engineEvmSwapExecute(
        rpcUrl: rpc.rpcUrl,
        seedPhrase: seed,
        chainId: BigInt.from(chainId),
        userAddress: walletAddress,
        srcToken: srcToken,
        srcDecimals: srcDecimals,
        destToken: destToken,
        destDecimals: destDecimals,
        amountRaw: srcAmountRaw.toString(),
        slippageBps: slippageBps,
      );

      if (result.success) {
        _log.i('[FundingResolver] swap OK: tx=${result.txHash} block=${result.blockNumber}');
        return ActionResult(success: true, message: 'Swap complete: ${result.txHash}');
      } else {
        return ActionResult(success: false, message: 'Swap reverted in block ${result.blockNumber}');
      }
    } catch (e) {
      return ActionResult(success: false, message: 'Swap failed: $e');
    }
  }

  /// Bridge ZEC → any token available on NEAR Intents.
  Future<ActionResult> swapZecToToken({
    required String evmAddress,
    required String targetSymbol,
    required String targetBlockchain,
    required double amountUsd,
    required String seed,
  }) async {
    try {
      final tokens = await _near.getTokens();
      final zec = _near.findToken(tokens, 'ZEC');
      if (zec == null) return const ActionResult(success: false, message: 'ZEC not found on NEAR Intents');

      var target = _near.findToken(tokens, targetSymbol, targetBlockchain);
      if (target == null && targetSymbol == 'POL') {
        target = _near.findToken(tokens, 'MATIC', targetBlockchain);
      }
      if (target == null) {
        return ActionResult(success: false,
          message: '$targetSymbol on $targetBlockchain is not supported via NEAR Intents.');
      }

      final zecPrice = (zec['price'] as num?)?.toDouble() ?? 0;
      if (zecPrice <= 0) return const ActionResult(success: false, message: 'ZEC price unavailable');

      final zecAmount = (amountUsd / zecPrice * 1e8).round();
      final refundAddr = await _getRefundAddress();

      final quoteResp = await _near.getQuote(
        originAsset: zec['defuseAssetId'] ?? zec['assetId'] ?? zec['asset_id'] ?? '',
        destAsset: target['defuseAssetId'] ?? target['assetId'] ?? target['asset_id'] ?? '',
        amount: zecAmount.toString(), recipient: evmAddress, refundTo: refundAddr,
      );

      final quote = quoteResp['quote'] ?? quoteResp;
      final depositAddress = (quote['depositAddress'] ?? quoteResp['deposit_address']) as String? ?? '';
      if (depositAddress.isEmpty) return const ActionResult(success: false, message: 'No deposit address in quote');

      final txId = await rust_engine.engineSendPayment(
        seedPhrase: seed, address: depositAddress, amount: BigInt.from(zecAmount), memo: null,
      );
      _log.i('[FundingResolver] ZEC sent to swap deposit: $txId');

      await _near.submitDeposit(txId, depositAddress);
      final result = await _near.pollStatus(depositAddress);
      _log.i('[FundingResolver] bridge poll result: $result (tx=$txId)');
      if (result == 'success') return ActionResult(success: true, message: 'Swap complete: $txId');
      // Timeout is NOT a hard failure -- the swap is submitted and may still complete.
      if (result == 'timeout') {
        return ActionResult(success: true, message: 'Bridge submitted (still processing): $txId');
      }
      return ActionResult(success: false, message: 'Swap $result');
    } catch (e) {
      return ActionResult(success: false, message: 'Swap failed: $e');
    }
  }

  /// Auto-fund native gas token on [chain] via ZEC bridge.
  Future<ActionResult> _fundGas({
    required ChainConfig chain,
    required String walletAddress,
    required String seed,
  }) async {
    try {
      final tokens = await _near.getTokens();
      final zec = _near.findToken(tokens, 'ZEC');
      var target = _near.findToken(tokens, chain.nativeSymbol, chain.nearIntentsBlockchain);
      if (target == null && chain.nativeSymbol == 'POL') {
        target = _near.findToken(tokens, 'MATIC', chain.nearIntentsBlockchain);
      }
      target ??= _near.findToken(tokens, chain.nativeSymbol);
      if (zec == null || target == null) {
        return ActionResult(success: false,
          message: 'ZEC or ${chain.nativeSymbol} not found on NEAR Intents');
      }

      final zecPrice = (zec['price'] as num?)?.toDouble() ?? 0;
      final nativePrice = (target['price'] as num?)?.toDouble() ?? 1;
      if (zecPrice <= 0) return const ActionResult(success: false, message: 'ZEC price unavailable');

      var costUsd = chain.gasTarget * nativePrice;
      // NEAR Intents has a minimum bridge amount — ensure at least $1 USD
      if (costUsd < 1.0) costUsd = 1.0;
      final zecForGas = (costUsd / zecPrice * 1e8).round();
      _log.i('[FundingResolver] _fundGas: target=${chain.gasTarget} ${chain.nativeSymbol} '
          'bridgeUsd=\$${costUsd.toStringAsFixed(2)} zecForGas=$zecForGas zat '
          '(zecPrice=\$${zecPrice.toStringAsFixed(2)}, nativePrice=\$${nativePrice.toStringAsFixed(4)})');
      final refundAddr = await _getRefundAddress();

      final quoteResp = await _near.getQuote(
        originAsset: zec['defuseAssetId'] ?? zec['assetId'] ?? zec['asset_id'] ?? '',
        destAsset: target['defuseAssetId'] ?? target['assetId'] ?? target['asset_id'] ?? '',
        amount: zecForGas.toString(), recipient: walletAddress, refundTo: refundAddr,
        slippageBps: 200,
      );

      final deposit = (quoteResp['deposit_address'] ?? quoteResp['depositAddress'] ??
          (quoteResp['quote'] as Map?)?['depositAddress']) as String? ?? '';
      if (deposit.isEmpty) return const ActionResult(success: false, message: 'No deposit address in gas quote');

      final status = await _sendZecToDeposit(deposit, zecForGas, seed);
      if (status == 'failed' || status == 'refunded' || status == 'incomplete') {
        return ActionResult(success: false, message: 'Gas bridge $status');
      }
      // 'success' or 'timeout' (still processing) — both mean ZEC was sent
      return ActionResult(success: true, message: '${chain.nativeSymbol} gas funded ($status)');
    } catch (e) {
      return ActionResult(success: false, message: 'Gas funding failed: $e');
    }
  }

  // ── Private plumbing ───────────────────────────────────────────────────

  Future<String> _getRefundAddress() async {
    try {
      final addresses = await rust_engine.engineGetAddresses();
      if (addresses.isNotEmpty) return addresses.first.address;
    } catch (_) {}
    return '';
  }

  Future<String> _sendZecToDeposit(String depositAddress, int zecAmount, String seed) async {
    final txId = await rust_engine.engineSendPayment(
      seedPhrase: seed, address: depositAddress, amount: BigInt.from(zecAmount), memo: null,
    );
    _log.i('[FundingResolver] ZEC sent to deposit: $txId');
    await _near.submitDeposit(txId, depositAddress);
    final status = await _near.pollStatus(depositAddress);
    _log.i('[FundingResolver] gas bridge poll result: $status (tx=$txId)');
    return status;
  }

  bool _isNativeToken(String address) {
    final a = address.toLowerCase();
    return a == paraswapNativeToken.toLowerCase() ||
        a == '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ||
        a == '0x0000000000000000000000000000000000000000';
  }
}
