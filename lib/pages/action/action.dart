import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:gap/gap.dart';
import '../../services/app_log.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../accounts.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../../coin/coins.dart' show isTestnet;
import '../../services/chain_config.dart';
import '../../services/wallet_service.dart';
import '../../services/portfolio_scanner.dart';
import '../../services/market_venue.dart';
import '../../services/action_executor.dart';
import '../../services/action_history.dart';
import '../../services/evm_portfolio_balance.dart';
import '../../services/llm_service.dart';
import '../../services/secure_key_store.dart';
import '../../src/rust/api/engine_api.dart' as rust_engine;
import '../utils.dart';
import 'intent.dart';
import 'llm_intent_parser.dart';
import 'models.dart';
import 'widgets/polymarket_bet_confirmation.dart';
import 'widgets/polymarket_sell_confirmation.dart';
import 'widgets/evm_swap_confirmation.dart';
import 'widgets/sweep_confirmation.dart';
import 'widgets/vote_confirmation.dart';
import '../../services/voting_service.dart';
import 'widgets/llm_settings_sheet.dart';

final _log = createLogger();

class ActionPage extends StatelessWidget {
  final String? initialIntent;
  const ActionPage({super.key, this.initialIntent});

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      final key = ValueKey(aaSequence.seqno);
      return _ActionPageInner(key: key, initialIntent: initialIntent);
    });
  }
}

class _ActionPageInner extends StatefulWidget {
  final String? initialIntent;
  const _ActionPageInner({super.key, this.initialIntent});

  @override
  State<_ActionPageInner> createState() => _ActionPageState();
}

class _ActionPageState extends State<_ActionPageInner> {
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

  bool _balanceExpanded = false;
  List<EvmTokenBalance> _evmBalances = [];
  double _evmTotalUsd = 0;

  /// When a Polymarket bet needs an amount, we store the intent here so the
  /// next user input is treated as a dollar amount, not re-parsed by the LLM.
  ParsedIntent? _pendingAmountIntent;

  /// Guided send flow: accumulates amount/address across multiple inputs.
  ParsedIntent? _pendingSendIntent;

  @override
  void initState() {
    super.initState();
    _fetchAggregatedBalance();
    _loadHistory();
    _initLlm();
    if (widget.initialIntent != null) {
      _addSystemMessage('What would you like to do?', card: _buildSuggestionChips());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _executeIntent(IntentParser.parse(widget.initialIntent!));
      });
    } else {
      _checkForActiveVote();
      _addSystemMessage('What would you like to do?', card: _buildSuggestionChips());
    }
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
    await aa.updateBalance();

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

    if (mounted) setState(() {});
  }

  double get _zecAmount => aa.poolBalances.confirmed / 1e8;
  double get _zecBalanceUsd => _zecAmount * (marketPrice.price ?? 0.0);

  String get _inputHint {
    if (_pendingSendIntent != null) {
      if (_pendingSendIntent!.amount == null || _pendingSendIntent!.amount! <= 0) {
        return 'Enter amount (e.g. 0.5 ZEC)...';
      }
      if (_pendingSendIntent!.address == null) {
        return 'Paste recipient address...';
      }
    }
    if (_pendingAmountIntent != null) {
      return 'Enter dollar amount...';
    }
    return _llmStatus == LlmStatus.loaded ? 'Ask me anything...' : 'Type a command...';
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

    // Guided send flow: collect amount or address step by step
    final pendingSend = _pendingSendIntent;
    if (pendingSend != null) {
      final trimmedInput = text.trim();
      if (pendingSend.amount == null) {
        final amount = _extractAmount(trimmedInput);
        if (amount != null && amount > 0) {
          _pendingSendIntent = pendingSend.copyWith(amount: amount, amountIsUsd: false);
          if (pendingSend.address == null) {
            _addSystemMessage('${amount.toStringAsFixed(8)} ZEC. Now paste the recipient address.');
          } else {
            _pendingSendIntent = null;
            await _executeIntent(pendingSend.copyWith(amount: amount, amountIsUsd: false));
            final followUp = _buildFollowUpChips(IntentType.send);
            if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
          }
          setState(() => _processing = false);
          return;
        }
      }
      if (pendingSend.address == null) {
        final addrMatch = RegExp(r'(u1[a-z0-9]{60,}|zs1[a-z0-9]{60,}|t1[a-zA-Z0-9]{33})', caseSensitive: false).firstMatch(trimmedInput);
        if (addrMatch != null) {
          final addr = addrMatch.group(1)!;
          if (pendingSend.amount == null) {
            _pendingSendIntent = pendingSend.copyWith(address: addr);
            _addSystemMessage('Got it, sending to ${ParsedIntent.truncAddr(addr)}. How much ZEC?');
          } else {
            _pendingSendIntent = null;
            await _executeIntent(pendingSend.copyWith(address: addr));
            final followUp = _buildFollowUpChips(IntentType.send);
            if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
          }
          setState(() => _processing = false);
          return;
        }
      }
      _pendingSendIntent = null;
    }

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
      case IntentType.vote:
        await _handleVote();
      case IntentType.history:
        await _handleHistory();
      case IntentType.receive:
        _handleReceive();
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
      final shieldedZat = (balance.orchard + balance.sapling + balance.ironwood).toInt();
      final transparentZat = balance.transparent.toInt();
      final totalZat = shieldedZat + transparentZat;
      final total = totalZat / 1e8;
      final shielded = shieldedZat / 1e8;
      final transparent = transparentZat / 1e8;
      final zecUsd = total * (marketPrice.price ?? 0);
      _addSystemMessage('', card: _balanceCard(total, shielded, transparent, zecUsd), intentType: IntentType.balance);
    } catch (e) {
      _addSystemMessage('Failed to get balance.', card: _errorCard(message: _friendlyError(e), onRetry: _handleBalance));
    }
  }

  Future<void> _handlePortfolio() async {
    // Polymarket is currently the only active venue, so we auto-select it
    // instead of prompting the user with a one-option picker.
    if (_marketFlow.trading == MarketVenue.unset) {
      setState(() => _marketFlow.trading = MarketVenue.polymarket);
    }
    setState(() => _marketFlow.resetTrading());

    try {
      final seed = await _getSeedForAction();
      final evmAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      final positions = await WalletService.instance.getPolymarketPortfolio(evmAddress);
      if (positions.isEmpty) {
        _addSystemMessage(
            'No open Polymarket positions for your Polygon address.',
            intentType: IntentType.portfolio);
        return;
      }
      _addSystemMessage('', card: _portfolioCard(positions), intentType: IntentType.portfolio);
    } catch (e) {
      _addSystemMessage('Failed to load portfolio.', card: _errorCard(message: _friendlyError(e), onRetry: _handlePortfolio));
    }
  }

  Future<void> _handleSell(ParsedIntent intent) async {
    if (_marketFlow.trading == MarketVenue.unset) {
      setState(() => _marketFlow.trading = MarketVenue.polymarket);
    }
    setState(() => _marketFlow.resetTrading());

    try {
      final seed = await _getSeedForAction();
      final evmAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);

      final positions = await WalletService.instance.getPolymarketPortfolio(evmAddress);
      if (positions.isEmpty) {
        _addSystemMessage('No open Polymarket positions to sell.');
        return;
      }
      _addSystemMessage('Which position do you want to sell? Tap one:',
          card: _portfolioCard(positions, sellMode: true));
    } catch (e) {
      _addSystemMessage('Failed to load positions.', card: _errorCard(message: _friendlyError(e), onRetry: () => _handleSell(intent)));
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
      onResult: (msg) {
        _addSystemMessage(msg);
        _fetchAggregatedBalance();
        final followUp = _buildFollowUpChips(IntentType.sell);
        if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
      },
    ));
  }

  Future<void> _handleSweep() async {
    try {
      _addSystemMessage('Scanning your wallets across chains...');
      final seed = await _getSeedForAction();
      final evmAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);
      final sweepable = await PortfolioScanner.scanSweepable(evmAddress);

      setState(() {
        if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast();
      });

      if (sweepable.isEmpty) {
        _addSystemMessage(
          'Nothing to sweep. Non-zero balances across EVM chains are below \$${PortfolioScanner.minUsd.toStringAsFixed(2)}.',
        );
        return;
      }

      final supported = sweepable.where((t) => t.isSupported).length;
      final chains = sweepable.map((t) => t.chainLabel).toSet().length;
      final totalUsd = sweepable.fold<double>(0, (sum, t) => sum + t.usdValue);

      _addSystemMessage(
        'Found ~\$${totalUsd.toStringAsFixed(2)} on $chains chain${chains == 1 ? '' : 's'}. '
        '${supported > 0 ? 'Select what to bring back to shielded ZEC.' : 'Some balances need a different path (e.g. Polymarket pUSD).'}',
        card: SweepConfirmation(
          tokens: sweepable,
          totalUsd: totalUsd,
          onResult: (msg) {
            _addSystemMessage(msg);
            _fetchAggregatedBalance();
            final followUp = _buildFollowUpChips(IntentType.sweep);
            if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
          },
        ),
      );
    } catch (e) {
      _addSystemMessage('Failed to scan balances.', card: _errorCard(message: _friendlyError(e), onRetry: _handleSweep));
    }
  }

  Future<void> _checkForActiveVote() async {
    try {
      final hasActive = await VotingService.instance.discoverActiveRound();
      if (hasActive && mounted) {
        _addSystemMessage(
          'A governance vote is active: "${VotingService.instance.config!.title}". '
          'You are eligible with ${VotingService.instance.eligibility!.eligibleZec.toStringAsFixed(2)} ZEC.',
          card: _buildSuggestionChips(items: [
            SuggestionItem(Icons.how_to_vote, 'Vote now', 'vote',
                intent: const ParsedIntent(type: IntentType.vote, raw: 'vote')),
          ]),
          intentType: IntentType.vote,
        );
      }
    } catch (_) {
      // Non-critical; don't surface errors for background discovery
    }
  }

  Future<void> _handleVote() async {
    try {
      _addSystemMessage('Checking for active governance votes...');

      final voting = VotingService.instance;
      final config = await voting.discover(staging: true);

      setState(() {
        if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast();
      });

      if (config == null) {
        _addSystemMessage('No active vote round found. Check back when a governance vote is announced.');
        return;
      }

      if (config.isExpired) {
        _addSystemMessage('The vote round "${config.title}" has ended.');
        return;
      }

      if (!config.isActive) {
        _addSystemMessage('Vote round "${config.title}" is not currently active (${config.statusLabel}).');
        return;
      }

      final eligibility = await voting.checkEligibility(config.snapshotHeight);
      if (!eligibility.isEligible) {
        _addSystemMessage(
          'You don\'t have eligible Orchard notes at snapshot height ${config.snapshotHeight}. '
          'Shield some ZEC and wait for the next round.',
        );
        return;
      }

      _addSystemMessage(
        '${config.title}\n'
        'Your voting weight: ${eligibility.eligibleZec.toStringAsFixed(2)} ZEC '
        '(${eligibility.noteCount} note${eligibility.noteCount == 1 ? '' : 's'}).',
        card: VoteConfirmation(
          config: config,
          eligibility: eligibility,
          onResult: (msg) {
            _addSystemMessage(msg);
            final followUp = _buildFollowUpChips(IntentType.vote);
            if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
          },
        ),
      );
    } catch (e) {
      _addSystemMessage('Failed to check voting status.', card: _errorCard(message: _friendlyError(e), onRetry: _handleVote));
    }
  }

  Future<void> _handleHistory() async {
    try {
      final txs = await rust_engine.engineGetTransactions();
      if (txs.isEmpty) {
        _addSystemMessage('No transactions yet.');
        return;
      }
      final recent = txs.take(10).toList();
      _addSystemMessage(
        '${txs.length} transaction${txs.length == 1 ? '' : 's'} total. Showing the latest:',
        card: _transactionListCard(recent),
      );
    } catch (e) {
      _addSystemMessage('Failed to load transactions.', card: _errorCard(message: _friendlyError(e), onRetry: _handleHistory));
    }
  }

  void _handleReceive() {
    final address = aa.diversifiedAddress;
    if (address.isEmpty) {
      _addSystemMessage('No address available. Make sure your wallet is synced.');
      return;
    }
    _addSystemMessage(
      'Here\'s your shielded address:',
      card: _receiveCard(address),
    );
    final followUp = _buildFollowUpChips(IntentType.receive);
    if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
  }

  Widget _transactionListCard(List<rust_engine.EngineTransactionRecord> txs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: txs.map((tx) {
        final isIncoming = tx.value >= 0;
        final amount = (tx.value.abs() / 1e8).toStringAsFixed(4);
        final date = tx.timestamp > 0
            ? timeago.format(DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000))
            : 'pending';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                isIncoming ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                color: isIncoming ? ZipherColors.green : ZipherColors.warm,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${isIncoming ? '+' : '-'}$amount ZEC',
                      style: TextStyle(
                        color: ZipherColors.textPrimary,
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      date,
                      style: TextStyle(
                        color: ZipherColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (tx.memo != null && tx.memo!.isNotEmpty)
                Icon(Icons.message_outlined, color: ZipherColors.textMuted, size: 14),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _receiveCard(String address) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImage(
            data: address,
            size: 200,
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: address));
            _addSystemMessage('Address copied to clipboard.');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: ZipherColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ZipherColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    address,
                    style: TextStyle(
                      color: ZipherColors.textSecondary,
                      fontSize: 11,
                      fontFamily: 'JetBrains Mono',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.copy_rounded, size: 16, color: ZipherColors.cyan),
              ],
            ),
          ),
        ),
      ],
    );
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
    if (intent.address == null && (intent.amount == null || intent.amount! <= 0)) {
      _pendingSendIntent = intent;
      _addSystemMessage('How much ZEC do you want to send?');
      return;
    }
    if (intent.amount == null || intent.amount! <= 0) {
      _pendingSendIntent = intent;
      _addSystemMessage('Sending to ${ParsedIntent.truncAddr(intent.address!)}. How much ZEC?');
      return;
    }
    if (intent.address == null) {
      _pendingSendIntent = intent;
      _addSystemMessage('${intent.amount!.toStringAsFixed(8)} ZEC. Now paste the recipient address.');
      return;
    }

    final amountZat = (intent.amount! * 1e8).round();
    _addSystemMessage(intent.summary, card: _SendConfirmationCard(
      address: intent.address!,
      amount: intent.amount!,
      amountZat: amountZat,
      memo: intent.memo,
      onConfirm: (priority) async {
        final authed = await requireSigningAuthorization(
          context,
          actionSummary:
              'Send ${intent.amount!.toStringAsFixed(8)} ZEC to ${ParsedIntent.truncAddr(intent.address!)}',
        );
        if (!authed) {
          _addSystemMessage('Send cancelled.');
          return;
        }
        _addSystemMessage('Preparing transaction${priority ? ' (priority)' : ''}...');
        try {
          final result = await WalletService.instance.proposeSend(
            intent.address!,
            amountZat,
            memo: intent.memo,
            priority: priority,
          );
          _addSystemMessage('Signing and broadcasting...');
          final txid = await WalletService.instance.confirmSend();
          _addSystemMessage(
            'Sent ${(result.sendAmount / 1e8).toStringAsFixed(8)} ZEC\n'
            'Fee: ${(result.fee / 1e8).toStringAsFixed(8)} ZEC\n'
            'Txid: $txid',
          );
          _fetchAggregatedBalance();
          final followUp = _buildFollowUpChips(IntentType.send);
          if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
        } catch (e) {
          _addSystemMessage('Send failed.', card: _errorCard(
            message: _friendlyError(e),
            onRetry: () => _handleSend(ParsedIntent(type: IntentType.send, raw: 'send', address: intent.address, amount: intent.amount, memo: intent.memo)),
          ));
        }
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
        HapticFeedback.mediumImpact();
        final stream = ActionExecutor.instance.executeSwap(amountZec: intent.amount!, toToken: to);
        _addSystemMessage('', card: _CrossChainSwapCard(
          stream: stream,
          fromToken: from,
          toToken: to,
          amount: intent.amount!,
          onComplete: () { HapticFeedback.heavyImpact(); _fetchAggregatedBalance(); },
          onFailed: () => HapticFeedback.vibrate(),
        ));
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
      chain = ChainConfig.forLabel(intent.chain!);
    }
    if (chain == null) {
      _addSystemMessage(
        'Could not determine which chain to swap on.\n\n'
        'Try: swap 1 $from to $to on polygon, arbitrum, base, or bsc',
      );
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
        final authed = await requireSigningAuthorization(
          context,
          actionSummary: 'Shield transparent ZEC into the shielded pool',
        );
        if (!authed) {
          _addSystemMessage('Shielding cancelled.');
          return;
        }
        _addSystemMessage('Shielding in progress...');
        try {
          await WalletService.instance.shieldFunds();
          _addSystemMessage('Shielding complete. Transparent funds moved to Orchard pool.');
          final followUp = _buildFollowUpChips(IntentType.shield);
          if (followUp is! SizedBox) _addSystemMessage('', card: followUp);
        } catch (e) { _addSystemMessage('Shielding failed.', card: _errorCard(message: _friendlyError(e), onRetry: _handleShield)); }
      },
      onCancel: () => _addSystemMessage('Shielding cancelled.'),
    ), intentType: IntentType.shield);
  }

  Future<void> _handleMarketSearch(ParsedIntent intent) async {
    if (_marketFlow.discovery == MarketVenue.unset) {
      setState(() => _marketFlow.discovery = MarketVenue.polymarket);
    }

    _addSystemMessage('Searching Polymarket...', card: _loadingCard());
    try {
      final polymarketRows = await WalletService.instance.polymarketDiscoveryRows(
        keyword: intent.query,
        limit: 20,
      );
      _log.i('[Markets] Polymarket discovery rows: ${polymarketRows.length}');

      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      if (polymarketRows.isEmpty) {
        _addSystemMessage('No markets found on Polymarket${intent.query != null ? ' for "${intent.query}"' : ''}.');
        return;
      }
      LlmIntentParser.instance.setPolymarketRows(polymarketRows);
      LlmIntentParser.instance.setContext(LlmIntentParser.polymarketDiscoveryContext(polymarketRows));
      _addSystemMessage(
        'Tap a market to bet:',
        card: _polymarketDiscoveryCard(polymarketRows),
        intentType: IntentType.marketSearch,
      );
    } catch (e) {
      _log.e('[Markets] Polymarket search failed: $e');
      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      _addSystemMessage('Polymarket search failed.', card: _errorCard(message: _friendlyError(e), onRetry: () => _handleMarketSearch(intent)));
    }
  }

  Future<void> _handleMarketDiscover() async {
    if (_marketFlow.discovery == MarketVenue.unset) {
      setState(() => _marketFlow.discovery = MarketVenue.polymarket);
    }

    _addSystemMessage('Looking for trending Polymarket markets...', card: _loadingCard());
    try {
      final polymarketRows =
          await WalletService.instance.polymarketDiscoveryRows(keyword: null, limit: 20);
      _log.i('[Markets] Polymarket discover rows: ${polymarketRows.length}');

      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      if (polymarketRows.isEmpty) {
        _addSystemMessage('No active markets found on Polymarket right now.');
        return;
      }
      LlmIntentParser.instance.setPolymarketRows(polymarketRows);
      LlmIntentParser.instance.setContext(LlmIntentParser.polymarketDiscoveryContext(polymarketRows));
      _addSystemMessage(
        'Tap a market to bet:',
        card: _polymarketDiscoveryCard(polymarketRows),
        intentType: IntentType.marketDiscover,
      );
    } catch (e) {
      setState(() { if (_messages.isNotEmpty && !_messages.last.isUser) _messages.removeLast(); });
      _addSystemMessage('Could not fetch markets.', card: _errorCard(message: _friendlyError(e), onRetry: _handleMarketDiscover));
    }
  }

  Future<void> _handleBet(ParsedIntent intent) async {
    // Numeric market ids were the Myriad (BSC / USDT) flow; that venue is
    // hidden as of 2026-05. Polymarket is now the only active venue and
    // uses hex condition ids (0x…). Redirect users with a clear message
    // instead of touching the deprecated Myriad backend.
    setState(() => _marketFlow.resetTrading());
    _addSystemMessage(
      'Bets now go through Polymarket (Polygon / USDC). It uses hex condition ids (0x…).\n\n'
      'Try `find markets`, tap a row to bet, or:\n'
      'bet \$5 yes on polymarket 0x…',
    );
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
      // Polymarket-only flow; no venue prompt needed.
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
              // Polymarket brand badge. The `+` suffix on grouped events
              // is rendered as a tiny dot to the right of the logo so the
              // visual identity stays consistent across single and
              // multi-runner rows.
              Container(
                width: 18,
                height: 18,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Image.asset('assets/venues/polymarket.png',
                    width: 14, height: 14),
              ),
              if (kind == 'grouped') ...[
                const Gap(2),
                Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: Color(0xFF6366F1),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
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
      SuggestionItem(Icons.qr_code_rounded, 'Receive', 'receive',
          intent: const ParsedIntent(type: IntentType.receive, raw: 'receive')),
      SuggestionItem(Icons.swap_horiz, 'Swap', '_swap_chooser'),
      SuggestionItem(Icons.history_rounded, 'History', 'history',
          intent: const ParsedIntent(type: IntentType.history, raw: 'history')),
      SuggestionItem(Icons.trending_up, 'Find markets', 'find promising markets',
          intent: const ParsedIntent(type: IntentType.marketDiscover, raw: 'find promising markets')),
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
          SuggestionItem(Icons.how_to_vote, 'Vote', 'vote',
              intent: const ParsedIntent(type: IntentType.vote, raw: 'vote')),
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
      case IntentType.vote:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
        ];
      case IntentType.evmSwap:
      case IntentType.swap:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          SuggestionItem(Icons.swap_horiz, 'Swap again', '_swap_chooser'),
        ];
      case IntentType.send:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          SuggestionItem(Icons.history_rounded, 'History', 'history',
              intent: const ParsedIntent(type: IntentType.history, raw: 'history')),
          SuggestionItem(Icons.send_rounded, 'Send again', 'send',
              intent: const ParsedIntent(type: IntentType.send, raw: 'send')),
        ];
      case IntentType.receive:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          SuggestionItem(Icons.send_rounded, 'Send', 'send',
              intent: const ParsedIntent(type: IntentType.send, raw: 'send')),
        ];
      case IntentType.history:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          SuggestionItem(Icons.send_rounded, 'Send', 'send',
              intent: const ParsedIntent(type: IntentType.send, raw: 'send')),
        ];
      case IntentType.shield:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
        ];
      case IntentType.sell:
        chips = [
          SuggestionItem(Icons.account_balance_wallet_outlined, 'Balance', 'balance',
              intent: const ParsedIntent(type: IntentType.balance, raw: 'balance')),
          SuggestionItem(Icons.pie_chart_outline, 'My bets', 'my bets',
              intent: const ParsedIntent(type: IntentType.portfolio, raw: 'my bets')),
        ];
      case IntentType.marketDiscover:
      case IntentType.marketSearch:
        // Polymarket is the only active venue, so "switch platform" no
        // longer makes sense. Surface "refresh" and "my bets" instead.
        chips = [
          SuggestionItem(Icons.refresh, 'Refresh', 'find promising markets',
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
                style: const TextStyle(fontSize: 9, color: ZipherColors.textPrimary))))));
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
      // Only Polymarket positions remain (Myriad removed). For sell mode the
      // user tapped a position card to close it; otherwise this is a bet
      // entry — we just open the same Polymarket sell confirmation.
      _showPolymarketSellConfirmation(p);
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

  // ignore: unused_element
  Widget _marketListCard(List<Map<String, dynamic>> markets) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: ZipherColors.cardBg, borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle)),
      child: Column(children: markets.map((m) {
        final outcomes = (m['outcomes'] as List<dynamic>?) ?? [];
        final idLabel = m['id']?.toString().substring(0, 8) ?? '?';

        return InkWell(
          onTap: () => _submitDirect(
              ParsedIntent(
                  type: IntentType.betPolymarket,
                  raw: 'bet on polymarket ${m['id']}',
                  polymarketId: m['id']?.toString()),
              displayText: 'Bet on ${m['title'] ?? m['question'] ?? 'market'}'),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  // Venue badge — Polymarket logo on its brand accent.
                  Container(
                    width: 18,
                    height: 18,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Image.asset('assets/venues/polymarket.png',
                        width: 14, height: 14),
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

  Widget _buildHelpCard() {
    const commands = [
      ('balance', 'Your total across all chains'), ('send \$10 to u1...', 'Send money (USD or ZEC)'),
      ('swap \$20 to USDT', 'Cross-chain swap (NEAR Intents)'),
      ('swap 1 POL to USDC.e on polygon', 'Same-chain EVM swap (ParaSwap)'),
      ('receive', 'Show your shielded address'),
      ('history', 'Recent transactions'),
      ('markets bitcoin', 'Search prediction markets'),
      ('find promising markets', 'Discover opportunities'),
      ('bet \$5 yes on polymarket 0x…', 'Polymarket bet (Polygon / USDC)'),
      ('my bets', 'View open positions'),
      ('sell market 0x…', 'Close a position'),
      ('sweep', 'Bring EVM chain balances back to shielded ZEC'),
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
        Text('Prediction-market actions run on Polymarket (Polygon / USDC). ZEC is bridged automatically.',
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

  String _friendlyError(dynamic e) {
    var msg = e.toString();
    if (msg.startsWith('AnyhowException(')) {
      msg = msg.substring('AnyhowException('.length);
      if (msg.endsWith(')')) msg = msg.substring(0, msg.length - 1);
    }
    if (msg.startsWith('Exception: ')) msg = msg.substring('Exception: '.length);
    if (msg.length > 120) msg = '${msg.substring(0, 117)}...';
    return msg;
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
          centerTitle: true,
          leading: Navigator.of(context).canPop()
              ? IconButton(icon: Icon(Icons.arrow_back, color: ZipherColors.text60), onPressed: () => Navigator.of(context).pop())
              : null,
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
    return Observer(builder: (_) {
      final zecAmt = _zecAmount;
      final zecUsd = _zecBalanceUsd;
      final totalUsd = zecUsd + _evmTotalUsd;

      return GestureDetector(
        onTap: () => setState(() => _balanceExpanded = !_balanceExpanded),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(color: ZipherColors.bg,
              border: Border(bottom: BorderSide(color: ZipherColors.borderSubtle, width: 0.5))),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('\$${totalUsd.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: ZipherColors.textPrimary, letterSpacing: -0.5)),
              const Gap(8),
              Icon(_balanceExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 20, color: ZipherColors.text20),
            ]),
            if (!_balanceExpanded) Text('Total across all chains', style: TextStyle(fontSize: 11, color: ZipherColors.text20)),
            if (_balanceExpanded) ...[
              const Gap(10),
              _balanceHeaderRow('ZEC', zecAmt.toStringAsFixed(4), zecUsd),
              for (final t in _evmBalances) ...[
                const Gap(6),
                _balanceHeaderRowEvm(t),
              ],
            ],
          ]),
        ),
      );
    });
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
    return _PulsingDot(delayMs: delayMs);
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
              hintText: _inputHint,
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

class _SendConfirmationCard extends StatefulWidget {
  final String address;
  final double amount;
  final int amountZat;
  final String? memo;
  final Future<void> Function(bool priority) onConfirm;
  final VoidCallback onCancel;

  const _SendConfirmationCard({
    required this.address,
    required this.amount,
    required this.amountZat,
    required this.memo,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<_SendConfirmationCard> createState() => _SendConfirmationCardState();
}

class _SendConfirmationCardState extends State<_SendConfirmationCard> {
  bool _priority = false;
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Confirm Send', style: TextStyle(color: ZipherColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
        const Gap(12),
        _row('To', ParsedIntent.truncAddr(widget.address)),
        _row('Amount', '${widget.amount.toStringAsFixed(8)} ZEC'),
        if (widget.memo != null) _row('Memo', widget.memo!),
        const Gap(8),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Priority', style: TextStyle(fontSize: 13, color: ZipherColors.text40)),
              Text('Higher fee, priority during congestion', style: TextStyle(fontSize: 11, color: ZipherColors.text20)),
            ]),
          ),
          SizedBox(
            height: 28,
            child: Switch.adaptive(
              value: _priority,
              onChanged: _confirmed ? null : (v) => setState(() => _priority = v),
              activeColor: ZipherColors.cyan,
            ),
          ),
        ]),
        const Gap(12),
        if (!_confirmed)
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: widget.onCancel,
                child: Text('Cancel', style: TextStyle(color: ZipherColors.text40)),
              ),
            ),
            const Gap(8),
            Expanded(
              child: ElevatedButton(
                onPressed: () {
                  setState(() => _confirmed = true);
                  widget.onConfirm(_priority);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZipherColors.cyan,
                  foregroundColor: ZipherColors.textOnBrand,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.md)),
                ),
                child: const Text('Confirm'),
              ),
            ),
          ]),
      ]),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13))),
        Expanded(child: Text(value, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13))),
      ]),
    );
  }
}

class _CrossChainSwapCard extends StatefulWidget {
  final Stream<ActionProgress> stream;
  final String fromToken;
  final String toToken;
  final double amount;
  final VoidCallback onComplete;
  final VoidCallback onFailed;

  const _CrossChainSwapCard({
    required this.stream,
    required this.fromToken,
    required this.toToken,
    required this.amount,
    required this.onComplete,
    required this.onFailed,
  });

  @override
  State<_CrossChainSwapCard> createState() => _CrossChainSwapCardState();
}

class _CrossChainSwapCardState extends State<_CrossChainSwapCard> {
  final List<ActionProgress> _steps = [];
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.stream.listen((progress) {
      if (!mounted) return;
      setState(() {
        if (_steps.length < progress.step) {
          _steps.add(progress);
        } else {
          _steps[progress.step - 1] = progress;
        }
        if (progress.isComplete) {
          _done = true;
          widget.onComplete();
        }
        if (progress.isFailed) {
          _failed = true;
          widget.onFailed();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: _failed ? Colors.red.withValues(alpha: 0.3) : ZipherColors.text10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.swap_horiz, color: ZipherColors.cyan, size: 16),
          const Gap(8),
          Text(
            '${widget.amount.toStringAsFixed(4)} ${widget.fromToken} → ${widget.toToken}',
            style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ]),
        const Gap(12),
        if (_steps.isEmpty)
          Row(children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.cyan)),
            const Gap(8),
            Text('Initializing...', style: TextStyle(color: ZipherColors.text40, fontSize: 12)),
          ]),
        ..._steps.map((step) {
          final IconData icon;
          final Color color;
          if (step.isComplete) {
            icon = Icons.check_circle;
            color = ZipherColors.green;
          } else if (step.isFailed) {
            icon = Icons.cancel;
            color = Colors.red;
          } else {
            icon = Icons.radio_button_unchecked;
            color = ZipherColors.cyan;
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              step.status == ActionStatus.running && !step.isComplete && !step.isFailed
                  ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.cyan))
                  : Icon(icon, size: 14, color: color),
              const Gap(8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(step.label, style: TextStyle(color: ZipherColors.textPrimary, fontSize: 12)),
                if (step.detail.isNotEmpty)
                  Text(step.detail, style: TextStyle(color: ZipherColors.text40, fontSize: 11)),
              ])),
            ]),
          );
        }),
        if (_done) ...[
          const Gap(8),
          Text('Swap complete', style: TextStyle(color: ZipherColors.green, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
        if (_failed) ...[
          const Gap(8),
          Text('Swap failed', style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final int delayMs;
  const _PulsingDot({required this.delayMs});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.3, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.3).chain(CurveTween(curve: Curves.easeInOut)), weight: 50),
    ]).animate(_controller);
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _controller.repeat();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, child) => Opacity(
        opacity: _opacity.value,
        child: child,
      ),
      child: Container(width: 6, height: 6, decoration: BoxDecoration(color: ZipherColors.text40, shape: BoxShape.circle)),
    );
  }
}
