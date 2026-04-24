import 'dart:async';

import 'package:logger/logger.dart';

import '../coin/coins.dart' show isTestnet;
import '../src/rust/api/engine_api.dart' as rust_engine;
import 'action_history.dart';
import 'chain_config.dart';
import 'evm_rpc.dart';
import 'funding_resolver.dart';
import 'myriad_client.dart';
import 'near_intents.dart';
import 'polymarket_client.dart';
import 'tx_builder.dart';
import 'wallet_service.dart';
import 'secure_key_store.dart';

final _log = Logger();

/// Progress update emitted during multi-step execution flows.
class ActionProgress {
  final int step;
  final int totalSteps;
  final String label;
  final String detail;
  final ActionStatus status;

  const ActionProgress({
    required this.step,
    required this.totalSteps,
    required this.label,
    this.detail = '',
    this.status = ActionStatus.running,
  });

  bool get isComplete => status == ActionStatus.done;
  bool get isFailed => status == ActionStatus.failed;
}

enum ActionStatus { running, waiting, done, failed }

/// Result of a completed action execution.
class ActionResult {
  final bool success;
  final String message;
  final Map<String, dynamic> data;

  const ActionResult({
    required this.success,
    required this.message,
    this.data = const {},
  });
}

/// Thin coordinator that orchestrates multi-step action flows (bet, swap,
/// sweep, sell) and yields progress updates as a Stream.
///
/// Funding logic (gas + collateral) is delegated to [FundingResolver].
/// Heavy lifting is delegated to:
/// - [EvmRpc] — JSON-RPC calls to BSC / Polygon
/// - [TxBuilder] — EIP-1559 unsigned transaction encoding
/// - [PolymarketClient] — CLOB auth + order posting
/// - [MyriadClient] — Myriad prediction market quote API
/// - [NearIntents] — cross-chain swap infrastructure
class ActionExecutor {
  ActionExecutor._();
  static final instance = ActionExecutor._();

  final _bsc = EvmRpc.bsc;
  final _polygon = EvmRpc.polygon;
  final _near = NearIntents.instance;
  final _polymarket = PolymarketClient.instance;
  final _myriad = MyriadClient.instance;
  final _resolver = FundingResolver.instance;

  bool _executing = false;
  bool get isExecuting => _executing;

  // ── Address helpers ──────────────────────────────────────────────────────

  Future<String?> getBscAddress() async {
    try {
      return await rust_engine.engineDeriveEvmAddress(seedPhrase: await _getSeed());
    } catch (_) {
      return null;
    }
  }

  Future<String?> getPolygonAddress() => getBscAddress();

  Future<double> getTokenBalance(String bscAddress, String symbol) async {
    try {
      if (symbol.toUpperCase() == 'BNB') return _bsc.getNativeBalance(bscAddress);
      if (symbol.toUpperCase() == 'USDT') return _bsc.getErc20Balance(bscAddress, usdtBsc, decimals: 18);
      return 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  Future<double> getPolygonUsdcBalance(String address) async {
    final bridged = await _polygon.getErc20Balance(address, usdcPolygon, decimals: 6);
    final native = await _polygon.getErc20Balance(address, usdcPolygonNative, decimals: 6);
    return bridged + native;
  }

  Future<double> getPolygonUsdcBridgedBalance(String address) =>
      _polygon.getErc20Balance(address, usdcPolygon, decimals: 6);

  Future<double> getPolygonUsdcNativeBalance(String address) =>
      _polygon.getErc20Balance(address, usdcPolygonNative, decimals: 6);

  Future<double> getPolygonPolBalance(String address) =>
      _polygon.getNativeBalance(address);

  Future<List<Map<String, dynamic>>> getSweepableBscTokens() =>
      _near.getSweepableBscTokens();

  // ═════════════════════════════════════════════════════════════════════════
  // Polymarket Bet
  // ═════════════════════════════════════════════════════════════════════════

  Stream<ActionProgress> executeBetPolymarket({
    required String tokenId,
    required double amountUsd,
    required String side,
    required double price,
    required bool negRisk,
    String? marketTitle,
  }) async* {
    if (_executing) {
      yield const ActionProgress(step: 0, totalSteps: 1, label: 'Error',
          detail: 'Another action is already executing.', status: ActionStatus.failed);
      return;
    }
    _executing = true;
    const total = 6;

    try {
      yield const ActionProgress(step: 1, totalSteps: total, label: 'Deriving Polygon address');
      final seed = await _getSeed();
      final polyAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      // ── Fund USDC.e via unified resolver ──
      yield const ActionProgress(step: 2, totalSteps: total, label: 'Checking balances');
      final fee = amountUsd * atmosphereFeeRate;
      final totalNeeded = amountUsd + fee;

      yield* _resolver.ensureFunded(
        chain: ChainConfig.polygon,
        walletAddress: polyAddress,
        seed: seed,
        targetToken: usdcPolygon,
        targetDecimals: 6,
        amountNeeded: totalNeeded,
        stepOffset: 3,
        totalSteps: total,
      );

      final usdcBridged = await getPolygonUsdcBridgedBalance(polyAddress);
      if (usdcBridged < totalNeeded) {
        yield ActionProgress(step: 3, totalSteps: total, label: 'Insufficient USDC.e',
            detail: 'Have \$${usdcBridged.toStringAsFixed(2)} USDC.e but need \$${totalNeeded.toStringAsFixed(2)}. '
                'Try increasing gas reserve in settings or retry in a minute.',
            status: ActionStatus.failed);
        return;
      }

      // L1 auth
      yield const ActionProgress(step: 4, totalSteps: total, label: 'Authenticating with Polymarket');
      final clobCreds = await _polymarket.deriveCredentials(seed);

      // Approve USDC.e
      yield const ActionProgress(step: 5, totalSteps: total, label: 'Approving USDC.e');
      final approveAmount = BigInt.from((totalNeeded * 1e6).round());
      final spender = negRisk ? polymarketNegRiskExchange : polymarketCtfExchange;
      final polygonFees = await _polygon.suggestEip1559Fees(urgent: true);
      await _polygon.approveErc20(
        seed: seed, ownerAddress: polyAddress, tokenAddress: usdcPolygon,
        spenderAddress: spender, amount: approveAmount, chainId: 137,
        maxPriorityFee: polygonFees.maxPriorityFeePerGas,
        maxFee: polygonFees.maxFeePerGas, gasLimit: 60000,
      );

      // Sign & post order
      yield const ActionProgress(step: 6, totalSteps: total, label: 'Placing order on Polymarket');
      final feeRate = await _polymarket.getFeeRate(tokenId);
      final makerAmountRaw = (amountUsd * 1e6).round();
      final sharesAmount = (amountUsd / price * 1e6).round();
      final sideInt = side.toUpperCase() == 'BUY' ? 0 : 1;
      final salt = DateTime.now().millisecondsSinceEpoch.toString();

      final signature = await rust_engine.enginePolymarketSignOrder(
        seedPhrase: seed, salt: salt, maker: polyAddress, signer: polyAddress,
        taker: '0x0000000000000000000000000000000000000000', tokenId: tokenId,
        makerAmount: sideInt == 0 ? makerAmountRaw.toString() : sharesAmount.toString(),
        takerAmount: sideInt == 0 ? sharesAmount.toString() : makerAmountRaw.toString(),
        expiration: '0', nonce: '0', feeRateBps: feeRate.toString(),
        side: sideInt, signatureType: 0, negRisk: negRisk,
      );

      final orderBody = {
        'order': {
          'salt': salt, 'maker': polyAddress, 'signer': polyAddress,
          'taker': '0x0000000000000000000000000000000000000000',
          'tokenId': tokenId,
          'makerAmount': sideInt == 0 ? makerAmountRaw.toString() : sharesAmount.toString(),
          'takerAmount': sideInt == 0 ? sharesAmount.toString() : makerAmountRaw.toString(),
          'expiration': '0', 'nonce': '0', 'feeRateBps': feeRate.toString(),
          'side': sideInt.toString(), 'signatureType': 0,
        },
        'signature': signature, 'owner': polyAddress, 'orderType': 'FOK',
      };

      final postResp = await _polymarket.post('/order', orderBody, clobCreds);
      if (postResp == null || postResp['success'] != true) {
        final errMsg = postResp?['errorMsg'] ?? postResp?['error'] ?? 'Order rejected by Polymarket';
        yield ActionProgress(step: 6, totalSteps: total, label: 'Order failed',
            detail: errMsg.toString(), status: ActionStatus.failed);
        return;
      }

      final orderId = postResp['orderID'] ?? postResp['order_id'] ?? '';
      yield const ActionProgress(step: 6, totalSteps: total, label: 'Bet placed on Polymarket', status: ActionStatus.done);

      await ActionHistory.instance.add(ActionRecord(
        id: ActionHistory.newId(),
        type: 'bet_polymarket',
        timestamp: DateTime.now(),
        success: true,
        summary: '${side.toUpperCase()} \$${amountUsd.toStringAsFixed(2)} on ${marketTitle ?? "Polymarket bet"}',
        details: {'orderId': orderId, 'tokenId': tokenId, 'amountUsd': amountUsd, 'chain': 'polygon'},
      ));
    } catch (e) {
      yield ActionProgress(step: 0, totalSteps: total, label: 'Bet failed',
          detail: e.toString(), status: ActionStatus.failed);
    } finally {
      _executing = false;
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Polymarket Sell
  // ═════════════════════════════════════════════════════════════════════════

  Stream<ActionProgress> executeSellPolymarket({
    required String tokenId,
    required double shares,
    required double worstPrice,
    required bool negRisk,
    String? marketTitle,
  }) async* {
    if (_executing) {
      yield const ActionProgress(step: 0, totalSteps: 1, label: 'Error',
          detail: 'Another action is already executing.', status: ActionStatus.failed);
      return;
    }
    _executing = true;
    const total = 5;

    try {
      yield const ActionProgress(step: 1, totalSteps: total, label: 'Deriving Polygon address');
      final seed = await _getSeed();
      final polyAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      // Ensure POL gas via resolver (just gas, no collateral needed for sells)
      yield const ActionProgress(step: 2, totalSteps: total, label: 'Checking POL for gas');
      final polBalance = await getPolygonPolBalance(polyAddress);
      if (polBalance < ChainConfig.polygon.minGasBalance) {
        yield* _resolver.ensureFunded(
          chain: ChainConfig.polygon,
          walletAddress: polyAddress,
          seed: seed,
          targetToken: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE',
          targetDecimals: 18,
          amountNeeded: ChainConfig.polygon.gasTarget,
          stepOffset: 2,
          totalSteps: total,
        );
        final newPol = await getPolygonPolBalance(polyAddress);
        if (newPol < ChainConfig.polygon.minGasBalance) {
          yield ActionProgress(step: 2, totalSteps: total, label: 'POL gas failed',
              detail: 'Could not fund POL for gas. Balance: ${newPol.toStringAsFixed(6)} POL.',
              status: ActionStatus.failed);
          return;
        }
      }

      yield const ActionProgress(step: 3, totalSteps: total, label: 'Authenticating with Polymarket');
      final clobCreds = await _polymarket.deriveCredentials(seed);

      final tokenContract =
          negRisk ? polymarketNegRiskAdapter : polymarketCtfContract;
      final exchangeOperator =
          negRisk ? polymarketNegRiskExchange : polymarketCtfExchange;

      yield const ActionProgress(step: 4, totalSteps: total, label: 'Checking outcome-token approval');
      final alreadyApproved = await _polygon.erc1155IsApprovedForAll(
        owner: polyAddress,
        tokenContract: tokenContract,
        operator: exchangeOperator,
      );
      if (!alreadyApproved) {
        yield const ActionProgress(step: 4, totalSteps: total, label: 'Approving outcome tokens for CLOB');
        await _polygon.erc1155SetApprovalForAll(
          seed: seed,
          ownerAddress: polyAddress,
          tokenContract: tokenContract,
          operator: exchangeOperator,
          approved: true,
          chainId: 137,
        );
      }

      yield const ActionProgress(step: 5, totalSteps: total, label: 'Placing sell order');
      final feeRate = await _polymarket.getFeeRate(tokenId);
      final sharesRaw = (shares * 1e6).round();
      final usdcRaw = (shares * worstPrice * 1e6).round();
      if (sharesRaw <= 0 || usdcRaw <= 0) {
        yield const ActionProgress(step: 5, totalSteps: total, label: 'Order failed',
            detail: 'Invalid size or price', status: ActionStatus.failed);
        return;
      }
      const sideInt = 1;
      final salt = DateTime.now().millisecondsSinceEpoch.toString();

      final signature = await rust_engine.enginePolymarketSignOrder(
        seedPhrase: seed,
        salt: salt,
        maker: polyAddress,
        signer: polyAddress,
        taker: '0x0000000000000000000000000000000000000000',
        tokenId: tokenId,
        makerAmount: sharesRaw.toString(),
        takerAmount: usdcRaw.toString(),
        expiration: '0',
        nonce: '0',
        feeRateBps: feeRate.toString(),
        side: sideInt,
        signatureType: 0,
        negRisk: negRisk,
      );

      final orderBody = {
        'order': {
          'salt': salt, 'maker': polyAddress, 'signer': polyAddress,
          'taker': '0x0000000000000000000000000000000000000000',
          'tokenId': tokenId,
          'makerAmount': sharesRaw.toString(),
          'takerAmount': usdcRaw.toString(),
          'expiration': '0', 'nonce': '0', 'feeRateBps': feeRate.toString(),
          'side': sideInt.toString(), 'signatureType': 0,
        },
        'signature': signature, 'owner': polyAddress, 'orderType': 'FOK',
      };

      final postResp = await _polymarket.post('/order', orderBody, clobCreds);
      if (postResp == null || postResp['success'] != true) {
        final errMsg = postResp?['errorMsg'] ?? postResp?['error'] ?? 'Sell order rejected by Polymarket';
        yield ActionProgress(step: 5, totalSteps: total, label: 'Sell failed',
            detail: errMsg.toString(), status: ActionStatus.failed);
        return;
      }

      final orderId = postResp['orderID'] ?? postResp['order_id'] ?? '';
      yield const ActionProgress(step: 5, totalSteps: total, label: 'Sell submitted', status: ActionStatus.done);

      await ActionHistory.instance.add(ActionRecord(
        id: ActionHistory.newId(),
        type: 'sell_polymarket',
        timestamp: DateTime.now(),
        success: true,
        summary: 'Sold ${shares.toStringAsFixed(2)} shares — ${marketTitle ?? "Polymarket"}',
        details: {
          'orderId': orderId,
          'tokenId': tokenId,
          'shares': shares,
          'worstPrice': worstPrice,
          'chain': 'polygon',
        },
      ));
    } catch (e) {
      yield ActionProgress(step: 0, totalSteps: total, label: 'Sell failed',
          detail: e.toString(), status: ActionStatus.failed);
    } finally {
      _executing = false;
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Myriad Bet (BSC)
  // ═════════════════════════════════════════════════════════════════════════

  Stream<ActionProgress> executeBet({
    required int marketId,
    required int outcome,
    required double amountUsdt,
    required double slippage,
    required double maxPriceMove,
  }) async* {
    if (_executing) {
      yield const ActionProgress(step: 0, totalSteps: 1, label: 'Error',
          detail: 'Another action is already executing.', status: ActionStatus.failed);
      return;
    }
    _executing = true;
    const total = 7;

    try {
      // 1: Derive BSC address
      yield const ActionProgress(step: 1, totalSteps: total, label: 'Deriving BSC address',
          detail: 'Using your wallet seed to derive the EVM address...');
      final seed = await _getSeed();
      final bscAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      // 2: Fetch market details
      yield ActionProgress(step: 2, totalSteps: total, label: 'Fetching market details',
          detail: 'Getting market #$marketId token and live odds...');
      Map<String, dynamic>? marketData;
      try { marketData = await WalletService.instance.getMarketDetails(marketId); } catch (_) {}
      final marketToken = marketData?['token'] as Map<String, dynamic>?;
      final tokenAddress = (marketToken?['address'] as String? ?? usdtBsc).toLowerCase();
      final tokenSymbol = marketToken?['symbol'] as String? ?? 'USDT';
      final tokenDecimals = (marketToken?['decimals'] as num?)?.toInt() ?? 18;

      final preQuote = await _myriad.getQuote(marketId, outcome, amountUsdt, slippage);
      if (preQuote == null) {
        yield const ActionProgress(step: 2, totalSteps: total, label: 'Quote failed',
            detail: 'Could not get a quote from Myriad. The market may be closed.', status: ActionStatus.failed);
        return;
      }
      final initialPrice = preQuote['price'] as double? ?? 0;

      // 3-4: Fund collateral via unified resolver
      yield ActionProgress(step: 3, totalSteps: total, label: 'Funding $tokenSymbol',
          detail: 'Ensuring \$${amountUsdt.toStringAsFixed(2)} $tokenSymbol on BSC...');

      yield* _resolver.ensureFunded(
        chain: ChainConfig.bsc,
        walletAddress: bscAddress,
        seed: seed,
        targetToken: tokenAddress,
        targetDecimals: tokenDecimals,
        amountNeeded: amountUsdt,
        stepOffset: 4,
        totalSteps: total,
      );

      // 5: Verify balance
      yield ActionProgress(step: 5, totalSteps: total, label: 'Verifying $tokenSymbol balance',
          detail: 'Checking $tokenSymbol arrived on BSC...');
      final available = await _bsc.getErc20Balance(bscAddress, tokenAddress, decimals: tokenDecimals);
      if (available < 0.50) {
        yield ActionProgress(step: 5, totalSteps: total, label: 'Swap failed',
            detail: 'Only \$${available.toStringAsFixed(2)} $tokenSymbol arrived. '
                'Swap may have failed or is still settling.', status: ActionStatus.failed);
        return;
      }

      final actualBet = available < amountUsdt ? available : amountUsdt;
      final adjusted = actualBet < amountUsdt;

      // Re-quote with actual amount and check price movement
      final freshQuote = await _myriad.getQuote(marketId, outcome, actualBet, slippage);
      if (freshQuote != null && initialPrice > 0) {
        final currentPrice = freshQuote['price'] as double? ?? 0;
        if (currentPrice > 0) {
          final move = ((currentPrice - initialPrice) / initialPrice * 100).abs();
          if (move > maxPriceMove) {
            yield ActionProgress(step: 5, totalSteps: total, label: 'Price moved too much',
                detail: 'Price changed ${move.toStringAsFixed(1)}% (limit: ${maxPriceMove.toStringAsFixed(1)}%). '
                    'Was ${initialPrice.toStringAsFixed(4)}, now ${currentPrice.toStringAsFixed(4)}. '
                    '$tokenSymbol remains on BSC.',
                status: ActionStatus.failed);
            return;
          }
        }
      }

      // 6: Approve collateral
      final approveLabel = adjusted
          ? 'Approving \$${actualBet.toStringAsFixed(2)} $tokenSymbol (adjusted for swap fees)'
          : 'Approving $tokenSymbol';
      yield ActionProgress(step: 6, totalSteps: total, label: approveLabel,
          detail: 'Signing ERC-20 approval for Myriad contract on BSC...');
      final approveAmount = BigInt.from(actualBet * 1.05 * BigInt.from(10).pow(tokenDecimals).toDouble());
      await _bsc.approveErc20(
        seed: seed, ownerAddress: bscAddress, tokenAddress: tokenAddress,
        spenderAddress: myriadContract, amount: approveAmount, chainId: 56,
      );

      // 7: Place bet
      yield ActionProgress(step: 7, totalSteps: total, label: 'Placing bet',
          detail: adjusted
              ? 'Betting \$${actualBet.toStringAsFixed(2)} (swap delivered \$${available.toStringAsFixed(2)} of \$${amountUsdt.toStringAsFixed(2)} requested)...'
              : 'Signing and broadcasting bet transaction on BSC...');
      final quote = freshQuote ?? preQuote;
      final calldataStr = quote['calldata'] as String? ?? '';
      if (calldataStr.isEmpty) {
        yield const ActionProgress(step: 7, totalSteps: total, label: 'Bet failed',
            detail: 'No calldata in quote', status: ActionStatus.failed);
        return;
      }

      final bscFees = await _bsc.suggestEip1559Fees(urgent: true);
      final nonce = await _bsc.getNonce(bscAddress);
      final txHex = TxBuilder.buildUnsignedEip1559(
        chainId: 56, nonce: nonce,
        maxPriorityFeePerGas: bscFees.maxPriorityFeePerGas,
        maxFeePerGas: bscFees.maxFeePerGas,
        gasLimit: ChainConfig.bsc.defaultGasLimit, to: myriadContract,
        value: BigInt.zero, data: calldataStr.startsWith('0x') ? calldataStr : '0x$calldataStr',
      );
      final txHash = await _bsc.signBroadcastAndWait(seed: seed, unsignedTxHex: txHex);

      yield ActionProgress(step: 7, totalSteps: total, label: 'Bet placed',
          detail: 'Market #$marketId, \$${actualBet.toStringAsFixed(2)} USDT'
              '${adjusted ? ' (adjusted from \$${amountUsdt.toStringAsFixed(2)})' : ''}, '
              '${(quote['shares'] as double? ?? 0).toStringAsFixed(4)} shares. TX: $txHash',
          status: ActionStatus.done);

      await ActionHistory.instance.add(ActionRecord(
        id: ActionHistory.newId(), type: 'bet', timestamp: DateTime.now(), success: true,
        summary: 'Bet \$${actualBet.toStringAsFixed(2)} on market #$marketId',
        details: {'marketId': marketId, 'outcome': outcome, 'amountUsdt': actualBet,
          'requestedUsdt': amountUsdt, 'shares': quote['shares'], 'txHash': txHash, 'chain': 'bsc'},
      ));
    } catch (e) {
      _log.e('[ActionExecutor] bet failed: $e');
      yield ActionProgress(step: 0, totalSteps: total, label: 'Unexpected error',
          detail: '$e', status: ActionStatus.failed);
      await ActionHistory.instance.add(ActionRecord(
        id: ActionHistory.newId(), type: 'bet', timestamp: DateTime.now(), success: false,
        summary: 'Bet failed: $e', details: {'marketId': marketId, 'amountUsdt': amountUsdt},
      ));
    } finally {
      _executing = false;
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // ZEC Swap
  // ═════════════════════════════════════════════════════════════════════════

  Stream<ActionProgress> executeSwap({
    required double amountZec,
    required String toToken,
  }) async* {
    if (_executing) {
      yield const ActionProgress(step: 0, totalSteps: 1, label: 'Error',
          detail: 'Another action is already executing.', status: ActionStatus.failed);
      return;
    }
    _executing = true;
    const total = 4;

    try {
      yield ActionProgress(step: 1, totalSteps: total, label: 'Deriving address',
          detail: 'Getting your ${toToken.toUpperCase()} destination address...');
      final seed = await _getSeed();
      final evmAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      yield ActionProgress(step: 2, totalSteps: total, label: 'Getting swap quote',
          detail: 'Requesting quote for ${amountZec.toStringAsFixed(4)} ZEC → $toToken...');

      yield ActionProgress(step: 3, totalSteps: total, label: 'Swapping ZEC',
          detail: 'Broadcasting shielded ZEC transaction to NEAR Intents...',
          status: ActionStatus.waiting);

      double amountUsd;
      try {
        final tokens = await _near.getTokens();
        final zecToken = _near.findToken(tokens, 'ZEC');
        final zecPrice = (zecToken?['price'] as num?)?.toDouble() ?? 0;
        amountUsd = zecPrice > 0 ? amountZec * zecPrice : amountZec * 40;
      } catch (_) {
        amountUsd = amountZec * 40;
      }

      final swapResult = await _resolver.swapZecToToken(
        evmAddress: evmAddress, targetSymbol: toToken.toUpperCase(),
        targetBlockchain: 'bsc', amountUsd: amountUsd, seed: seed,
      );
      if (!swapResult.success) {
        yield ActionProgress(step: 3, totalSteps: total, label: 'Swap failed',
            detail: swapResult.message, status: ActionStatus.failed);
        return;
      }

      yield ActionProgress(step: 4, totalSteps: total, label: 'Swap complete',
          detail: '${amountZec.toStringAsFixed(4)} ZEC → $toToken. Tokens delivered to $evmAddress.',
          status: ActionStatus.done);

      await ActionHistory.instance.add(ActionRecord(
        id: ActionHistory.newId(), type: 'swap', timestamp: DateTime.now(), success: true,
        summary: 'Swapped ${amountZec.toStringAsFixed(4)} ZEC → $toToken',
        details: {'amountZec': amountZec, 'toToken': toToken, 'destination': evmAddress},
      ));
    } catch (e) {
      _log.e('[ActionExecutor] swap failed: $e');
      yield ActionProgress(step: 0, totalSteps: total, label: 'Unexpected error',
          detail: '$e', status: ActionStatus.failed);
      await ActionHistory.instance.add(ActionRecord(
        id: ActionHistory.newId(), type: 'swap', timestamp: DateTime.now(), success: false,
        summary: 'Swap failed: $e', details: {'amountZec': amountZec, 'toToken': toToken},
      ));
    } finally {
      _executing = false;
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Sweep token → ZEC
  // ═════════════════════════════════════════════════════════════════════════

  Future<ActionResult> executeSweepTokenToZec({
    required String tokenSymbol,
    required String contractAddress,
    required int decimals,
    required double amount,
    required String defuseAssetId,
    StreamController<ActionProgress>? progress,
  }) async {
    try {
      progress?.add(ActionProgress(step: 1, totalSteps: 5, label: 'Getting swap quote ($tokenSymbol → ZEC)...'));
      final seed = await _getSeed();
      final bscAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);
      final zecAddress = await _getRefundAddress();

      final tokens = await _near.getTokens();
      final zecToken = _near.findToken(tokens, 'ZEC');
      if (zecToken == null) throw Exception('ZEC not found on NEAR Intents');

      final zecAssetId = zecToken['defuseAssetId'] ?? zecToken['assetId'] ?? zecToken['asset_id'] ?? zecToken['defuse_asset_id'] ?? '';
      final rawAmount = BigInt.from(amount * BigInt.from(10).pow(decimals).toDouble()).toString();

      final quote = await _near.getQuote(
        originAsset: defuseAssetId, destAsset: zecAssetId as String,
        amount: rawAmount, recipient: zecAddress, refundTo: bscAddress,
      );

      final depositAddress = (quote['deposit_address'] ?? quote['depositAddress'] ?? '') as String;
      if (depositAddress.isEmpty) throw Exception('No deposit address in quote');

      progress?.add(ActionProgress(step: 2, totalSteps: 5, label: 'Approving $tokenSymbol transfer...'));
      final bscFees = await _bsc.suggestEip1559Fees(urgent: true);
      final nonce = await _bsc.getNonce(bscAddress);
      final spenderPadded = depositAddress.replaceAll('0x', '').padLeft(64, '0');
      final amountHex = BigInt.parse(rawAmount).toRadixString(16).padLeft(64, '0');
      final approveCalldata = '0x095ea7b3000000000000000000000000$spenderPadded$amountHex';
      final approveUnsigned = TxBuilder.buildUnsignedEip1559(
        chainId: 56, nonce: nonce,
        maxPriorityFeePerGas: bscFees.maxPriorityFeePerGas,
        maxFeePerGas: bscFees.maxFeePerGas,
        gasLimit: 100000, to: contractAddress, value: BigInt.zero, data: approveCalldata,
      );
      await _bsc.signBroadcastAndWait(seed: seed, unsignedTxHex: approveUnsigned);

      progress?.add(ActionProgress(step: 3, totalSteps: 5, label: 'Depositing $tokenSymbol to bridge...'));
      final transferData = TxBuilder.buildErc20TransferCalldata(depositAddress, rawAmount);
      final transferHex = '0x${TxBuilder.bytesToHex(transferData)}';
      final nonce2 = await _bsc.getNonce(bscAddress);
      final transferUnsigned = TxBuilder.buildUnsignedEip1559(
        chainId: 56, nonce: nonce2,
        maxPriorityFeePerGas: bscFees.maxPriorityFeePerGas,
        maxFeePerGas: bscFees.maxFeePerGas,
        gasLimit: 100000, to: contractAddress, value: BigInt.zero, data: transferHex,
      );
      final depositTxHash = await _bsc.signBroadcastAndWait(seed: seed, unsignedTxHex: transferUnsigned);

      progress?.add(const ActionProgress(step: 4, totalSteps: 5, label: 'Waiting for swap to complete...'));
      final swapId = (quote['swap_id'] ?? quote['swapId'] ?? '') as String;
      if (swapId.isNotEmpty) {
        await _near.pollStatus(swapId);
      } else {
        await Future.delayed(const Duration(seconds: 30));
      }

      progress?.add(ActionProgress(step: 5, totalSteps: 5, label: '$tokenSymbol swept', status: ActionStatus.done));
      return ActionResult(success: true,
        message: 'Swept ${amount.toStringAsFixed(4)} $tokenSymbol → ZEC (shielded)\nTX: $depositTxHash');
    } catch (e) {
      return ActionResult(success: false, message: 'Sweep $tokenSymbol failed: $e');
    }
  }

  Future<ActionResult> executeSweepBnbToZec({
    required double amount,
    StreamController<ActionProgress>? progress,
  }) async {
    try {
      progress?.add(const ActionProgress(step: 1, totalSteps: 4, label: 'Getting swap quote (BNB → ZEC)...'));
      final seed = await _getSeed();
      final bscAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);
      final zecAddress = await _getRefundAddress();

      final tokens = await _near.getTokens();
      final zecToken = _near.findToken(tokens, 'ZEC');
      final bnbToken = _near.findToken(tokens, 'BNB', 'bsc');
      if (zecToken == null || bnbToken == null) throw Exception('ZEC or BNB not found on NEAR Intents');

      final zecAssetId = zecToken['defuseAssetId'] ?? zecToken['assetId'] ?? zecToken['asset_id'] ?? zecToken['defuse_asset_id'] ?? '';
      final bnbAssetId = bnbToken['defuseAssetId'] ?? bnbToken['assetId'] ?? bnbToken['asset_id'] ?? bnbToken['defuse_asset_id'] ?? '';
      final rawAmount = BigInt.from(amount * 1e18).toString();

      final quote = await _near.getQuote(
        originAsset: bnbAssetId as String, destAsset: zecAssetId as String,
        amount: rawAmount, recipient: zecAddress, refundTo: bscAddress,
      );

      final depositAddress = (quote['deposit_address'] ?? quote['depositAddress'] ?? '') as String;
      if (depositAddress.isEmpty) throw Exception('No deposit address in quote');

      progress?.add(const ActionProgress(step: 2, totalSteps: 4, label: 'Sending BNB to bridge...'));
      final bscFees = await _bsc.suggestEip1559Fees(urgent: true);
      final nonce = await _bsc.getNonce(bscAddress);
      final weiAmount = BigInt.from((amount * 1e18).floor());
      final unsignedTxHex = TxBuilder.buildUnsignedEip1559(
        chainId: 56, nonce: nonce,
        maxPriorityFeePerGas: bscFees.maxPriorityFeePerGas,
        maxFeePerGas: bscFees.maxFeePerGas,
        gasLimit: 21000, to: depositAddress, value: weiAmount, data: '0x',
      );
      final depositTxHash = await _bsc.signBroadcastAndWait(seed: seed, unsignedTxHex: unsignedTxHex);

      progress?.add(const ActionProgress(step: 3, totalSteps: 4, label: 'Waiting for swap to complete...'));
      final swapId = (quote['swap_id'] ?? quote['swapId'] ?? '') as String;
      if (swapId.isNotEmpty) {
        await _near.pollStatus(swapId);
      } else {
        await Future.delayed(const Duration(seconds: 30));
      }

      progress?.add(const ActionProgress(step: 4, totalSteps: 4, label: 'BNB swept', status: ActionStatus.done));
      return ActionResult(success: true,
        message: 'Swept ${amount.toStringAsFixed(6)} BNB → ZEC (shielded)\nTX: $depositTxHash');
    } catch (e) {
      return ActionResult(success: false, message: 'Sweep BNB failed: $e');
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Sell position (Myriad)
  // ═════════════════════════════════════════════════════════════════════════

  Future<ActionResult> executeSell({
    required int marketId,
    required int outcomeId,
    required double shares,
    StreamController<ActionProgress>? progress,
  }) async {
    try {
      progress?.add(const ActionProgress(step: 1, totalSteps: 4, label: 'Getting sell quote...'));
      final quote = await _myriad.getQuote(marketId, outcomeId, shares, 5.0);
      if (quote == null) return const ActionResult(success: false, message: 'Failed to get sell quote from Myriad.');

      progress?.add(const ActionProgress(step: 2, totalSteps: 4, label: 'Building transaction...'));
      final seed = await _getSeed();
      final bscAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);
      final bscFees = await _bsc.suggestEip1559Fees(urgent: true);
      final nonce = await _bsc.getNonce(bscAddress);
      final calldataStr = quote['calldata'] as String? ?? '';
      final txHex = TxBuilder.buildUnsignedEip1559(
        chainId: 56, nonce: nonce,
        maxPriorityFeePerGas: bscFees.maxPriorityFeePerGas,
        maxFeePerGas: bscFees.maxFeePerGas,
        gasLimit: 500000, to: myriadContract,
        value: BigInt.zero, data: calldataStr.startsWith('0x') ? calldataStr : '0x$calldataStr',
      );

      progress?.add(const ActionProgress(step: 3, totalSteps: 4, label: 'Signing & broadcasting...'));
      final txHash = await _bsc.signBroadcastAndWait(seed: seed, unsignedTxHex: txHex);

      progress?.add(const ActionProgress(step: 4, totalSteps: 4, label: 'Position sold', status: ActionStatus.done));
      final usdReceived = (quote['value'] as num?)?.toDouble() ?? 0;
      return ActionResult(success: true,
        message: 'Sold ${shares.toStringAsFixed(2)} shares for ~\$${usdReceived.toStringAsFixed(2)} USDT\nTX: $txHash');
    } catch (e) {
      return ActionResult(success: false, message: 'Sell failed: $e');
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Private helpers
  // ═════════════════════════════════════════════════════════════════════════

  Future<String> _getSeed() async {
    final walletId = WalletService.instance.activeWalletId;
    if (walletId == null) throw Exception('No active wallet');
    final key = isTestnet ? '${walletId}_testnet' : walletId;
    final seed = await SecureKeyStore.getSeedForWallet(key);
    if (seed == null) throw Exception('Seed not found in secure storage');
    return seed;
  }

  Future<String> _getRefundAddress() async {
    try {
      final addresses = await rust_engine.engineGetAddresses();
      if (addresses.isNotEmpty) return addresses.first.address;
    } catch (_) {}
    return '';
  }
}
