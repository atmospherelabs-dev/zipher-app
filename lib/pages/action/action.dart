import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:logger/logger.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../accounts.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../../coin/coins.dart' show isTestnet;
import '../../services/chain_config.dart';
import '../../services/wallet_service.dart';
import '../../services/market_venue.dart';
import '../../services/action_executor.dart';
import '../../services/action_history.dart';
import '../../services/evm_portfolio_balance.dart';
import '../../services/evm_rpc.dart';
import '../../services/llm_service.dart';
import '../../services/secure_key_store.dart';
import '../../src/rust/api/engine_api.dart' as rust_engine;
import 'intent.dart';
import 'llm_intent_parser.dart';
import 'models.dart';
import 'widgets/bet_confirmation.dart';
import 'widgets/polymarket_bet_confirmation.dart';
import 'widgets/market_venue_picker.dart';
import 'widgets/sell_confirmation.dart';
import 'widgets/polymarket_sell_confirmation.dart';
import 'widgets/evm_swap_confirmation.dart';
import 'widgets/sweep_confirmation.dart';
import 'widgets/llm_settings_sheet.dart';

final _log = Logger();

class ActionPage extends StatefulWidget {
  const ActionPage({super.key});

  @override
  State<ActionPage> createState() => _ActionPageState();
}

class _ActionPageState extends State<ActionPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final List<ActionMessage> _messages = [];
  bool _processing = false;
  /// Discovery vs trading venue (explicit state for prediction-market flows).
  final PredictionMarketFlowState _marketFlow = PredictionMarketFlowState();

  List<ActionRecord> _history = [];
  bool _historyExpanded = false;

  LlmStatus _llmStatus = LlmStatus.notDownloaded;
  double _llmDownloadProgress = 0;
  StreamSubscription<LlmStatus>? _llmSub;

  bool _balanceLoading = true;
  bool _balanceExpanded = false;
  double _zecBalanceUsd = 0;
  double _zecAmount = 0;
  List<EvmTokenBalance> _evmBalances = [];
  double _evmTotalUsd = 0;

  /// When a Polymarket bet needs an amount, we store the intent here so the
  /// next user input is treated as a dollar amount, not re-parsed by the LLM.
  ParsedIntent? _pendingAmountIntent;

  @override
  void initState() {
    super.initState();
    _fetchAggregatedBalance();
    _loadHistory();
    _initLlm();
    _addSystemMessage('What would you like to do?', card: _buildSuggestionChips());
  }

  @override
  void dispose() {
    _llmSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Balance
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _fetchAggregatedBalance() async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final balance = await WalletService.instance.getBalance();
        final totalZat = (balance.orchard + balance.sapling + balance.transparent).toInt();
        _zecAmount = totalZat / 1e8;
        _zecBalanceUsd = _zecAmount * (marketPrice.price ?? 0.0);
        break;
      } catch (_) {
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        } else {
          final confirmed = aa.poolBalances.confirmed;
          _zecAmount = confirmed / 1e8;
          _zecBalanceUsd = _zecAmount * (marketPrice.price ?? 0.0);
        }
      }
    }

    try {
      final chain = aa.chainAddresses;
      if (chain != null) {
        final r = await EvmPortfolioBalance.fetch(chain.evm, timeout: const Duration(seconds: 12));
        _evmBalances = r.tokens;
        _evmTotalUsd = r.tokens.fold<double>(0, (s, t) => s + t.balanceUsd);
      } else {
        _evmBalances = [];
        _evmTotalUsd = 0;
      }
    } catch (_) {
      _evmBalances = [];
      _evmTotalUsd = 0;
    }

    if (mounted) setState(() => _balanceLoading = false);
  }

  double get _totalUsd => _zecBalanceUsd + _evmTotalUsd;

  /// For sweep UX: derive BNB/USD from last portfolio fetch, else rough default.
  double _bnbUsdPerUnit(double bnbBal) {
    for (final t in _evmBalances) {
      if (t.symbol == 'BNB' && t.chainLabel == 'BSC' && t.balance > 0) {
        return t.balanceUsd / t.balance;
      }
    }
    return 600;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // History & LLM
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _loadHistory() async {
    await ActionHistory.instance.load();
    if (mounted) setState(() => _history = ActionHistory.instance.records);
  }

  Future<void> _initLlm() async {
    await LlmService.instance.initialize();
    _llmSub = LlmService.instance.statusStream.listen((status) {
      if (mounted) setState(() => _llmStatus = status);
    });
    if (mounted) setState(() => _llmStatus = LlmService.instance.status);
    if (LlmService.instance.status == LlmStatus.ready) {
      await LlmService.instance.loadModel();
    }
  }

  void _showLlmSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZipherColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => LlmSettingsSheet(
        initialStatus: _llmStatus,
        downloadProgress: _llmDownloadProgress,
        onDownload: () async {
          Navigator.pop(ctx);
          await LlmService.instance.download(onProgress: (p) {
            if (mounted) setState(() => _llmDownloadProgress = p);
          });
          if (LlmService.instance.status == LlmStatus.ready) await LlmService.instance.loadModel();
        },
        onDelete: () async { Navigator.pop(ctx); await LlmService.instance.deleteModel(); },
        onLoad: () async { Navigator.pop(ctx); await LlmService.instance.loadModel(); },
        onUnload: () async { Navigator.pop(ctx); await LlmService.instance.unloadModel(); },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Chat messaging
  // ═══════════════════════════════════════════════════════════════════════════

  void _addSystemMessage(String text, {Widget? card, IntentType? intentType}) {
    setState(() {
      _messages.add(ActionMessage(text: text, isUser: false, card: card, intentType: intentType));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _handleSubmit(String text) async {
    if (text.trim().isEmpty || _processing) return;

    // Swap chooser: show cross-chain vs per-chain-with-balance options
    if (text == '_swap_chooser') {
      _showSwapChooser();
      return;
    }

    _controller.clear();
    setState(() {
      _messages.add(ActionMessage(text: text.trim(), isUser: true));
      _processing = true;
    });
    _scrollToBottom();

    // If a Polymarket bet is waiting for an amount, extract it from the raw text
    final pending = _pendingAmountIntent;
    if (pending != null) {
      _pendingAmountIntent = null;
      final amount = _extractAmount(text);
      if (amount != null && amount > 0) {
        final withAmount = pending.copyWith(amount: amount);
        await _executeIntent(withAmount);
        final followUp = _buildFollowUpChips(withAmount.type);
        if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
        setState(() => _processing = false);
        _loadHistory();
        return;
      }
      // Couldn't parse an amount — fall through to normal LLM parse
    }

    final intent = await LlmIntentParser.instance.parse(text);
    await _executeIntent(intent);

    final followUp = _buildFollowUpChips(intent.type);
    if (followUp is! SizedBox) _addSystemMessage('', card: followUp);

    setState(() => _processing = false);
    _loadHistory();
  }

  /// Extract a dollar amount from user text like "$4", "4$", "$10.50", "10 usd".
  double? _extractAmount(String text) {
    final cleaned = text.trim().toLowerCase().replaceAll(',', '');
    final patterns = [
      RegExp(r'\$\s*(\d+(?:\.\d+)?)'),
      RegExp(r'(\d+(?:\.\d+)?)\s*\$'),
      RegExp(r'(\d+(?:\.\d+)?)\s*(?:usd|usdc|dollars?)'),
      RegExp(r'^(\d+(?:\.\d+)?)$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(cleaned);
      if (m != null) return double.tryParse(m.group(1)!);
    }
    return null;
  }

  /// Dispatch a known intent directly — no LLM, no parsing delay.
  /// Used by suggestion chips, tap actions, and other pre-classified UI elements.
  Future<void> _submitDirect(ParsedIntent intent, {String? displayText}) async {
    if (_processing) return;
    setState(() {
      _messages.add(ActionMessage(text: displayText ?? intent.summary, isUser: true));
      _processing = true;
    });
    _scrollToBottom();

    await _executeIntent(intent);

    final followUp = _buildFollowUpChips(intent.type);
    if (followUp is! SizedBox) _addSystemMessage('', card: followUp);

    setState(() => _processing = false);
    _loadHistory();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Intent dispatch
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _executeIntent(ParsedIntent intent) async {
    switch (intent.type) {
      case IntentType.help:
        _addSystemMessage('Here\'s what I can do:', card: _buildHelpCard());
      case IntentType.balance:
        await _handleBalance();
      case IntentType.send:
        _handleSend(intent);
      case IntentType.swap:
        _handleSwap(intent);
      case IntentType.evmSwap:
        await _handleEvmSwap(intent);
      case IntentType.shield:
        _handleShield();
      case IntentType.marketSearch:
        _marketFlow.resetDiscovery();
        await _handleMarketSearch(intent);
      case IntentType.marketDiscover:
        _marketFlow.resetDiscovery();
        await _handleMarketDiscover();
      case IntentType.bet:
        await _handleBet(intent);
      case IntentType.betPolymarket:
        await _handleBetPolymarket(intent);
      case IntentType.portfolio:
        await _handlePortfolio();
      case IntentType.sell:
        await _handleSell(intent);
      case IntentType.sweep:
        await _handleSweep();
      case IntentType.unknown:
        final suggestion = await LlmService.instance.suggestForUnknown(intent.raw);
        _addSystemMessage(
          suggestion ?? 'I didn\'t understand that. Try "help" to see what I can do.',
          card: _buildSuggestionChips(items: [
            SuggestionItem(Icons.help_outline, 'Help', 'help',
                intent: const ParsedIntent(type: IntentType.help, raw: 'help')),
            SuggestionItem(Icons.trending_up, 'Find markets', 'find promising markets',
                intent: const ParsedIntent(type: IntentType.marketDiscover, raw: 'find promising markets')),
            SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
                intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          ]),
        );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _handleBalance() async {
    try {
      _fetchAggregatedBalance();
      final balance = await WalletService.instance.getBalance();
      final shieldedZat = (balance.orchard + balance.sapling).toInt();
      final transparentZat = balance.transparent.toInt();
      final totalZat = shieldedZat + transparentZat;
      final total = totalZat / 1e8;
      final shielded = shieldedZat / 1e8;
      final transparent = transparentZat / 1e8;
      final zecUsd = total * (marketPrice.price ?? 0);
      _addSystemMessage('', card: _balanceCard(total, shielded, transparent, zecUsd), intentType: IntentType.balance);
    } catch (e) {
      _addSystemMessage('Failed to get balance.', card: _errorCard(message: '$e', onRetry: _handleBalance));
    }
  }

  Future<void> _handlePortfolio() async {
    if (_marketFlow.trading == MarketVenue.unset) {
      _addSystemMessage('Which platform are your positions on?', card: MarketVenuePickerRow(
        onPick: (v) {
          setState(() => _marketFlow.trading = v);
          _handlePortfolio();
        },
      ));
      return;
    }
    final venue = _marketFlow.trading;
    setState(() => _marketFlow.resetTrading());

    try {
      final seed = await _getSeedForAction();
      final evmAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      if (venue == MarketVenue.polymarket) {
        final positions = await WalletService.instance.getPolymarketPortfolio(evmAddress);
        if (positions.isEmpty) {
          _addSystemMessage('No open Polymarket positions for your Polygon address.', intentType: IntentType.portfolio);
          return;
        }
        _addSystemMessage('', card: _portfolioCard(positions), intentType: IntentType.portfolio);
        return;
      }

      final positions = await WalletService.instance.getPortfolio(evmAddress);
      if (positions.isEmpty) {
        _addSystemMessage('No open positions found.', intentType: IntentType.portfolio);
        return;
      }
      _addSystemMessage('', card: _portfolioCard(positions), intentType: IntentType.portfolio);
    } catch (e) {
      _addSystemMessage('Failed to load portfolio.', card: _errorCard(message: '$e', onRetry: _handlePortfolio));
    }
  }

  Future<void> _handleSell(ParsedIntent intent) async {
    if (_marketFlow.trading == MarketVenue.unset) {
      _addSystemMessage('Which platform is this position on?', card: MarketVenuePickerRow(
        onPick: (v) {
          setState(() => _marketFlow.trading = v);
          _handleSell(intent);
        },
      ));
      return;
    }
    final venue = _marketFlow.trading;
    setState(() => _marketFlow.resetTrading());

    try {
      final seed = await _getSeedForAction();
      final evmAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      if (venue == MarketVenue.polymarket) {
        final positions = await WalletService.instance.getPolymarketPortfolio(evmAddress);
        if (positions.isEmpty) {
          _addSystemMessage('No open Polymarket positions to sell.');
          return;
        }
        _addSystemMessage('Which position do you want to sell? Tap one:', card: _portfolioCard(positions, sellMode: true));
        return;
      }

      final positions = await WalletService.instance.getPortfolio(evmAddress);
      if (positions.isEmpty) { _addSystemMessage('No open positions to sell.'); return; }
      if (intent.marketId != null) {
        final pos = positions.where((p) => (p['market_id'] ?? p['marketId'] ?? 0) == intent.marketId).firstOrNull;
        if (pos == null) { _addSystemMessage('You don\'t have a position on market #${intent.marketId}.'); return; }
        _showSellConfirmation(pos);
      } else {
        _addSystemMessage('Which position do you want to sell? Tap one:', card: _portfolioCard(positions, sellMode: true));
      }
    } catch (e) {
      _addSystemMessage('Failed to load positions: $e');
    }
  }

  void _showPolymarketSellConfirmation(Map<String, dynamic> position) {
    final tokenId = (position['asset'] ?? '').toString();
    final shares = (position['shares'] as num?)?.toDouble() ?? 0;
    final curPrice = (position['current_price'] as num?)?.toDouble() ?? 0;
    final negRisk = position['negative_risk'] == true || position['negativeRisk'] == true;
    final title = position['market_title'] ?? position['title'] ?? 'Polymarket';
    final outcome = position['outcome']?.toString() ?? position['outcome_title']?.toString() ?? '?';
    if (tokenId.isEmpty || shares <= 0 || curPrice <= 0) {
      _addSystemMessage('Cannot sell: missing token, size, or price for this position.');
      return;
    }
    final worstPrice = (curPrice * 0.92).clamp(0.01, 0.99).toDouble();
    _addSystemMessage('', card: PolymarketSellConfirmation(
      tokenId: tokenId,
      marketTitle: title.toString(),
      outcomeTitle: outcome,
      shares: shares,
      worstPrice: worstPrice,
      negRisk: negRisk,
      onResult: (msg) { _addSystemMessage(msg); _fetchAggregatedBalance(); },
    ));
  }

  void _showSellConfirmation(Map<String, dynamic> position) {
    final marketId = position['market_id'] ?? position['marketId'] ?? 0;
    final title = position['market_title'] ?? position['title'] ?? 'Market #$marketId';
    final outcomeTitle = position['outcome_title'] ?? position['outcome'] ?? '?';
    final shares = (position['shares'] as num?)?.toDouble() ?? 0;
    final outcomeId = position['outcome_id'] ?? position['outcomeId'] ?? 0;

    _addSystemMessage('', card: SellConfirmation(
      marketId: (marketId as num).toInt(),
      marketTitle: title.toString(),
      outcomeTitle: outcomeTitle.toString(),
      outcomeId: (outcomeId as num).toInt(),
      shares: shares,
      onResult: (msg) { _addSystemMessage(msg); _fetchAggregatedBalance(); },
    ));
  }

  Future<void> _handleSweep() async {
    try {
      _addSystemMessage('Scanning your BSC wallet...');
      final seed = await _getSeedForAction();
      final bscAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);
      final supportedTokens = await ActionExecutor.instance.getSweepableBscTokens();
      final sweepable = <SweepableToken>[];

      final bscRpc = EvmRpc.bsc;
      final bnbBal = await bscRpc.getNativeBalance(bscAddress);
      final bnbSweepable = bnbBal - 0.003;
      if (bnbSweepable > 0.001) {
        final rate = _bnbUsdPerUnit(bnbBal);
        sweepable.add(SweepableToken(symbol: 'BNB', balance: bnbBal, sweepAmount: bnbSweepable,
            usdValue: bnbSweepable * rate, decimals: 18));
      }

      for (final token in supportedTokens) {
        final symbol = (token['symbol'] as String? ?? '').toUpperCase();
        final contract = token['address'] as String? ?? token['contractAddress'] as String? ?? '';
        final decimals = (token['decimals'] as num?)?.toInt() ?? 18;
        final price = (token['price'] as num?)?.toDouble() ?? 0;
        final defuseId = (token['defuseAssetId'] ?? token['assetId'] ?? token['asset_id'] ?? token['defuse_asset_id'] ?? '') as String;
        if (contract.isEmpty || defuseId.isEmpty) continue;

        try {
          final bal = await bscRpc.getErc20Balance(bscAddress, contract, decimals: decimals);
          if (bal <= 0) continue;
          final usd = price > 0 ? bal * price : (symbol == 'USDT' || symbol == 'USDC' || symbol == 'DAI' || symbol == 'BUSD' ? bal : 0.0);
          if (usd < 0.10) continue;
          sweepable.add(SweepableToken(symbol: symbol, balance: bal, sweepAmount: bal, usdValue: usd,
              contractAddress: contract, defuseAssetId: defuseId, decimals: decimals));
        } catch (_) {}
      }

      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });

      if (sweepable.isEmpty) {
        _addSystemMessage('Nothing to sweep. Your BSC wallet is empty or all balances are below the minimum.');
        return;
      }

      final totalUsd = sweepable.fold<double>(0, (sum, t) => sum + t.usdValue);
      _addSystemMessage('', card: SweepConfirmation(
        tokens: sweepable, totalUsd: totalUsd,
        onResult: (msg) { _addSystemMessage(msg); _fetchAggregatedBalance(); },
      ));
    } catch (e) {
      _addSystemMessage('Failed to scan balances: $e');
    }
  }

  Future<String> _getSeedForAction() async {
    final walletId = WalletService.instance.activeWalletId;
    if (walletId == null) throw Exception('No active wallet');
    final key = isTestnet ? '${walletId}_testnet' : walletId;
    final seed = await SecureKeyStore.getSeedForWallet(key);
    if (seed == null) throw Exception('Seed not found');
    return seed;
  }

  void _handleSend(ParsedIntent intent) {
    if (intent.address == null) { _addSystemMessage('Please provide a destination address.\n\nExample: send 0.5 ZEC to u1abc...'); return; }
    if (intent.amount == null || intent.amount! <= 0) { _addSystemMessage('Please provide an amount.\n\nExample: send 0.5 ZEC to ${intent.address}'); return; }

    final amountZat = (intent.amount! * 1e8).round();
    _addSystemMessage(intent.summary, card: _confirmationCard(
      title: 'Confirm Send',
      details: [
        _detailRow('To', ParsedIntent.truncAddr(intent.address!)),
        _detailRow('Amount', '${intent.amount!.toStringAsFixed(8)} ZEC'),
        _detailRow('Amount', '$amountZat zatoshis'),
        if (intent.memo != null) _detailRow('Memo', intent.memo!),
      ],
      onConfirm: () async {
        _addSystemMessage('Preparing transaction...');
        try {
          final result = await WalletService.instance.proposeSend(intent.address!, amountZat, memo: intent.memo);
          _addSystemMessage('Transaction proposed.\n\n  Amount: ${(result.sendAmount / 1e8).toStringAsFixed(8)} ZEC\n  Fee:    ${(result.fee / 1e8).toStringAsFixed(8)} ZEC\n\nConfirm in the send screen to broadcast.');
        } catch (e) { _addSystemMessage('Send failed: $e'); }
      },
      onCancel: () => _addSystemMessage('Send cancelled.'),
    ), intentType: IntentType.send);
  }

  void _showSwapChooser() {
    _messages.add(ActionMessage(text: 'Swap', isUser: true));
    setState(() {});
    _scrollToBottom();

    final chips = <SuggestionItem>[
      SuggestionItem(Icons.swap_vert, 'Cross-chain (ZEC)', 'swap',
          intent: const ParsedIntent(type: IntentType.swap, raw: 'swap')),
    ];

    // Add one chip per EVM chain where the user has native balance
    final seen = <String>{};
    for (final t in _evmBalances) {
      if (seen.contains(t.chainLabel)) continue;
      if (t.balance <= 0) continue;
      // Only show for native tokens (POL, BNB) -- they indicate chain activity
      final isNative = (t.chainLabel == 'Polygon' && (t.symbol == 'POL' || t.symbol == 'MATIC'))
          || (t.chainLabel == 'BSC' && t.symbol == 'BNB');
      if (!isNative) continue;
      seen.add(t.chainLabel);
      final chainLower = t.chainLabel.toLowerCase();
      chips.add(SuggestionItem(
        Icons.swap_horiz,
        'Swap on ${t.chainLabel}',
        'swap on $chainLower',
      ));
    }

    _addSystemMessage(
      'What kind of swap?',
      card: _buildSuggestionChips(items: chips),
    );
  }

  void _handleSwap(ParsedIntent intent) {
    final from = intent.fromToken ?? 'ZEC';
    final to = intent.toToken;
    if (to == null) { _addSystemMessage('Please specify the destination token.\n\nExample: swap 1 ZEC to USDT'); return; }
    if (intent.amount == null || intent.amount! <= 0) { _addSystemMessage('Please specify the amount.\n\nExample: swap 1 $from to $to'); return; }

    _addSystemMessage(intent.summary, card: _confirmationCard(
      title: 'Confirm Swap',
      details: [_detailRow('From', '${intent.amount!.toStringAsFixed(4)} $from'), _detailRow('To', to), _detailRow('Via', 'NEAR Intents (cross-chain)')],
      onConfirm: () {
        _addSystemMessage('Starting cross-chain swap...');
        HapticFeedback.mediumImpact();
        ActionExecutor.instance.executeSwap(amountZec: intent.amount!, toToken: to).listen((progress) {
          final icon = progress.isFailed ? 'X' : progress.isComplete ? '+' : '>';
          _addSystemMessage('[$icon] Step ${progress.step}/${progress.totalSteps}: ${progress.label}\n${progress.detail}');
          if (progress.isComplete) HapticFeedback.heavyImpact();
          if (progress.isFailed) HapticFeedback.vibrate();
        });
      },
      onCancel: () => _addSystemMessage('Swap cancelled.'),
    ), intentType: IntentType.swap);
  }

  Future<void> _handleEvmSwap(ParsedIntent intent) async {
    final from = intent.fromToken;
    final to = intent.toToken;
    if (from == null || to == null) {
      final chainLabel = intent.chain ?? 'EVM';
      // Show the user what they have on this chain
      final relevant = _evmBalances.where((t) =>
          t.chainLabel.toLowerCase() == chainLabel.toLowerCase() && t.balance > 0).toList();
      final balStr = relevant.isNotEmpty
          ? relevant.map((t) => '${t.balance.toStringAsFixed(4)} ${t.symbol}').join(', ')
          : 'no tokens found';
      _addSystemMessage(
        'Your $chainLabel balances: $balStr\n\n'
        'Tell me what to swap, e.g.:\n'
        '  swap 1 POL to USDC.e\n'
        '  swap 10 USDC.e to POL',
      );
      return;
    }
    if (intent.amount == null || intent.amount! <= 0) {
      _addSystemMessage('Please specify the amount.\n\nExample: swap 1 $from to $to');
      return;
    }

    // Resolve chain config
    ChainConfig? chain;
    if (intent.chain != null) {
      final chainLower = intent.chain!.toLowerCase();
      if (chainLower == 'polygon') chain = ChainConfig.polygon;
      else if (chainLower == 'bsc') chain = ChainConfig.bsc;
    }
    if (chain == null) {
      _addSystemMessage('Could not determine which chain to swap on.\n\nTry: swap 1 $from to $to on polygon');
      return;
    }

    // Resolve token addresses and decimals
    final srcResolved = _resolveEvmToken(from, chain);
    final destResolved = _resolveEvmToken(to, chain);
    if (srcResolved == null) {
      _addSystemMessage('Unknown token: $from on ${chain.name}');
      return;
    }
    if (destResolved == null) {
      _addSystemMessage('Unknown token: $to on ${chain.name}');
      return;
    }

    _addSystemMessage('', card: EvmSwapConfirmation(
      fromToken: from,
      toToken: to,
      amount: intent.amount!,
      chain: chain,
      srcAddress: srcResolved.$1,
      srcDecimals: srcResolved.$2,
      destAddress: destResolved.$1,
      destDecimals: destResolved.$2,
      onResult: (msg) { _addSystemMessage(msg); _fetchAggregatedBalance(); },
      onBalanceChanged: _fetchAggregatedBalance,
    ), intentType: IntentType.evmSwap);
  }

  /// Resolve a token symbol to (address, decimals) on a given chain.
  (String, int)? _resolveEvmToken(String symbol, ChainConfig chain) {
    final upper = symbol.toUpperCase();

    // Native token
    if (upper == chain.nativeSymbol.toUpperCase() ||
        upper == 'MATIC' && chain.nativeSymbol == 'POL') {
      return ('0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', chain.nativeDecimals);
    }

    // Known tokens on this chain
    final info = chain.knownTokens[upper];
    if (info != null) return (info.address, info.decimals);

    // Common aliases
    if (upper == 'USDC.E' && chain.knownTokens.containsKey('USDC.e')) {
      final t = chain.knownTokens['USDC.e']!;
      return (t.address, t.decimals);
    }

    return null;
  }

  void _handleShield() {
    _addSystemMessage('Shield transparent funds', card: _confirmationCard(
      title: 'Confirm Shielding',
      details: [_detailRow('Action', 'Move transparent ZEC to shielded pool'), _detailRow('Privacy', 'Your funds become fully private')],
      onConfirm: () async {
        _addSystemMessage('Shielding in progress...');
        try {
          await WalletService.instance.shieldFunds();
          _addSystemMessage('Shielding complete. Transparent funds moved to Orchard pool.');
        } catch (e) { _addSystemMessage('Shielding failed: $e'); }
      },
      onCancel: () => _addSystemMessage('Shielding cancelled.'),
    ), intentType: IntentType.shield);
  }

  Future<void> _handleMarketSearch(ParsedIntent intent) async {
    if (_marketFlow.discovery == MarketVenue.unset) {
      _addSystemMessage('Where do you want to search?', card: MarketVenuePickerRow(
        onPick: (v) {
          setState(() => _marketFlow.discovery = v);
          _handleMarketSearch(intent);
        },
      ));
      return;
    }

    final platformLabel = _marketFlow.discovery == MarketVenue.polymarket ? 'Polymarket' : 'Myriad';
    _addSystemMessage('Searching $platformLabel...', card: _loadingCard());
    try {
      List<Map<String, dynamic>> markets = [];
      List<Map<String, dynamic>> polymarketRows = [];

      if (_marketFlow.discovery == MarketVenue.polymarket) {
        try {
          polymarketRows = await WalletService.instance.polymarketDiscoveryRows(
            keyword: intent.query,
            limit: 20,
          );
          _log.i('[Markets] Polymarket discovery rows: ${polymarketRows.length}');
        } catch (e) {
          _log.e('[Markets] Polymarket search failed: $e');
          setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
          _addSystemMessage('Polymarket search failed.', card: _errorCard(message: '$e', onRetry: () => _handleMarketSearch(intent)));
          return;
        }
      } else {
        try {
          markets = await WalletService.instance.searchMarkets(intent.query);
          for (final m in markets) { m['_provider'] = 'myriad'; }
          _log.i('[Markets] Myriad returned ${markets.length} results');
        } catch (e) {
          _log.e('[Markets] Myriad search failed: $e');
          setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
          _addSystemMessage('Myriad search failed.', card: _errorCard(message: '$e', onRetry: () => _handleMarketSearch(intent)));
          return;
        }
      }

      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      if (_marketFlow.discovery == MarketVenue.polymarket) {
        if (polymarketRows.isEmpty) {
          _addSystemMessage('No markets found on $platformLabel${intent.query != null ? ' for "${intent.query}"' : ''}.');
          return;
        }
        LlmIntentParser.instance.setPolymarketRows(polymarketRows);
        LlmIntentParser.instance.setContext(LlmIntentParser.polymarketDiscoveryContext(polymarketRows));
        _addSystemMessage(
          'Tap a market to bet:',
          card: _polymarketDiscoveryCard(polymarketRows),
          intentType: IntentType.marketSearch,
        );
        return;
      }
      if (markets.isEmpty) { _addSystemMessage('No markets found on $platformLabel${intent.query != null ? ' for "${intent.query}"' : ''}.'); return; }
      LlmIntentParser.instance.setContext(LlmIntentParser.marketsContext(markets));
      _addSystemMessage('Found ${markets.length} markets on $platformLabel:', card: _marketListCard(markets), intentType: IntentType.marketSearch);
    } catch (e) {
      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      _addSystemMessage('Market search failed.', card: _errorCard(message: '$e', onRetry: () => _handleMarketSearch(intent)));
    }
  }

  Future<void> _handleMarketDiscover() async {
    if (_marketFlow.discovery == MarketVenue.unset) {
      _addSystemMessage('Which platform?', card: MarketVenuePickerRow(
        onPick: (v) {
          setState(() => _marketFlow.discovery = v);
          _handleMarketDiscover();
        },
      ));
      return;
    }

    final platformLabel = _marketFlow.discovery == MarketVenue.polymarket ? 'Polymarket' : 'Myriad';
    _addSystemMessage('Looking for trending $platformLabel markets...', card: _loadingCard());
    try {
      List<Map<String, dynamic>> markets = [];
      List<Map<String, dynamic>> polymarketRows = [];

      if (_marketFlow.discovery == MarketVenue.polymarket) {
        try {
          polymarketRows = await WalletService.instance.polymarketDiscoveryRows(keyword: null, limit: 20);
          _log.i('[Markets] Polymarket discover rows: ${polymarketRows.length}');
        } catch (e) {
          _log.e('[Markets] Polymarket discover failed: $e');
          setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
          _addSystemMessage('Polymarket fetch failed.', card: _errorCard(message: '$e', onRetry: _handleMarketDiscover));
          return;
        }
      } else {
        try {
          final raw = await WalletService.instance.searchMarkets('');
          for (final m in raw) { m['_provider'] = 'myriad'; }
          markets = raw.where((m) {
            if ((m['state'] as String? ?? '') != 'open') return false;
            final outcomes = (m['outcomes'] as List<dynamic>?) ?? [];
            if (outcomes.length < 2) return false;
            final prices = outcomes.map((o) => ((o as Map)['price'] as num?)?.toDouble() ?? 0).toList();
            if (prices.every((p) => p == 0) || prices.any((p) => p > 0.85)) return false;
            return ((m['volume'] as num?)?.toDouble() ?? 0) > 100;
          }).toList();
          _log.i('[Markets] Myriad discover returned ${markets.length} results');
        } catch (e) {
          _log.e('[Markets] Myriad discover failed: $e');
          setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
          _addSystemMessage('Myriad fetch failed.', card: _errorCard(message: '$e', onRetry: _handleMarketDiscover));
          return;
        }
      }

      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      if (_marketFlow.discovery == MarketVenue.polymarket) {
        if (polymarketRows.isEmpty) {
          _addSystemMessage('No active markets found on $platformLabel right now.');
          return;
        }
        LlmIntentParser.instance.setPolymarketRows(polymarketRows);
        LlmIntentParser.instance.setContext(LlmIntentParser.polymarketDiscoveryContext(polymarketRows));
        _addSystemMessage(
          'Tap a market to bet:',
          card: _polymarketDiscoveryCard(polymarketRows),
          intentType: IntentType.marketDiscover,
        );
        return;
      }
      if (markets.isEmpty) { _addSystemMessage('No active markets found on $platformLabel right now.'); return; }
      LlmIntentParser.instance.setContext(LlmIntentParser.marketsContext(markets));
      _addSystemMessage('Trending on $platformLabel:', card: _marketListCard(markets), intentType: IntentType.marketDiscover);
    } catch (e) {
      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      _addSystemMessage('Could not fetch markets.', card: _errorCard(message: '$e', onRetry: _handleMarketDiscover));
    }
  }

  Future<void> _handleBet(ParsedIntent intent) async {
    if (intent.marketId == null) {
      if (_marketFlow.trading == MarketVenue.unset) {
        _addSystemMessage('Which prediction market?', card: MarketVenuePickerRow(
          onPick: (v) {
            setState(() => _marketFlow.trading = v);
            _handleBet(intent);
          },
        ));
        return;
      }
      if (_marketFlow.trading == MarketVenue.polymarket) {
        setState(() => _marketFlow.resetTrading());
        _addSystemMessage(
          'Polymarket uses a hex condition id (0x…), not a numeric market #.\n\n'
          'Try find markets with Polymarket selected, then tap a row, or:\n'
          'bet \$5 yes on polymarket 0x…',
        );
        return;
      }
      setState(() => _marketFlow.resetTrading());
      _addSystemMessage('Please specify a Myriad market ID.\n\nExample: bet \$5 yes on market #27498');
      return;
    }

    setState(() => _marketFlow.resetTrading());

    if (intent.amount == null || intent.amount! <= 0) {
      _pendingAmountIntent = intent;
      _addSystemMessage('How much do you want to bet on market #${intent.marketId}?\n\nJust type an amount (e.g. \$5).');
      return;
    }

    _addSystemMessage('Fetching market #${intent.marketId} details...', card: _loadingCard());
    final market = await WalletService.instance.getMarketDetails(intent.marketId!);
    setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
    if (market == null) { _addSystemMessage('Could not fetch market #${intent.marketId}. It may not exist.'); return; }

    final outcomes = (market['outcomes'] as List<dynamic>?) ?? [];
    if (outcomes.isEmpty) { _addSystemMessage('Market #${intent.marketId} has no outcomes listed.'); return; }

    final title = market['title'] ?? market['question'] ?? 'Market #${intent.marketId}';
    final tokenInfo = market['token'] as Map<String, dynamic>?;
    final tokenSymbol = tokenInfo?['symbol'] as String? ?? 'USDT';
    final isBinary = outcomes.length == 2 && _isBinaryOutcome(outcomes[0]['title']?.toString() ?? '') && _isBinaryOutcome(outcomes[1]['title']?.toString() ?? '');

    if (isBinary) {
      if (intent.direction != null) {
        final outcomeIdx = intent.direction == 'no' ? 1 : 0;
        final o = outcomes[outcomeIdx];
        _showBetConfirmation(marketId: intent.marketId!, marketTitle: title, amount: intent.amount!,
            outcomeId: (o['outcome_id'] as num?)?.toInt() ?? outcomeIdx,
            outcomeTitle: o['title']?.toString() ?? (outcomeIdx == 0 ? 'Yes' : 'No'), tokenSymbol: tokenSymbol);
      } else {
        _addSystemMessage('$title\n\nWhich direction?', card: _directionPicker(
            marketId: intent.marketId!, marketTitle: title, amount: intent.amount!, outcomes: outcomes, tokenSymbol: tokenSymbol));
      }
    } else {
      _addSystemMessage('$title\n\nPick an outcome:', card: _outcomePicker(
          marketId: intent.marketId!, marketTitle: title, amount: intent.amount!, outcomes: outcomes, tokenSymbol: tokenSymbol),
          intentType: IntentType.bet);
    }
  }

  Future<void> _handleBetPolymarket(ParsedIntent intent) async {
    // Multi-runner event: show runner picker
    if (intent.polymarketRunners != null && intent.polymarketRunners!.isNotEmpty) {
      final eventTitle = intent.polymarketEventTitle ?? 'Polymarket';
      _addSystemMessage('$eventTitle\n\nPick a runner:', card: _polymarketRunnerPicker(
        runners: intent.polymarketRunners!,
        amount: intent.amount,
        direction: intent.direction,
      ), intentType: IntentType.betPolymarket);
      return;
    }

    final hasPolyId = intent.polymarketId != null && intent.polymarketId!.isNotEmpty;
    if (!hasPolyId) {
      if (_marketFlow.trading == MarketVenue.unset) {
        _addSystemMessage('Which prediction market?', card: MarketVenuePickerRow(
          onPick: (v) {
            setState(() => _marketFlow.trading = v);
            _handleBetPolymarket(intent);
          },
        ));
        return;
      }
      if (_marketFlow.trading == MarketVenue.myriad) {
        setState(() => _marketFlow.resetTrading());
        _addSystemMessage('For Myriad, use a numeric market id.\n\nExample: bet \$5 yes on market #27498');
        return;
      }
      setState(() => _marketFlow.resetTrading());
      _addSystemMessage(
        'Specify a Polymarket condition id (0x…), or tap a market from search.\n\nExample: bet \$5 yes on polymarket 0x…',
      );
      return;
    }

    setState(() => _marketFlow.resetTrading());

    _addSystemMessage('Fetching Polymarket details...', card: _loadingCard());
    Map<String, dynamic>? market;
    try {
      market = await WalletService.instance.getPolymarketMarket(intent.polymarketId!);
    } catch (_) {}

    if (market == null) {
      // Try to find it in recently displayed markets by matching condition_id
      final normalized = await WalletService.instance.searchPolymarketMarkets('');
      final match = normalized.where((m) {
        final cid = m['condition_id'] ?? m['conditionId'] ?? '';
        return cid == intent.polymarketId;
      }).firstOrNull;
      if (match != null) market = match;
    }

    setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });

    if (market == null) {
      _addSystemMessage('Could not fetch Polymarket market ${intent.polymarketId}.\n\nTry searching for markets first.');
      return;
    }

    // Normalize if not already normalized
    final rawOutcomes = market['outcomes'];
    List<Map<String, dynamic>> outcomes;
    if (rawOutcomes is List) {
      outcomes = rawOutcomes.map((o) {
        if (o is Map<String, dynamic>) return o;
        return <String, dynamic>{};
      }).where((o) => o.isNotEmpty).toList();
    } else {
      outcomes = [];
    }

    // Fallback: try to build outcomes from raw Gamma fields
    if (outcomes.isEmpty) {
      final outcomePrices = market['outcomePrices'] as String? ?? market['outcome_prices'] as String? ?? '[]';
      final outcomeLabels = market['outcomes'] as String? ?? '["Yes","No"]';
      final tokenIds = market['clobTokenIds'] as String? ?? market['clob_token_ids'] as String? ?? '[]';
      List<dynamic> prices = [], labels = [], tokens = [];
      try { prices = json.decode(outcomePrices) as List; } catch (_) {}
      try { labels = json.decode(outcomeLabels) as List; } catch (_) {}
      try { tokens = json.decode(tokenIds) as List; } catch (_) {}
      for (var i = 0; i < labels.length; i++) {
        outcomes.add({
          'title': labels[i]?.toString() ?? 'Outcome $i',
          'price': i < prices.length ? (double.tryParse(prices[i].toString()) ?? 0) : 0.0,
          'outcome_id': i,
          'token_id': i < tokens.length ? tokens[i].toString() : '',
        });
      }
    }

    if (outcomes.isEmpty) {
      _addSystemMessage('This Polymarket market has no outcomes listed.');
      return;
    }

    final title = market['title'] ?? market['question'] ?? 'Polymarket';
    final negRisk = market['neg_risk'] as bool? ?? market['negRisk'] as bool? ?? false;

    if (intent.amount == null || intent.amount! <= 0) {
      _pendingAmountIntent = intent;
      _addSystemMessage('How much do you want to bet on "$title"?\n\nJust type an amount (e.g. \$5).');
      return;
    }

    // Binary market with direction specified
    final isBinary = outcomes.length == 2 &&
        _isBinaryOutcome(outcomes[0]['title']?.toString() ?? '') &&
        _isBinaryOutcome(outcomes[1]['title']?.toString() ?? '');

    if (isBinary && intent.direction != null) {
      final idx = intent.direction == 'no' ? 1 : 0;
      final o = outcomes[idx];
      _showPolymarketBetConfirmation(
        conditionId: intent.polymarketId!,
        marketTitle: title.toString(),
        amount: intent.amount!,
        outcomeIndex: idx,
        outcomeTitle: o['title']?.toString() ?? (idx == 0 ? 'Yes' : 'No'),
        tokenId: o['token_id']?.toString() ?? '',
        price: (o['price'] as num?)?.toDouble() ?? 0,
        negRisk: negRisk,
      );
    } else if (isBinary) {
      _addSystemMessage('$title\n\nWhich direction?', card: _polymarketDirectionPicker(
        conditionId: intent.polymarketId!,
        marketTitle: title.toString(),
        amount: intent.amount!,
        outcomes: outcomes,
        negRisk: negRisk,
      ));
    } else {
      _addSystemMessage('$title\n\nPick an outcome:', card: _polymarketOutcomePicker(
        conditionId: intent.polymarketId!,
        marketTitle: title.toString(),
        amount: intent.amount!,
        outcomes: outcomes,
        negRisk: negRisk,
      ), intentType: IntentType.betPolymarket);
    }
  }

  void _showPolymarketBetConfirmation({
    required String conditionId,
    required String marketTitle,
    required double amount,
    required int outcomeIndex,
    required String outcomeTitle,
    required String tokenId,
    required double price,
    required bool negRisk,
  }) {
    if (tokenId.isEmpty) {
      _addSystemMessage('This outcome has no CLOB token ID — it cannot be traded yet.');
      return;
    }

    _addSystemMessage('', card: PolymarketBetConfirmation(
      conditionId: conditionId,
      marketTitle: marketTitle,
      amount: amount,
      outcomeIndex: outcomeIndex,
      outcomeTitle: outcomeTitle,
      tokenId: tokenId,
      price: price,
      negRisk: negRisk,
      onResult: _addSystemMessage,
      onBalanceChanged: _fetchAggregatedBalance,
    ), intentType: IntentType.betPolymarket);
  }

  Widget _polymarketDirectionPicker({
    required String conditionId,
    required String marketTitle,
    required double amount,
    required List<Map<String, dynamic>> outcomes,
    required bool negRisk,
  }) {
    final yesPrice = ((outcomes[0]['price'] as num?)?.toDouble() ?? 0) * 100;
    final noPrice = ((outcomes[1]['price'] as num?)?.toDouble() ?? 0) * 100;

    Widget dirBtn(String label, Color color, int idx, double pct) => Expanded(
      child: Material(color: Colors.transparent, child: InkWell(
        onTap: () => _showPolymarketBetConfirmation(
          conditionId: conditionId, marketTitle: marketTitle, amount: amount,
          outcomeIndex: idx, outcomeTitle: label,
          tokenId: outcomes[idx]['token_id']?.toString() ?? '',
          price: (outcomes[idx]['price'] as num?)?.toDouble() ?? 0,
          negRisk: negRisk,
        ),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: label == 'Yes' ? 0.1 : 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: label == 'Yes' ? 0.3 : 0.2)),
          ),
          child: Column(children: [
            Text(label, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w700)),
            const Gap(4),
            Text('${pct.toStringAsFixed(0)}%', style: TextStyle(color: ZipherColors.text40, fontSize: 12, fontFamily: 'JetBrains Mono')),
          ]),
        ),
      )),
    );

    return Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: [
      dirBtn('Yes', const Color(0xFF6366F1), 0, yesPrice), const Gap(12),
      dirBtn('No', Colors.redAccent.withValues(alpha: 0.9), 1, noPrice),
    ]));
  }

  Widget _polymarketOutcomePicker({
    required String conditionId,
    required String marketTitle,
    required double amount,
    required List<Map<String, dynamic>> outcomes,
    required bool negRisk,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: outcomes.map((o) {
        final oTitle = o['title']?.toString() ?? '?';
        final price = (o['price'] as num?)?.toDouble() ?? 0;
        final idx = outcomes.indexOf(o);
        final pctLabel = '${(price * 100).toStringAsFixed(0)}%';
        return InkWell(
          onTap: () => _showPolymarketBetConfirmation(
            conditionId: conditionId, marketTitle: marketTitle, amount: amount,
            outcomeIndex: idx, outcomeTitle: oTitle,
            tokenId: o['token_id']?.toString() ?? '',
            price: price, negRisk: negRisk,
          ),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), child: Row(children: [
            Container(width: 32, height: 32,
                decoration: BoxDecoration(color: const Color(0xFF6366F1).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Center(child: Text(pctLabel,
                    style: const TextStyle(color: Color(0xFF6366F1), fontSize: 10, fontWeight: FontWeight.w700, fontFamily: 'JetBrains Mono')))),
            const Gap(12),
            Expanded(child: Text(oTitle, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500))),
            Icon(Icons.chevron_right, color: ZipherColors.text40, size: 18),
          ])),
        );
      }).toList()),
    );
  }

  Widget _polymarketRunnerPicker({
    required List<Map<String, dynamic>> runners,
    double? amount,
    String? direction,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: runners.map((r) {
        final label = r['label']?.toString() ?? '?';
        final price = (r['price'] as num?)?.toDouble() ?? 0;
        final cid = r['condition_id']?.toString() ?? '';
        final pctLabel = '${(price * 100).toStringAsFixed(0)}%';
        if (cid.isEmpty) return const SizedBox.shrink();
        return InkWell(
          onTap: () => _submitDirect(
            ParsedIntent(type: IntentType.betPolymarket, raw: 'bet on $label',
                polymarketId: cid, amount: amount, direction: direction),
            displayText: 'Bet on $label',
          ),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), child: Row(children: [
            Container(width: 32, height: 32,
                decoration: BoxDecoration(color: const Color(0xFF6366F1).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Center(child: Text(pctLabel,
                    style: const TextStyle(color: Color(0xFF6366F1), fontSize: 10, fontWeight: FontWeight.w700, fontFamily: 'JetBrains Mono')))),
            const Gap(12),
            Expanded(child: Text(label, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500))),
            Icon(Icons.chevron_right, color: ZipherColors.text40, size: 18),
          ])),
        );
      }).toList()),
    );
  }

  bool _isBinaryOutcome(String title) {
    final t = title.toLowerCase().trim();
    return t == 'yes' || t == 'no';
  }

  void _showBetConfirmation({required int marketId, required String marketTitle, required double amount,
      required int outcomeId, required String outcomeTitle, String tokenSymbol = 'USDT'}) async {
    String summaryText = 'Bet \$${amount.toStringAsFixed(2)} on "$outcomeTitle"';
    try {
      final market = await WalletService.instance.getMarketDetails(marketId);
      if (market != null) {
        final outcomes = (market['outcomes'] as List<dynamic>?) ?? [];
        final llmSummary = await LlmService.instance.summarizeMarket(
            title: marketTitle, outcomes: outcomes.map((o) => o as Map<String, dynamic>).toList());
        if (llmSummary != null && llmSummary.isNotEmpty) summaryText = llmSummary;
      }
    } catch (_) {}

    _addSystemMessage(summaryText, card: BetConfirmation(
      marketId: marketId, marketTitle: marketTitle, amount: amount,
      outcomeId: outcomeId, outcomeTitle: outcomeTitle, tokenSymbol: tokenSymbol,
      onResult: _addSystemMessage, onBalanceChanged: _fetchAggregatedBalance,
    ), intentType: IntentType.bet);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Card builders (inline, non-stateful)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Polymarket discovery: one card per Gamma event (grouped multi-outcome or single binary).
  Widget _polymarketDiscoveryCard(List<Map<String, dynamic>> rows) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: ZipherColors.borderSubtle.withValues(alpha: 0.5)),
            _polymarketDiscoveryRow(rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _polymarketDiscoveryRow(Map<String, dynamic> row) {
    final kind = row['kind'] as String? ?? 'single';
    final title = row['title']?.toString() ?? '?';
    final runners = (row['top_runners'] as List<dynamic>?) ?? [];

    // For single-runner events, tapping the whole row opens that market
    final singleCid = runners.length == 1
        ? (runners.first as Map<String, dynamic>)['condition_id']?.toString() ?? ''
        : '';

    return InkWell(
      onTap: singleCid.isNotEmpty
          ? () => _submitDirect(
                ParsedIntent(type: IntentType.betPolymarket, raw: 'bet on polymarket $singleCid', polymarketId: singleCid),
                displayText: title.toString(),
              )
          : null,
      borderRadius: BorderRadius.circular(ZipherRadius.md),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(3)),
                child: Text(kind == 'grouped' ? 'PM+' : 'PM',
                    style: const TextStyle(color: Color(0xFF6366F1), fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'JetBrains Mono')),
              ),
              const Gap(6),
              Expanded(
                  child: Text(title,
                      style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis)),
              if (singleCid.isNotEmpty)
                Icon(Icons.chevron_right, color: ZipherColors.text40, size: 18),
            ]),
            if (runners.length > 1) ...[
              const Gap(8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: runners.map<Widget>((u) {
                  final m = u as Map<String, dynamic>;
                  final lab = m['label']?.toString() ?? '?';
                  final pr = (m['price'] as num?)?.toDouble() ?? 0;
                  final cid = m['condition_id']?.toString() ?? '';
                  if (cid.isEmpty) return const SizedBox.shrink();
                  return Material(
                    color: ZipherColors.cardBgElevated,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      onTap: () => _submitDirect(
                        ParsedIntent(type: IntentType.betPolymarket, raw: 'bet on polymarket $cid', polymarketId: cid),
                        displayText: 'Bet on $lab ($title)',
                      ),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text('$lab ${(pr * 100).toStringAsFixed(0)}%',
                            style: TextStyle(color: ZipherColors.text60, fontSize: 11, fontFamily: 'JetBrains Mono')),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ] else if (runners.length == 1) ...[
              const Gap(4),
              Text('${((runners.first as Map)['price'] as num? ?? 0) * 100 ~/ 1}% Yes',
                  style: TextStyle(color: ZipherColors.text40, fontSize: 11, fontFamily: 'JetBrains Mono')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionChips({List<SuggestionItem>? items}) {
    final chips = items ?? [
      SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
          intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
      SuggestionItem(Icons.swap_horiz, 'Swap', '_swap_chooser'),
      SuggestionItem(Icons.trending_up, 'Find markets', 'find promising markets',
          intent: const ParsedIntent(type: IntentType.marketDiscover, raw: 'find promising markets')),
      SuggestionItem(Icons.pie_chart_outline, 'My bets', 'my bets',
          intent: const ParsedIntent(type: IntentType.portfolio, raw: 'my bets')),
      SuggestionItem(Icons.help_outline, 'Help', 'help',
          intent: const ParsedIntent(type: IntentType.help, raw: 'help')),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 8,
          children: chips.map((c) => _chipButton(icon: c.icon, label: c.label,
              onTap: () => c.intent != null
                  ? _submitDirect(c.intent!, displayText: c.label)
                  : _handleSubmit(c.command))).toList()),
    );
  }

  Widget _buildFollowUpChips(IntentType after) {
    final List<SuggestionItem> chips;
    switch (after) {
      case IntentType.balance:
        chips = [
          SuggestionItem(Icons.trending_up, 'Find markets', 'find promising markets',
              intent: const ParsedIntent(type: IntentType.marketDiscover, raw: 'find promising markets')),
          SuggestionItem(Icons.swap_horiz, 'Sweep', 'sweep',
              intent: const ParsedIntent(type: IntentType.sweep, raw: 'sweep')),
        ];
      case IntentType.bet:
      case IntentType.betPolymarket:
        chips = [
          SuggestionItem(Icons.pie_chart_outline, 'My bets', 'my bets',
              intent: const ParsedIntent(type: IntentType.portfolio, raw: 'my bets')),
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
        ];
      case IntentType.portfolio:
        chips = [
          SuggestionItem(Icons.swap_horiz, 'Sweep', 'sweep',
              intent: const ParsedIntent(type: IntentType.sweep, raw: 'sweep')),
          SuggestionItem(Icons.trending_up, 'Find markets', 'find promising markets',
              intent: const ParsedIntent(type: IntentType.marketDiscover, raw: 'find promising markets')),
        ];
      case IntentType.sweep:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          SuggestionItem(Icons.pie_chart_outline, 'My bets', 'my bets',
              intent: const ParsedIntent(type: IntentType.portfolio, raw: 'my bets')),
        ];
      case IntentType.evmSwap:
      case IntentType.swap:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          SuggestionItem(Icons.swap_horiz, 'Swap again', '_swap_chooser'),
        ];
      case IntentType.marketDiscover:
      case IntentType.marketSearch:
        chips = [
          SuggestionItem(Icons.refresh, 'Switch platform', 'find promising markets',
              intent: const ParsedIntent(type: IntentType.marketDiscover, raw: 'find promising markets')),
          SuggestionItem(Icons.pie_chart_outline, 'My bets', 'my bets',
              intent: const ParsedIntent(type: IntentType.portfolio, raw: 'my bets')),
        ];
      default:
        chips = const [];
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return _buildSuggestionChips(items: chips);
  }

  Widget _chipButton({required IconData icon, required String label, required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(20),
            border: Border.all(color: ZipherColors.borderSubtle),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: ZipherColors.cyan),
            const Gap(6),
            Text(label, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  Widget _balanceCard(double total, double shielded, double transparent, double zecUsd) {
    final grandTotal = zecUsd + _evmTotalUsd;
    return Container(
      margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ClipOval(child: Image.asset('assets/tokens/zec.png', width: 20, height: 20)),
          const Gap(8),
          Text('${total.toStringAsFixed(4)} ZEC',
              style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w600, fontFamily: 'JetBrains Mono')),
        ]),
        if (zecUsd > 0) ...[const Gap(4), Text('\$${zecUsd.toStringAsFixed(2)} USD', style: TextStyle(color: ZipherColors.text40, fontSize: 14))],
        const Gap(12),
        _miniBar('Shielded', shielded, total, ZipherColors.cyan),
        const Gap(6),
        _miniBar('Transparent', transparent, total, ZipherColors.warm),
        for (var i = 0; i < _evmBalances.length; i++) ...[
          if (i == 0) const Gap(12) else const Gap(6),
          _tokenBalanceRowFromEvm(_evmBalances[i]),
        ],
        if (grandTotal > 0) ...[
          const Gap(12), Divider(height: 1, color: ZipherColors.borderSubtle), const Gap(8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Total', style: TextStyle(color: ZipherColors.text40, fontSize: 12)),
            Text('\$${grandTotal.toStringAsFixed(2)}', style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        ],
      ]),
    );
  }

  Widget _tokenBalanceRowFromEvm(EvmTokenBalance t) {
    final amountStr = t.balance >= 1 ? t.balance.toStringAsFixed(4) : t.balance.toStringAsFixed(6);
    return Row(children: [
      _evmTokenIcon(t.symbol, networkUrl: t.thumbnailUrl),
      const Gap(8),
      Expanded(child: Text('$amountStr ${t.symbol} · ${t.chainLabel}',
          style: const TextStyle(color: ZipherColors.textSecondary, fontSize: 12, fontFamily: 'JetBrains Mono'), maxLines: 1, overflow: TextOverflow.ellipsis)),
      Text('\$${t.balanceUsd.toStringAsFixed(2)}', style: TextStyle(color: ZipherColors.text40, fontSize: 12)),
    ]);
  }

  Widget _evmTokenIcon(String symbol, {String? networkUrl}) {
    if (networkUrl != null && networkUrl.isNotEmpty) {
      return ClipOval(
        child: Image.network(networkUrl, width: 16, height: 16, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _evmTokenIconAsset(symbol)),
      );
    }
    return _evmTokenIconAsset(symbol);
  }

  Widget _evmTokenIconAsset(String symbol) {
    final s = symbol.toLowerCase();
    return ClipOval(child: Image.asset('assets/tokens/$s.png', width: 16, height: 16,
        errorBuilder: (_, __, ___) => Container(width: 16, height: 16,
            decoration: BoxDecoration(color: ZipherColors.text20, shape: BoxShape.circle),
            child: Center(child: Text(symbol.isNotEmpty ? symbol[0] : '?',
                style: const TextStyle(fontSize: 9, color: Colors.white))))));
  }

  Widget _miniBar(String label, double value, double total, Color color) {
    final pct = total > 0 ? (value / total).clamp(0.0, 1.0) : 0.0;
    return Row(children: [
      SizedBox(width: 90, child: Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 12))),
      Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(value: pct, backgroundColor: ZipherColors.cardBgElevated,
              valueColor: AlwaysStoppedAnimation(color), minHeight: 4))),
      const Gap(8),
      Text(value.toStringAsFixed(4), style: const TextStyle(color: ZipherColors.textSecondary, fontSize: 12, fontFamily: 'JetBrains Mono')),
    ]);
  }

  Widget _detailRow(String label, String value) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 80, child: Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13))),
      Expanded(child: Text(value, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13))),
    ]));
  }

  Widget _confirmationCard({required String title, required List<Widget> details, required VoidCallback onConfirm, required VoidCallback onCancel}) {
    return Container(
      margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.warning_amber_rounded, color: ZipherColors.warm, size: 18), const Gap(8),
          Text(title, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
        const Gap(12), ...details, const Gap(16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: onCancel,
              style: OutlinedButton.styleFrom(side: BorderSide(color: ZipherColors.text20), foregroundColor: ZipherColors.textSecondary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm))),
              child: const Text('Cancel'))),
          const Gap(12),
          Expanded(child: ElevatedButton(onPressed: onConfirm,
              style: ElevatedButton.styleFrom(backgroundColor: ZipherColors.cyan, foregroundColor: ZipherColors.textOnBrand,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm))),
              child: const Text('Confirm'))),
        ]),
      ]),
    );
  }

  Widget _portfolioCard(List<Map<String, dynamic>> positions, {bool sellMode = false}) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 8), child: Row(children: [
          const Icon(Icons.pie_chart_outline, size: 16, color: ZipherColors.cyan), const Gap(8),
          Text('Open Positions (${positions.length})',
              style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
        ])),
        ...positions.map((p) => _positionRow(p, sellMode: sellMode)),
        const Gap(8),
      ]),
    );
  }

  Widget _positionRow(Map<String, dynamic> p, {bool sellMode = false}) {
    final isPm = p['_provider'] == 'polymarket';
    final marketId = p['market_id'] ?? p['marketId'] ?? 0;
    final title = p['market_title'] ?? p['title'] ?? 'Market #$marketId';
    final shares = (p['shares'] as num?)?.toDouble() ?? 0;
    final outcomeTitle = p['outcome_title'] ?? p['outcome'] ?? '?';
    final price = (p['current_price'] as num?)?.toDouble() ?? (p['price'] as num?)?.toDouble() ?? 0;
    final value = (p['current_value'] as num?)?.toDouble() ?? (shares * price);
    final costBasis = (p['cost_basis'] as num?)?.toDouble() ?? (p['value'] as num?)?.toDouble() ?? value;
    final pnlFromApi = p['cash_pnl'] as num?;
    final pnl = pnlFromApi != null ? pnlFromApi.toDouble() : (value - costBasis);
    final pnlColor = pnl >= 0 ? ZipherColors.cyan : Colors.redAccent;

    void onTap() {
      if (isPm) {
        _showPolymarketSellConfirmation(p);
        return;
      }
      if (sellMode) {
        _showSellConfirmation(p);
        return;
      }
      _submitDirect(
        ParsedIntent(type: IntentType.bet, raw: 'bet on market #$marketId', marketId: marketId as int?),
        displayText: 'Bet on market #$marketId',
      );
    }

    return InkWell(
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title.toString(), style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              const Gap(8),
              Text('\$${value.toStringAsFixed(2)}', style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 12,
                  fontWeight: FontWeight.w600, fontFamily: 'JetBrains Mono')),
            ]),
            const Gap(4),
            Row(children: [
              Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: ZipherColors.purple.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                  child: Text(outcomeTitle.toString(), style: const TextStyle(color: ZipherColors.purple, fontSize: 10, fontWeight: FontWeight.w600))),
              const Gap(8),
              Text('${shares.toStringAsFixed(2)} shares @ ${(price * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: ZipherColors.text40, fontSize: 10)),
              const Spacer(),
              Text('${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(2)}',
                  style: TextStyle(color: pnlColor, fontSize: 10, fontWeight: FontWeight.w600, fontFamily: 'JetBrains Mono')),
            ]),
          ])),
    );
  }

  Widget _marketListCard(List<Map<String, dynamic>> markets) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(children: markets.map((m) {
        final outcomes = (m['outcomes'] as List<dynamic>?) ?? [];
        final provider = m['_provider'] as String? ?? 'myriad';
        final isPolymarket = provider == 'polymarket';
        final idLabel = isPolymarket ? (m['id']?.toString().substring(0, 8) ?? '?') : '#${m['id']}';

        return InkWell(
          onTap: () => isPolymarket
              ? _submitDirect(ParsedIntent(type: IntentType.betPolymarket, raw: 'bet on polymarket ${m['id']}', polymarketId: m['id']?.toString()),
                  displayText: 'Bet on ${m['title'] ?? m['question'] ?? 'market'}')
              : _submitDirect(ParsedIntent(type: IntentType.bet, raw: 'bet on market #${m['id']}', marketId: int.tryParse('${m['id']}')),
                  displayText: 'Bet on market #${m['id']}'),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                        color: isPolymarket ? const Color(0xFF6366F1).withValues(alpha: 0.15) : ZipherColors.cardBgElevated,
                        borderRadius: BorderRadius.circular(3)),
                    child: Text(isPolymarket ? 'PM' : 'MY',
                        style: TextStyle(color: isPolymarket ? const Color(0xFF6366F1) : ZipherColors.text40,
                            fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'JetBrains Mono')),
                  ),
                  const Gap(6),
                  Text(idLabel, style: TextStyle(color: ZipherColors.text40, fontSize: 11, fontFamily: 'JetBrains Mono')),
                  const Gap(8),
                  Expanded(child: Text('${m['title']}', style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                      maxLines: 2, overflow: TextOverflow.ellipsis)),
                ]),
                if (outcomes.isNotEmpty) ...[
                  const Gap(6),
                  Wrap(spacing: 8, runSpacing: 4, children: outcomes.take(4).map((o) {
                    final price = (o['price'] as num?)?.toDouble() ?? 0;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: ZipherColors.cardBgElevated, borderRadius: BorderRadius.circular(4)),
                      child: Text('${o['title']}: ${(price * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: ZipherColors.text60, fontSize: 11, fontFamily: 'JetBrains Mono')),
                    );
                  }).toList()),
                ],
              ])),
        );
      }).toList()),
    );
  }

  Widget _directionPicker({required int marketId, required String marketTitle, required double amount,
      required List<dynamic> outcomes, String tokenSymbol = 'USDT'}) {
    final yesPrice = ((outcomes[0]['price'] as num?)?.toDouble() ?? 0) * 100;
    final noPrice = ((outcomes[1]['price'] as num?)?.toDouble() ?? 0) * 100;
    final yesId = (outcomes[0]['outcome_id'] as num?)?.toInt() ?? 0;
    final noId = (outcomes[1]['outcome_id'] as num?)?.toInt() ?? 1;

    Widget dirBtn(String label, Color color, int id, double pct) => Expanded(
      child: Material(color: Colors.transparent, child: InkWell(
        onTap: () => _showBetConfirmation(marketId: marketId, marketTitle: marketTitle, amount: amount,
            outcomeId: id, outcomeTitle: label, tokenSymbol: tokenSymbol),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(color: color.withValues(alpha: label == 'Yes' ? 0.1 : 0.08),
              borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: label == 'Yes' ? 0.3 : 0.2))),
          child: Column(children: [
            Text(label, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w700)),
            const Gap(4),
            Text('${pct.toStringAsFixed(0)}%', style: TextStyle(color: ZipherColors.text40, fontSize: 12, fontFamily: 'JetBrains Mono')),
          ]),
        ),
      )),
    );

    return Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: [
      dirBtn('Yes', ZipherColors.cyan, yesId, yesPrice), const Gap(12),
      dirBtn('No', Colors.redAccent.withValues(alpha: 0.9), noId, noPrice),
    ]));
  }

  Widget _outcomePicker({required int marketId, required String marketTitle, required double amount,
      required List<dynamic> outcomes, String tokenSymbol = 'USDT'}) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: outcomes.map((o) {
        final oTitle = o['title']?.toString() ?? '?';
        final price = (o['price'] as num?)?.toDouble() ?? 0;
        final oId = (o['outcome_id'] as num?)?.toInt() ?? outcomes.indexOf(o);
        final pctLabel = '${(price * 100).toStringAsFixed(0)}%';
        return InkWell(
          onTap: () => _showBetConfirmation(marketId: marketId, marketTitle: marketTitle, amount: amount,
              outcomeId: oId, outcomeTitle: oTitle, tokenSymbol: tokenSymbol),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), child: Row(children: [
            Container(width: 32, height: 32,
                decoration: BoxDecoration(color: ZipherColors.purple.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Center(child: Text(pctLabel,
                    style: TextStyle(color: ZipherColors.purple, fontSize: 10, fontWeight: FontWeight.w700, fontFamily: 'JetBrains Mono')))),
            const Gap(12),
            Expanded(child: Text(oTitle, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500))),
            Icon(Icons.chevron_right, color: ZipherColors.text40, size: 18),
          ])),
        );
      }).toList()),
    );
  }

  Widget _buildHelpCard() {
    const commands = [
      ('balance', 'Your total across all chains'), ('send \$10 to u1...', 'Send money (USD or ZEC)'),
      ('swap \$20 to USDT', 'Cross-chain swap (NEAR Intents)'),
      ('swap 1 POL to USDC.e on polygon', 'Same-chain EVM swap (ParaSwap)'),
      ('markets bitcoin', 'Search prediction markets'),
      ('find promising markets', 'Discover opportunities'), ('bet \$5 yes on market #123', 'Myriad bet (BSC / USDT)'),
      ('bet \$5 yes on polymarket 0x…', 'Polymarket bet (Polygon / USDC)'),
      ('my bets', 'View open positions'), ('sell market #123', 'Close a position'),
      ('sweep', 'Convert BSC tokens back to ZEC'),
    ];
    return Container(
      margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ...commands.map((c) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 160, child: Text(c.$1, style: const TextStyle(color: ZipherColors.cyan, fontSize: 12, fontFamily: 'JetBrains Mono'))),
          Expanded(child: Text(c.$2, style: TextStyle(color: ZipherColors.text40, fontSize: 12))),
        ]))),
        const Gap(10),
        Text('Bets, portfolio, and sell ask Myriad vs Polymarket first — different chains and flows.',
            style: TextStyle(color: ZipherColors.text20, fontSize: 11)),
        const Gap(4),
        Text('Amounts default to USD. All irreversible actions require confirmation.',
            style: TextStyle(color: ZipherColors.text20, fontSize: 11)),
      ]),
    );
  }

  Widget _loadingCard() {
    return Container(
      margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Row(children: [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.cyan)),
        const Gap(12),
        Text('Loading...', style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
      ]),
    );
  }

  Widget _errorCard({required String message, required VoidCallback onRetry}) {
    return Container(
      margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: Colors.red.withValues(alpha: 0.2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 16), const Gap(8),
          Expanded(child: Text(message, style: TextStyle(color: ZipherColors.text60, fontSize: 12, height: 1.4),
              maxLines: 3, overflow: TextOverflow.ellipsis)),
        ]),
        const Gap(8),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: () { HapticFeedback.lightImpact(); onRetry(); },
          icon: const Icon(Icons.refresh, size: 14), label: const Text('Retry'),
          style: TextButton.styleFrom(foregroundColor: ZipherColors.cyan,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), textStyle: const TextStyle(fontSize: 12)),
        )),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: ZipherColors.bg,
        appBar: AppBar(
          backgroundColor: ZipherColors.bg, surfaceTintColor: Colors.transparent,
          title: const Text('Action', style: TextStyle(color: ZipherColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600)),
          centerTitle: true,
          leading: IconButton(icon: Icon(Icons.arrow_back, color: ZipherColors.text60), onPressed: () => Navigator.of(context).pop()),
          actions: [
            IconButton(
              icon: Icon(_llmStatus == LlmStatus.loaded ? Icons.auto_awesome_rounded : Icons.auto_awesome_outlined, size: 20,
                  color: _llmStatus == LlmStatus.loaded ? ZipherColors.cyan : ZipherColors.text20),
              onPressed: _showLlmSettings,
            ),
          ],
        ),
        body: Column(children: [
        _buildBalanceHeader(),
        if (_history.isNotEmpty) _buildHistoryStrip(),
        Expanded(child: ListView.builder(
          controller: _scrollController, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: _messages.length + (_processing ? 1 : 0),
          itemBuilder: (context, index) => index < _messages.length ? _buildMessage(_messages[index]) : _typingIndicator(),
        )),
        _buildInputBar(),
      ]),
    ));
  }

  Widget _buildBalanceHeader() {
    if (_balanceLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZipherColors.borderSubtle, width: 0.5))),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: ZipherColors.text20)),
        ]),
      );
    }

    return GestureDetector(
      onTap: () => setState(() => _balanceExpanded = !_balanceExpanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(color: ZipherColors.bg,
            border: Border(bottom: BorderSide(color: ZipherColors.borderSubtle, width: 0.5))),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('\$${_totalUsd.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: ZipherColors.textPrimary, letterSpacing: -0.5)),
            const Gap(8),
            Icon(_balanceExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 20, color: ZipherColors.text20),
          ]),
          if (!_balanceExpanded) Text('Total across all chains', style: TextStyle(fontSize: 11, color: ZipherColors.text20)),
          if (_balanceExpanded) ...[
            const Gap(10),
            _balanceHeaderRow('ZEC', _zecAmount.toStringAsFixed(4), _zecBalanceUsd),
            for (final t in _evmBalances) ...[
              const Gap(6),
              _balanceHeaderRowEvm(t),
            ],
          ],
        ]),
      ),
    );
  }

  Widget _balanceHeaderRow(String symbol, String amount, double usd) {
    return Row(children: [
      _evmTokenIconAsset(symbol),
      const Gap(8),
      Text('$amount $symbol', style: TextStyle(fontSize: 12, color: ZipherColors.text40, fontFamily: 'JetBrains Mono')),
      const Spacer(),
      Text('\$${usd.toStringAsFixed(2)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZipherColors.text60)),
    ]);
  }

  Widget _balanceHeaderRowEvm(EvmTokenBalance t) {
    final amountStr = t.balance >= 1 ? t.balance.toStringAsFixed(4) : t.balance.toStringAsFixed(6);
    return Row(children: [
      _evmTokenIcon(t.symbol, networkUrl: t.thumbnailUrl),
      const Gap(8),
      Expanded(child: Text('$amountStr ${t.symbol} · ${t.chainLabel}',
          style: TextStyle(fontSize: 12, color: ZipherColors.text40, fontFamily: 'JetBrains Mono'), maxLines: 1, overflow: TextOverflow.ellipsis)),
      Text('\$${t.balanceUsd.toStringAsFixed(2)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZipherColors.text60)),
    ]);
  }

  Widget _buildHistoryStrip() {
    final shown = _historyExpanded ? _history.take(10).toList() : _history.take(3).toList();
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZipherColors.borderSubtle, width: 0.5))),
      child: Column(children: [
        GestureDetector(
          onTap: () => setState(() => _historyExpanded = !_historyExpanded),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Row(children: [
            Icon(Icons.history_rounded, size: 14, color: ZipherColors.text20), const Gap(6),
            Text('Recent Actions', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: ZipherColors.text20)),
            const Spacer(),
            Icon(_historyExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 16, color: ZipherColors.text20),
          ])),
        ),
        ...shown.map(_buildHistoryRow),
      ]),
    );
  }

  Widget _buildHistoryRow(ActionRecord r) {
    final icon = switch (r.type) { 'bet' => Icons.casino_rounded, 'swap' => Icons.swap_horiz_rounded, 'send' => Icons.arrow_upward_rounded, _ => Icons.receipt_long_rounded };
    final color = r.success ? ZipherColors.text40 : ZipherColors.orange;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4), child: Row(children: [
      Icon(icon, size: 14, color: color), const Gap(8),
      Expanded(child: Text(r.summary, style: TextStyle(fontSize: 12, color: ZipherColors.text40), maxLines: 1, overflow: TextOverflow.ellipsis)),
      const Gap(8),
      Text(timeago.format(r.timestamp, locale: 'en_short'), style: TextStyle(fontSize: 10, color: ZipherColors.text20)),
      if (!r.success) ...[const Gap(4), Icon(Icons.error_outline_rounded, size: 12, color: ZipherColors.orange)],
    ]));
  }

  Widget _buildMessage(ActionMessage msg) {
    final showTime = DateTime.now().difference(msg.time).inMinutes > 1;
    return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
          child: Column(crossAxisAlignment: msg.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
            if (msg.text.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: msg.isUser ? ZipherColors.cyan.withValues(alpha: 0.15) : ZipherColors.cardBg,
                  borderRadius: BorderRadius.only(topLeft: const Radius.circular(16), topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(msg.isUser ? 16 : 4), bottomRight: Radius.circular(msg.isUser ? 4 : 16)),
                  border: Border.all(color: msg.isUser ? ZipherColors.cyan.withValues(alpha: 0.2) : ZipherColors.borderSubtle),
                ),
                child: Text(msg.text, style: TextStyle(
                    color: msg.isUser ? ZipherColors.textPrimary : ZipherColors.textSecondary, fontSize: 14, height: 1.5)),
              ),
            if (msg.card != null) msg.card!,
            if (showTime) Padding(padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                child: Text(timeago.format(msg.time, locale: 'en_short'), style: TextStyle(color: ZipherColors.text20, fontSize: 10))),
          ])),
    ));
  }

  Widget _typingIndicator() {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: ZipherColors.cardBg,
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4), bottomRight: Radius.circular(16)),
            border: Border.all(color: ZipherColors.borderSubtle)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [_dot(0), const Gap(4), _dot(150), const Gap(4), _dot(300)]),
      ),
    ));
  }

  Widget _dot(int delayMs) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0), duration: const Duration(milliseconds: 600), curve: Curves.easeInOut,
      builder: (context, value, child) => Opacity(opacity: value,
          child: Container(width: 6, height: 6, decoration: BoxDecoration(color: ZipherColors.text40, shape: BoxShape.circle))),
    );
  }

  Widget _buildInputBar() {
    return Container(
      decoration: BoxDecoration(color: ZipherColors.surface,
          border: Border(top: BorderSide(color: ZipherColors.borderSubtle, width: 0.5))),
      child: SafeArea(top: false, child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(children: [
          Expanded(child: TextField(
            controller: _controller, focusNode: _focusNode,
            textInputAction: TextInputAction.send, onSubmitted: _handleSubmit,
            style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              hintText: _llmStatus == LlmStatus.loaded ? 'Ask me anything...' : 'Type a command...',
              hintStyle: TextStyle(color: ZipherColors.text20), filled: true, fillColor: ZipherColors.cardBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            ),
          )),
          const Gap(8),
          Container(
            decoration: BoxDecoration(color: _processing ? ZipherColors.text20 : ZipherColors.cyan, shape: BoxShape.circle),
            child: IconButton(
              icon: _processing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.textPrimary))
                  : const Icon(Icons.arrow_upward, color: ZipherColors.textOnBrand, size: 20),
              onPressed: _processing ? null : () => _handleSubmit(_controller.text),
            ),
          ),
        ]),
      )),
    );
  }
}
