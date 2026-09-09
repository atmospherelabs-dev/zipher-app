import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../coin/coins.dart';
import '../../services/near_intents.dart';
import '../../services/evm_portfolio_balance.dart';
import '../../services/wallet_receive_address.dart';
import '../../services/wallet_service.dart';
import '../../src/rust/api/engine_api.dart' as engine;
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../main/sync_status.dart';
import '../utils.dart';
import 'wallet_conversation.dart';
import 'widgets/wallet_review_card.dart';
import 'widgets/z_chat_widgets.dart';

/// The home and Z entry points share one conversation. No model initialization,
/// remote language parsing is needed. Public EVM balances refresh separately.
class WalletChatPage extends StatelessWidget {
  final String? initialIntent;
  final EvmBalanceReader? balanceReader;
  const WalletChatPage({super.key, this.initialIntent, this.balanceReader});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: testnetNotifier,
      builder: (_, network, __) => Observer(
          builder: (_) => _WalletChat(
                key: ValueKey('${aaSequence.seqno}:$network'),
                initialIntent: initialIntent,
                balanceReader: balanceReader,
              )));
}

class _WalletChat extends StatefulWidget {
  final String? initialIntent;
  final EvmBalanceReader? balanceReader;
  const _WalletChat({super.key, this.initialIntent, this.balanceReader});
  @override
  State<_WalletChat> createState() => _WalletChatState();
}

class _WalletChatState extends State<_WalletChat> with WidgetsBindingObserver {
  final _conversation = WalletConversation();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <({String text, bool user, Widget? card})>[];
  final _wallet = WalletService.instance;
  final _near = NearIntentsService();
  late final String? _walletId;
  late final bool _testnet;
  late final ActiveAccount2 _account;
  final _reviewEpoch = ValueNotifier<int>(0);
  bool _busy = false;
  bool _balanceExpanded = false;
  bool _historyExpanded = false;
  bool _choosingAddress = false;
  late final EvmBalanceReader _balanceReader;
  EvmBalanceSnapshot? _portfolio;
  bool _loadingPortfolio = false;
  Timer? _portfolioTimer;
  WalletRequest? _swapRequest;
  List<NearToken> _swapTokens = [];
  NearToken? _swapToken;
  String? _swapRecipient;
  Timer? _swapTimer;
  bool _pollingSwap = false;
  String? _trackedDeposit;
  String? _lastSwapStatus;

  bool get _current =>
      mounted &&
      identical(aa, _account) &&
      _wallet.activeWalletId == _walletId &&
      isTestnet == _testnet &&
      !_wallet.isBusy;

  @override
  void initState() {
    super.initState();
    _walletId = _wallet.activeWalletId;
    _testnet = isTestnet;
    _account = aa;
    _balanceReader = widget.balanceReader ?? EvmPortfolioBalance.createReader();
    WidgetsBinding.instance.addObserver(this);
    if (_wallet.isWalletOpen)
      _portfolioTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (mounted && TickerMode.valuesOf(context).enabled)
          _refreshPortfolio();
      });
    _messages
        .add((text: 'What would you like to do?', user: false, card: null));
    // Local balance comes from the existing account/sync stream. Fiat refresh
    // is public market data; no account or address is included.
    marketPrice.update().catchError((Object _) {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshPortfolio();
      if (widget.initialIntent != null && _current)
        _submit(widget.initialIntent!);
    });
  }

  @override
  void dispose() {
    _swapTimer?.cancel();
    _portfolioTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    _reviewEpoch.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPortfolio(force: true);
      if (_wallet.isWalletOpen) boostSyncPolling();
    }
  }

  Future<void> _refreshPortfolio({bool force = false}) async {
    if (!_current ||
        _testnet ||
        _loadingPortfolio ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) return;
    setState(() => _loadingPortfolio = true);
    try {
      if (_account.chainAddresses == null && _wallet.isWalletOpen)
        await _account.updateChainAddresses();
      if (!_current) return;
      final address = _account.chainAddresses?.evm;
      if (address == null || address.isEmpty) return;
      final result = await _balanceReader.fetch(address, force: force);
      if (_current) setState(() => _portfolio = result);
    } catch (_) {
      // Existing snapshot stays visible if a new read cannot start.
    } finally {
      if (mounted) setState(() => _loadingPortfolio = false);
    }
  }

  @override
  void didUpdateWidget(covariant _WalletChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialIntent != null &&
        widget.initialIntent != oldWidget.initialIntent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current) _submit(widget.initialIntent!);
      });
    }
  }

  void _message(String text, {bool user = false, Widget? card}) {
    if (!_current) return;
    setState(() => _messages.add((text: text, user: user, card: card)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      }
    });
  }

  void _clearDraft() {
    _conversation.cancel();
    _choosingAddress = false;
    _swapRequest = null;
    _swapTokens = [];
    _swapToken = null;
    _swapRecipient = null;
    _reviewEpoch.value++;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (_current) {
        // Do not echo raw RPC errors, which can contain request addresses.
        final text = e.toString().toLowerCase();
        _message(text.contains('insufficient')
            ? 'There isn’t enough spendable shielded ZEC to cover this amount and its fee. Check your balance or wait for confirmations.'
            : text.contains('sync') || text.contains('checkpoint')
                ? 'Your wallet is still syncing. Wait for it to catch up, then try again.'
                : 'That request couldn’t finish. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(String text) async {
    if (_busy || !_current || text.trim().isEmpty) return;
    _input.clear();
    _message(text.trim(), user: true);
    await _run(() async {
      final command = WalletConversation.command(text);
      if (_choosingAddress && command == WalletCommand.unknown) {
        await _receive(text);
        return;
      }
      _choosingAddress = false;
      // A network or recipient is a reply to the active swap, never a guess at
      // an EVM destination. Explicit commands can cancel/replace that draft.
      if (_swapRequest != null && command == WalletCommand.unknown) {
        await _continueSwap(text.trim());
        return;
      }
      if (command != WalletCommand.unknown) {
        _swapRequest = null;
        _swapToken = null;
        _swapTokens = [];
        _swapRecipient = null;
        _reviewEpoch.value++;
      }
      final reply = _conversation.accept(text);
      if (reply.prompt != null) _message(reply.prompt!);
      final request = reply.request;
      if (request == null) return;
      switch (request.command) {
        case WalletCommand.send:
          await _prepareSend(request);
        case WalletCommand.receive:
          await _receive(text);
        case WalletCommand.swap:
          await _beginSwap(request);
        case WalletCommand.balance:
          await _account.updateBalance();
          await _refreshPortfolio(force: true);
          if (!_current) return;
          final b = _account.poolBalances;
          _message(
              'Balance: ${WalletConversation.formatZec(b.total)} ZEC\n'
              'Spendable shielded: ${WalletConversation.formatZec(b.shielded)} ZEC\n'
              'Confirming: ${WalletConversation.formatZec(b.unconfirmed)} ZEC\n'
              'Transparent: ${WalletConversation.formatZec(b.totalTransparent)} ZEC',
              card: _portfolioDetails());
        case WalletCommand.history:
          await _history();
        case WalletCommand.help:
          _message(
              'Type send and I’ll ask who and how much, or write “send 0.5 ZEC to …”.\n\n'
              'Receive or “my address” shows supported chains; choose one for its address, QR and copy button. Swap guides you through amount, token, network and recipient. '
              'Use balance or history to check your wallet. Type cancel to discard a draft.\n\n'
              'Amounts are in ZEC. Every payment needs your review and confirmation.');
        case WalletCommand.cancel:
        case WalletCommand.unknown:
          break;
      }
    });
  }

  Future<void> _receive(String input) async {
    if (_account.chainAddresses == null && !_testnet && _wallet.isWalletOpen) {
      await _account.updateChainAddresses();
      if (!_current) return;
    }
    final choices = WalletReceiveAddress.available(
        zcash: _account.diversifiedAddress,
        testnet: _testnet,
        chains: _account.chainAddresses);
    final requested = WalletReceiveAddress.requestedChain(input);
    final matching = choices.where((c) => c.id == requested).toList();
    if (matching.length == 1) {
      _showReceiveAddress(matching.single);
      return;
    }
    _choosingAddress = true;
    _message(
        choices.isEmpty
            ? 'Your addresses are still loading. Try receive again in a moment.'
            : requested != null
                ? 'That chain’s address is unavailable in this wallet. Choose an available chain.'
                : 'Which chain would you like to receive on?',
        card: choices.isEmpty
            ? null
            : Wrap(spacing: 8, runSpacing: 8, children: [
                for (final choice in choices)
                  ZChatShortcut(
                      icon: Icons.qr_code_rounded,
                      label: choice.label,
                      onTap: () {
                        if (!_current || _busy) return;
                        _submit('My ${choice.label} address');
                      }),
              ]));
  }

  void _showReceiveAddress(WalletReceiveAddress choice) {
    if (!_current) return;
    _choosingAddress = false;
    if (choice.id == 'zec' && _wallet.isWalletOpen) boostSyncPolling();
    _message(
        'Your ${choice.label} ${choice.id == 'zec' ? 'shielded ' : 'mainnet '}receive address.',
        card: Column(children: [
          Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImage(data: choice.address, size: 180)),
          const SizedBox(height: 12),
          SelectableText(choice.address, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Text(
              'Send only assets on ${choice.label}${choice.id == 'zec' ? '' : ' mainnet'} to this address.',
              style: TextStyle(fontSize: 12, color: ZipherColors.text60)),
          TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy address'),
              onPressed: () async {
                if (!_current) return;
                try {
                  await Clipboard.setData(ClipboardData(text: choice.address));
                  _message('${choice.label} address copied.');
                } catch (_) {
                  _message(
                      'Copy failed. You can select and copy the full address above.');
                }
              }),
        ]));
  }

  Widget _portfolioDetails() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final t in _portfolio?.tokens ?? <EvmTokenBalance>[])
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Expanded(
                    child: Text(
                        '${t.balance.toStringAsFixed(8)} ${t.symbol} · ${t.chainLabel}',
                        style: TextStyle(
                            fontSize: 12, color: ZipherColors.text60))),
                const SizedBox(width: 8),
                Text(
                    t.priceAvailable
                        ? '\$${t.balanceUsd.toStringAsFixed(2)} USD'
                        : 'Price unavailable',
                    style: TextStyle(fontSize: 11, color: ZipherColors.text40)),
              ])),
        if (_portfolio != null && !_portfolio!.complete)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'Unavailable: ${_portfolio!.unavailableChains.join(', ')}. These chains are excluded from the subtotal.',
                  style: TextStyle(fontSize: 11, color: ZipherColors.orange))),
        if (_portfolio != null &&
            _portfolio!.tokens.isEmpty &&
            _portfolio!.complete)
          Text('No balances found for tracked EVM assets.',
              style: TextStyle(fontSize: 11, color: ZipherColors.text40)),
        if (_portfolio == null && !_testnet)
          Text(
              _loadingPortfolio
                  ? 'Loading other chains…'
                  : 'Other-chain balances unavailable.',
              style: TextStyle(fontSize: 11, color: ZipherColors.text40)),
        if (!_testnet)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'EVM balances use public RPC services. Bitcoin and Solana balances are not included.',
                  style: TextStyle(fontSize: 11, color: ZipherColors.text40))),
      ]);

  Future<void> _history() async {
    final records = await engine.engineGetTransactions();
    if (!_current) return;
    if (records.isEmpty) {
      _message(
          'No transactions yet. Your history will appear as your wallet syncs.');
      return;
    }
    _message('Recent transactions',
        card: Column(
          children: records.take(10).map((tx) {
            final incoming = tx.value >= 0;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(incoming ? Icons.south_west : Icons.north_east,
                  color: incoming ? ZipherColors.green : ZipherColors.text60),
              title: Text(
                  '${incoming ? '+' : '−'}${WalletConversation.formatZec(tx.value.abs().toInt())} ZEC'),
              subtitle: Text(tx.expiredUnmined
                  ? 'Expired · not confirmed'
                  : tx.height > 0
                      ? 'Confirmed · block ${tx.height}'
                      : 'Pending confirmation'),
            );
          }).toList(),
        ));
  }

  Future<bool> _canSend() async {
    if (!_account.canPay || await _wallet.isActiveFrostWallet()) {
      _message(
          'This wallet needs the dedicated signing flow. Open the wallet overview to send.',
          card: TextButton(
              onPressed: () => context.push('/account/overview'),
              child: const Text('Open wallet overview')));
      return false;
    }
    return _current;
  }

  Future<void> _prepareSend(WalletRequest request,
      {NearQuoteResponse? quote,
      NearToken? destination,
      String? recipient}) async {
    if (request.memo != null && utf8.encode(request.memo!).length > 512) {
      _message(
          'The memo is too long. Use at most 512 UTF-8 bytes, then start the send again.');
      return;
    }
    if (!await _canSend()) return;
    final address = request.recipient!;
    final validation = await _wallet.validateAddress(address);
    if (!_current) return;
    if (!validation.isValid) {
      _message(
          'That address is invalid for this wallet. Check the full address and network, then start again with send.');
      return;
    }
    final isTransparent = address.startsWith('t');
    if (isTransparent && request.memo != null && request.memo!.isNotEmpty) {
      _message(
          'Transparent addresses cannot receive a private memo. Use a shielded address or start again without a memo.');
      return;
    }
    _message(quote == null
        ? 'Checking the address, spendable funds and exact fee…'
        : 'Checking the Zcash deposit and network fee…');
    final proposal = await _wallet.proposeSend(address, request.zatoshis!,
        memo: request.memo);
    if (!_current) return;
    if (!proposal.isExact || proposal.sendAmount != request.zatoshis) {
      _message(
          'The wallet couldn’t prepare that exact amount. Start again with a smaller amount.');
      return;
    }
    final revision = _wallet.proposalRevision;
    final epoch = ++_reviewEpoch.value;
    final details = <String, String>{
      if (quote == null) 'Recipient': address,
      if (quote != null) 'Receive on': destination!.displayName,
      if (quote != null) 'Recipient': recipient!,
      'Amount': '${WalletConversation.formatZec(proposal.sendAmount)} ZEC',
      'Network fee': '${WalletConversation.formatZec(proposal.fee)} ZEC',
      'Total':
          '${WalletConversation.formatZec(proposal.sendAmount + proposal.fee)} ZEC',
      if (request.memo != null) 'Memo': request.memo!,
      if (quote != null)
        'Estimated receive':
            '${_tokenAmount(quote.amountOut, destination!.decimals)} ${destination.symbol}',
      if (quote != null && quote.minAmountOut != null)
        'Minimum receive':
            '${_tokenAmount(quote.minAmountOut!, destination!.decimals)} ${destination.symbol}',
      if (quote != null)
        'Slippage': '1% · provider quote includes 0.5% app fee',
      if (quote != null) 'Quote deadline': quote.deadline,
      if (quote == null && isTransparent)
        'Privacy': 'Recipient and amount are public at a transparent address.',
      if (quote != null)
        'Provider':
            'NEAR Intents receives the destination and refund addresses. Destination-chain transfers may be public.',
    };
    _message(quote == null ? 'Review your send.' : 'Review your swap.',
        card: WalletReviewCard(
          epoch: _reviewEpoch,
          expectedEpoch: epoch,
          details: details,
          confirmLabel: quote == null ? 'Send ZEC' : 'Confirm swap',
          onCancel: () {
            _clearDraft();
            _message('Cancelled. Nothing was sent.');
          },
          onConfirm: () => _run(() async {
            if (_reviewEpoch.value != epoch || !_current) return;
            if (_wallet.proposalRevision != revision) {
              _reviewEpoch.value++;
              _message(
                  'Another transaction replaced this review. Start again with send or swap to get a fresh review.');
              return;
            }
            if (quote != null && !_quoteValid(quote, request.zatoshis!)) {
              _reviewEpoch.value++;
              _message('This quote expired. Type swap to get a fresh quote.');
              return;
            }
            final authorized = await requireSigningAuthorization(context,
                actionSummary:
                    'Send ${WalletConversation.formatZec(proposal.sendAmount)} ZEC + '
                    '${WalletConversation.formatZec(proposal.fee)} ZEC fee to $address');
            if (!_current || !authorized) {
              _message('Cancelled. Nothing was sent.');
              return;
            }
            if (_reviewEpoch.value != epoch ||
                (quote != null && !_quoteValid(quote, request.zatoshis!))) {
              _message(
                  'The request changed or expired. Start again to review it.');
              return;
            }
            if (quote != null) {
              // Persist recovery information before signing. Even if the app
              // closes during broadcast, swap history can query the deposit.
              await SwapStore.save(_storedSwap(
                  quote, destination!, recipient!, request.zatoshis!));
              if (!_current) return;
            }
            _message('Signing and broadcasting…');
            String txid;
            try {
              txid = await _wallet.confirmSend(
                  expectedRevision: revision,
                  expectedWalletId: _walletId,
                  expectedTestnet: _testnet);
            } catch (_) {
              // A broadcast timeout does not prove non-submission. Never offer
              // an automatic re-send from this card.
              if (!_current) return;
              _reviewEpoch.value++;
              _message(
                  'The send could not be confirmed here. Check history and sync before starting another send; the transaction may have reached the network.');
              return;
            }
            if (!_current) return;
            _reviewEpoch.value++;
            boostSyncPolling();
            _message(
                'Broadcast submitted. Waiting for network confirmation.\nTransaction: $txid');
            if (quote != null) {
              await _recordSwap(
                  quote, destination!, recipient!, request.zatoshis!, txid);
            }
            await _account.updateBalance();
          }),
        ));
  }

  Future<void> _beginSwap(WalletRequest request) async {
    if (_testnet) {
      _message(
          'Cross-chain swaps are available on mainnet. Your testnet ZEC stays on testnet.');
      return;
    }
    if (_trackedDeposit != null) {
      _message(
          'Your current swap is still being tracked. Wait for its result before starting another swap.');
      return;
    }
    if (!await _canSend()) return;
    _message('Looking up ${request.token} networks…');
    final tokens = await _near.getTokens();
    if (!_current) return;
    final matches = tokens
        .where((t) =>
            t.symbol.toUpperCase() == request.token &&
            t.symbol.toUpperCase() != 'ZEC')
        .toList();
    if (matches.isEmpty) {
      _message(
          'That destination token isn’t available. Type swap to choose another token.');
      return;
    }
    _swapRequest = request;
    _swapTokens = matches;
    _swapToken = null;
    _swapRecipient = null;
    if (matches.length == 1) {
      _swapToken = matches.single;
      _askSwapRecipient();
    } else {
      _message('Which network should receive your ${request.token}?',
          card: Wrap(spacing: 8, children: [
            for (final (index, token) in matches.indexed)
              TextButton(
                  onPressed: () {
                    if (_current &&
                        identical(_swapRequest, request) &&
                        _swapToken == null) _submit('${index + 1}');
                  },
                  child:
                      Text('${index + 1}. ${token.blockchain.toUpperCase()}')),
          ]));
    }
  }

  void _askSwapRecipient() {
    final addresses = _account.chainAddresses;
    final request = _swapRequest;
    final token = _swapToken;
    final network = token!.blockchain.toLowerCase();
    final own = switch (network) {
      'btc' => addresses?.bitcoin,
      'sol' => addresses?.solana,
      'eth' ||
      'arb' ||
      'base' ||
      'op' ||
      'pol' ||
      'bsc' ||
      'avax' ||
      'gnosis' ||
      'bera' =>
        addresses?.evm,
      _ => null,
    };
    _message(
        'Paste the ${_swapToken!.displayName} recipient address. Check that it belongs to this network.',
        card: own == null || own.isEmpty
            ? null
            : TextButton(
                onPressed: () {
                  if (_current &&
                      request != null &&
                      identical(_swapRequest, request) &&
                      identical(_swapToken, token)) _submit(own);
                },
                child: Text('Use my ${_swapToken!.displayName} address'),
              ));
  }

  Future<void> _continueSwap(String input) async {
    if (_swapToken == null) {
      final choice = int.tryParse(input);
      final matches = choice != null &&
              choice > 0 &&
              choice <= _swapTokens.length
          ? [_swapTokens[choice - 1]]
          : _swapTokens
              .where((t) => t.blockchain.toLowerCase() == input.toLowerCase())
              .toList();
      if (matches.length != 1) {
        _message(
            'Choose one of the listed networks. Type cancel to start over.');
        return;
      }
      _swapToken = matches.single;
      _askSwapRecipient();
      return;
    }
    if (input.contains(RegExp(r'\s')) ||
        input.length < 10 ||
        input.length > 512) {
      _askSwapRecipient();
      return;
    }
    _swapRecipient = input;
    final tokens = await _near.getTokens();
    final zec = _near.findZecToken(tokens);
    if (!_current) return;
    if (zec == null || zec.decimals != 8) throw StateError('ZEC unavailable');
    final refundAddresses = await _wallet.getTransparentAddresses();
    if (!_current) return;
    if (refundAddresses.isEmpty) {
      _message(
          'A Zcash refund address is unavailable. Try again after the wallet has loaded.');
      return;
    }
    _message(
        'Getting a quote for ${WalletConversation.formatZec(_swapRequest!.zatoshis!)} ZEC → ${_swapToken!.displayName}…');
    final quote = await _near.getQuote(
        dry: false,
        originAsset: zec.assetId,
        destinationAsset: _swapToken!.assetId,
        amount: BigInt.from(_swapRequest!.zatoshis!),
        refundTo: refundAddresses.first,
        recipient: _swapRecipient!);
    if (!_current) return;
    if (!_quoteValid(quote, _swapRequest!.zatoshis!)) {
      _message(
          'The provider returned an incomplete or expired quote. Type swap to try again.');
      _swapRequest = null;
      return;
    }
    final request = WalletRequest(WalletCommand.send,
        recipient: quote.depositAddress, zatoshis: _swapRequest!.zatoshis);
    final destination = _swapToken!;
    final recipient = _swapRecipient!;
    _swapRequest = null;
    await _prepareSend(request,
        quote: quote, destination: destination, recipient: recipient);
  }

  bool _quoteValid(NearQuoteResponse q, int amount) {
    return q.isUsableExactInput(amount);
  }

  String _tokenAmount(BigInt amount, int decimals) {
    final scale = BigInt.from(10).pow(decimals);
    final fraction = (amount % scale).toString().padLeft(decimals, '0');
    return decimals == 0 ? amount.toString() : '${amount ~/ scale}.$fraction';
  }

  StoredSwap _storedSwap(
      NearQuoteResponse quote, NearToken token, String recipient, int zatoshis,
      {String? txid}) {
    return StoredSwap(
        provider: 'near_intents',
        depositAddress: quote.depositAddress,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        fromCurrency: 'ZEC',
        fromAmount: WalletConversation.formatZec(zatoshis),
        toCurrency: token.symbol,
        toAmount: _tokenAmount(quote.amountOut, token.decimals),
        toAddress: recipient,
        txId: txid,
        fromBlockchain: 'zec',
        toBlockchain: token.blockchain);
  }

  Future<void> _recordSwap(NearQuoteResponse quote, NearToken token,
      String recipient, int zatoshis, String txid) async {
    // Post-broadcast bookkeeping must never turn a successful send into a
    // retryable failure. The txid has already been displayed above.
    try {
      await SwapStore.save(
          _storedSwap(quote, token, recipient, zatoshis, txid: txid));
    } catch (_) {
      _message(
          'The deposit was sent, but saving swap history failed. Keep the transaction ID above.');
    }
    try {
      await _near.submitDeposit(
          txHash: txid, depositAddress: quote.depositAddress);
    } catch (_) {
      _message(
          'Deposit submitted on Zcash. The swap provider is still detecting it; do not send again.');
    }
    if (!_current) return;
    _trackedDeposit = quote.depositAddress;
    _lastSwapStatus = null;
    _message('The swap is awaiting your deposit confirmation.',
        card: TextButton(
            onPressed: () =>
                context.push('/swap/status', extra: quote.depositAddress),
            child: const Text('Open swap status')));
    _swapTimer?.cancel();
    _swapTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _pollSwap());
    await _pollSwap();
  }

  Future<void> _pollSwap() async {
    if (_pollingSwap || !_current || _trackedDeposit == null) return;
    _pollingSwap = true;
    try {
      final status = await _near.getStatus(_trackedDeposit!);
      if (!_current) return;
      if (status.status != _lastSwapStatus) {
        _lastSwapStatus = status.status;
        _message(status.isSuccess
            ? 'Swap complete. The destination tokens have been delivered.'
            : status.isRefunded
                ? 'The swap was refunded. Check your Zcash balance as it syncs.'
                : status.isFailed
                    ? 'The swap did not complete. Open swap status to check the deposit and refund.'
                    : status.isProcessing
                        ? 'Deposit detected. The swap is processing.'
                        : 'Waiting for the swap provider to confirm the deposit.');
      }
      if (status.isTerminal) {
        _swapTimer?.cancel();
        _trackedDeposit = null;
        boostSyncPolling();
      }
    } catch (_) {
      // A transient provider outage does not mean the swap failed. Retry on
      // the next bounded poll; the persisted swap also has a status page.
    } finally {
      _pollingSwap = false;
    }
  }

  // Keep the existing Z page's quiet header, expandable balance and chat
  // layout. The shared presentation widgets also render the original page.
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          backgroundColor: ZipherColors.bg,
          appBar: AppBar(
            backgroundColor: ZipherColors.bg,
            surfaceTintColor: Colors.transparent,
            centerTitle: true,
            title: _testnet
                ? Text('Testnet',
                    style: TextStyle(fontSize: 12, color: ZipherColors.text40))
                : null,
            leading: Navigator.of(context).canPop()
                ? IconButton(
                    tooltip: 'Back',
                    icon: Icon(Icons.arrow_back, color: ZipherColors.text60),
                    onPressed: () => Navigator.of(context).pop())
                : null,
          ),
          body: Column(children: [
            _buildBalanceHeader(),
            SyncStatusWidget(),
            // The keyboard leaves space for the conversation on smaller phones.
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              _buildHistoryStrip(),
            Expanded(
                child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: _messages.length + (_busy ? 1 : 0),
              itemBuilder: (_, index) {
                if (index == _messages.length)
                  return const ZChatTypingIndicator();
                final msg = _messages[index];
                return ZChatMessage(
                  text: msg.text,
                  isUser: msg.user,
                  card: index == 0
                      ? _buildSuggestionChips()
                      : msg.card == null
                          ? null
                          : Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: ZipherColors.cardBg,
                                  borderRadius:
                                      BorderRadius.circular(ZipherRadius.md),
                                  border: Border.all(
                                      color: ZipherColors.borderSubtle)),
                              child: msg.card),
                  footer: index == _messages.length - 1 &&
                          !_busy &&
                          (_conversation.pending != null ||
                              _swapRequest != null)
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: ZChatShortcut(
                              icon: Icons.close,
                              label: 'Cancel',
                              onTap: () => _submit('cancel')))
                      : null,
                );
              },
            )),
            ZChatComposer(
              controller: _input,
              busy: _busy,
              onSubmit: _submit,
              hint: _swapRequest != null
                  ? (_swapToken == null
                      ? 'Choose a network'
                      : 'Paste the recipient address')
                  : _choosingAddress
                      ? 'Choose a chain'
                      : _conversation.hint,
            ),
          ]),
        ),
      );

  Widget _buildSuggestionChips() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (icon, label) in [
            (Icons.arrow_upward_rounded, 'Send'),
            (Icons.qr_code_rounded, 'Receive'),
            (Icons.swap_horiz, 'Swap'),
            (Icons.account_balance_wallet_outlined, 'Balance'),
            (Icons.history_rounded, 'History'),
            (Icons.help_outline, 'Help'),
          ])
            ZChatShortcut(
                icon: icon,
                label: label,
                onTap: _busy ? null : () => _submit(label)),
        ]),
      );

  Widget _buildBalanceHeader() => Observer(builder: (_) {
        final b = _account.poolBalances;
        final price = marketPrice.price;
        final hasFiat = price != null && price > 0 && !_testnet;
        final currency = appSettings.currency.toUpperCase();
        final includesEvm = hasFiat && currency == 'USD' && _portfolio != null;
        final fiat = hasFiat
            ? (b.total / 1e8 * price +
                    (includesEvm ? _portfolio!.evmTotalUsd : 0))
                .toStringAsFixed(2)
            : null;
        final partial =
            includesEvm && (!_portfolio!.complete || !_portfolio!.fullyPriced);
        final expanded =
            _balanceExpanded && MediaQuery.viewInsetsOf(context).bottom == 0;
        return Semantics(
          button: true,
          label:
              expanded ? 'Collapse balance details' : 'Expand balance details',
          child: Material(
              color: ZipherColors.bg,
              child: InkWell(
                onTap: () {
                  setState(() => _balanceExpanded = !_balanceExpanded);
                  if (_balanceExpanded) _refreshPortfolio();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(
                              color: ZipherColors.borderSubtle, width: .5))),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Flexible(
                          child: Text(
                              fiat != null
                                  ? (currency == 'USD'
                                      ? '\$$fiat'
                                      : '$fiat $currency')
                                  : '${WalletConversation.formatZec(b.total)} ZEC',
                              style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                  color: ZipherColors.textPrimary,
                                  letterSpacing: -.5))),
                      const SizedBox(width: 8),
                      Icon(
                          expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: ZipherColors.text40),
                    ]),
                    if (!expanded)
                      Text(
                          includesEvm
                              ? (partial
                                  ? 'Tracked subtotal · incomplete'
                                  : 'Zcash + tracked EVM assets')
                              : 'Zcash balance',
                          style: TextStyle(
                              fontSize: 11, color: ZipherColors.text40)),
                    if (expanded) ...[
                      const SizedBox(height: 10),
                      Row(children: [
                        ClipOval(
                            child: Image.asset('assets/tokens/zec.png',
                                width: 18, height: 18)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                '${WalletConversation.formatZec(b.total)} ZEC',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: ZipherColors.text60,
                                    fontFamily: 'JetBrains Mono'))),
                        Text('Total',
                            style: TextStyle(
                                fontSize: 11, color: ZipherColors.text40)),
                      ]),
                      const SizedBox(height: 6),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                              '${WalletConversation.formatZec(b.shielded)} ZEC spendable',
                              style: TextStyle(
                                  fontSize: 12, color: ZipherColors.text60))),
                      if (b.hasUnconfirmed)
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                                '${WalletConversation.formatZec(b.unconfirmed)} ZEC confirming',
                                style: TextStyle(
                                    fontSize: 12, color: ZipherColors.text40))),
                      ConstrainedBox(
                          constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.sizeOf(context).height * .16),
                          child: SingleChildScrollView(
                              child: _portfolioDetails())),
                      if (!_testnet)
                        TextButton.icon(
                            onPressed: _loadingPortfolio
                                ? null
                                : () => _refreshPortfolio(force: true),
                            icon: const Icon(Icons.refresh, size: 14),
                            label: Text(
                                _loadingPortfolio
                                    ? 'Refreshing…'
                                    : 'Refresh other chains',
                                style: const TextStyle(fontSize: 11))),
                    ],
                  ]),
                ),
              )),
        );
      });

  Widget _buildHistoryStrip() => Observer(builder: (_) {
        final records = _account.txs.items.toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        if (records.isEmpty) return const SizedBox.shrink();
        return Container(
          decoration: BoxDecoration(
              border: Border(
                  bottom:
                      BorderSide(color: ZipherColors.borderSubtle, width: .5))),
          child: Column(children: [
            InkWell(
              onTap: () => setState(() => _historyExpanded = !_historyExpanded),
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(children: [
                    Icon(Icons.history_rounded,
                        size: 14, color: ZipherColors.text40),
                    const SizedBox(width: 6),
                    Text('Recent Actions',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: .5,
                            color: ZipherColors.text40)),
                    const Spacer(),
                    Icon(
                        _historyExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: ZipherColors.text40),
                  ])),
            ),
            if (_historyExpanded)
              ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * .18),
                  child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final tx in records.take(10))
                          Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 4),
                              child: Row(children: [
                                Icon(
                                    tx.value >= 0
                                        ? Icons.arrow_downward_rounded
                                        : Icons.arrow_upward_rounded,
                                    size: 14,
                                    color: ZipherColors.text40),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text(
                                        '${tx.value >= 0 ? '+' : '−'}${tx.value.abs().toStringAsFixed(8)} ZEC',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: ZipherColors.text60),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)),
                                const SizedBox(width: 8),
                                Text(
                                    tx.expiredUnmined
                                        ? 'Expired'
                                        : tx.height > 0
                                            ? 'Confirmed'
                                            : 'Pending',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: ZipherColors.text40)),
                              ])),
                      ])),
          ]),
        );
      });
}
