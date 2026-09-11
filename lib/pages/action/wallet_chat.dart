import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:intl/intl.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../coin/coins.dart';
import '../../services/near_intents.dart';
import '../../services/network_privacy.dart';
import '../../services/wallet_swap_tracker.dart';
import '../../services/evm_portfolio_balance.dart';
import '../../services/wallet_receive_address.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_registry.dart';
import '../scan.dart';
import 'wallet_chat_input.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../main/home.dart' show showWalletAccountSwitcher;
import '../tx.dart' show gotoTx;
import '../../services/app_log.dart';
import 'widgets/wallet_balance_details.dart';
import 'widgets/wallet_activity_row.dart';
import 'widgets/wallet_activity_panel.dart';
import '../utils.dart';
import 'wallet_conversation.dart';
import 'widgets/wallet_review_card.dart';
import 'widgets/z_chat_widgets.dart';

/// The home and Z entry points share one conversation. No model initialization,
/// remote language parsing is needed. Public EVM balances refresh separately.
class WalletChatPage extends StatelessWidget {
  final String? initialIntent;
  final EvmBalanceReader? balanceReader;
  final NetworkPrivacy? privacy;
  const WalletChatPage(
      {super.key, this.initialIntent, this.balanceReader, this.privacy});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: testnetNotifier,
      builder: (_, network, __) => Observer(
          builder: (_) => _WalletChat(
                key: ValueKey('${aaSequence.seqno}:$network'),
                initialIntent: initialIntent,
                balanceReader: balanceReader,
                privacy: privacy,
              )));
}

class _WalletChat extends StatefulWidget {
  final String? initialIntent;
  final EvmBalanceReader? balanceReader;
  final NetworkPrivacy? privacy;
  const _WalletChat(
      {super.key, this.initialIntent, this.balanceReader, this.privacy});
  @override
  State<_WalletChat> createState() => _WalletChatState();
}

class _WalletChatState extends State<_WalletChat> with WidgetsBindingObserver {
  final _conversation = WalletConversation();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _latestMessageKey = GlobalKey();
  final _messages = <({String text, bool user, Widget? card})>[];
  final _wallet = WalletService.instance;
  final _near = NearIntentsService();
  NetworkPrivacy get _privacy => widget.privacy ?? NetworkPrivacy.instance;
  late final String? _walletId;
  late final bool _testnet;
  late final ActiveAccount2 _account;
  final _reviewEpoch = ValueNotifier<int>(0);
  final _portfolioUpdates = ValueNotifier<int>(0);
  bool _busy = false;
  String _busyLabel = 'Working…';
  bool _balanceExpanded = false;
  WalletHomeTab _homeTab = WalletHomeTab.chat;
  bool _choosingAddress = false;
  late final EvmBalanceReader _balanceReader;
  EvmBalanceSnapshot? _portfolio;
  bool _loadingPortfolio = false;
  Timer? _portfolioTimer;
  bool _swapAwaitingAmount = false;
  WalletRequest? _swapRequest;
  List<NearToken> _swapTokens = [];
  NearToken? _swapToken;
  String? _swapRecipient;
  late final WalletSwapTracker _swapTracker;
  String? _trackedDeposit;
  String? _lastSwapStatus;
  ChatManagementStep? _managementStep;
  String? _contactChain;
  String? _contactName;
  late String _displayName;

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
    _displayName = _account.name;
    WalletRegistry.instance.changes.addListener(_refreshAccountName);
    _refreshAccountName();
    _swapTracker = WalletSwapTracker(
        walletId: _walletId,
        testnet: _testnet,
        transactionIds: () =>
            _account.txs.items.map((tx) => tx.fullTxId).toSet(),
        canPoll: () =>
            _current &&
            (WidgetsBinding.instance.lifecycleState == null ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.resumed) &&
            TickerMode.valuesOf(context).enabled,
        readStatus: _near.getStatus)
      ..addListener(_onSwapUpdate);
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
      if (_current && _wallet.isWalletOpen) _swapTracker.start();
      _refreshPortfolio();
      if (widget.initialIntent != null && _current)
        _submit(widget.initialIntent!);
    });
  }

  @override
  void dispose() {
    WalletRegistry.instance.changes.removeListener(_refreshAccountName);
    _swapTracker.dispose();
    _portfolioTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    _reviewEpoch.dispose();
    _portfolioUpdates.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPortfolio(force: true);
      if (_wallet.isWalletOpen) {
        boostSyncPolling();
        _swapTracker.refresh();
      }
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
    _portfolioUpdates.value++;
    AppLog.instance.event('portfolio', 'refresh_started');
    try {
      if (_account.chainAddresses == null && _wallet.isWalletOpen)
        await _account.updateChainAddresses();
      if (!_current) return;
      final address = _account.chainAddresses?.evm;
      if (address == null || address.isEmpty) return;
      final result = await _balanceReader.fetch(address,
          force: force,
          bitcoin: _account.chainAddresses?.bitcoin,
          solana: _account.chainAddresses?.solana);
      if (_current) {
        setState(() => _portfolio = result);
        _portfolioUpdates.value++;
        AppLog.instance.event('portfolio', 'refresh_completed',
            detail:
                'assets=${result.tokens.length} unavailable=${result.unavailableChains.join(",")}');
      }
    } catch (e) {
      AppLog.instance.event('portfolio', 'refresh_failed', error: e);
    } finally {
      if (mounted) {
        setState(() => _loadingPortfolio = false);
        _portfolioUpdates.value++;
      }
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
    if (!user) AppLog.instance.event('chat', 'response', detail: text);
    setState(() => _messages.add((text: text, user: user, card: card)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        final target = _latestMessageKey.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(target,
              alignment: 0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut);
        } else {
          // Build an off-screen lazy reply before aligning its beginning.
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final target = _latestMessageKey.currentContext;
            if (mounted && target != null) {
              Scrollable.ensureVisible(target, alignment: 0);
            }
          });
        }
      }
    });
  }

  void _clearDraft() {
    _managementStep = null;
    _contactChain = null;
    _contactName = null;
    _conversation.cancel();
    _choosingAddress = false;
    _swapRequest = null;
    _swapAwaitingAmount = false;
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
      AppLog.instance.event('chat', 'request_failed', error: e);
      if (_current) {
        if (e is NearIntentsException &&
            e.minimumZatoshis != null &&
            _swapRequest != null) {
          _swapAwaitingAmount = true;
          _message(
              'This route currently needs at least ${WalletConversation.formatZec(e.minimumZatoshis!)} ZEC. Enter a new amount in ZEC, or cancel.');
          return;
        }
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
    if (_homeTab != WalletHomeTab.chat)
      setState(() => _homeTab = WalletHomeTab.chat);
    if (WalletConversation.command(text) == WalletCommand.clear) {
      _clearChat();
      return;
    }
    _input.clear();
    _message(text.trim(), user: true);
    await _run(() async {
      if (await _manage(text)) return;
      final command = WalletConversation.command(text);
      setState(() => _busyLabel = switch (command) {
            WalletCommand.balance => 'Updating balances…',
            WalletCommand.history => 'Loading transactions…',
            WalletCommand.memos => 'Loading memos…',
            WalletCommand.receive => 'Preparing your address…',
            WalletCommand.send => 'Preparing your payment…',
            WalletCommand.swap => 'Finding swap options…',
            WalletCommand.torOn => 'Connecting to Tor…',
            WalletCommand.torOff => 'Changing connection…',
            _ => 'Working…',
          });
      AppLog.instance.event('chat', 'command',
          detail:
              'command=${command.name} draft=${_conversation.pending?.command.name ?? _swapRequest?.command.name ?? "none"}');
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
        _swapAwaitingAmount = false;
        _swapToken = null;
        _swapTokens = [];
        _swapRecipient = null;
        _reviewEpoch.value++;
      }
      final reply = _conversation.accept(text);
      if (reply.prompt != null) {
        final askingAmount =
            _conversation.pending?.command == WalletCommand.send &&
                _conversation.pending?.zatoshis == null;
        _message(reply.prompt!,
            card: askingAmount
                ? Observer(
                    builder: (_) => Text(
                        '${_assetAmount(_account.poolBalances.shielded / 1e8)} ZEC available · fee applies',
                        style: const TextStyle(
                            fontFamily: 'JetBrains Mono',
                            fontSize: 12,
                            color: ZipherColors.textSecondary)))
                : null);
      }
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
          _message('Your assets',
              card: ValueListenableBuilder<int>(
                  valueListenable: _portfolioUpdates,
                  builder: (_, __, ___) => Observer(builder: (_) {
                        final b = _account.poolBalances;
                        final price = _zecUsdPrice;
                        return Column(children: [
                          _assetRow(
                              chain: 'Zcash',
                              symbol: 'ZEC',
                              amount: b.total / 1e8,
                              dollars:
                                  price == null ? null : b.total / 1e8 * price,
                              onTap: _showPools),
                          _portfolioDetails(
                              onRefresh: () => _refreshPortfolio(force: true)),
                        ]);
                      })));
        case WalletCommand.pools:
          await _account.updateBalance();
          if (_current)
            _message('Your ZEC by pool',
                card: Observer(
                    builder: (_) => WalletPoolDetails(_account.poolBalances)));
        case WalletCommand.privacy:
          _message(_privacy.label, card: _privacyControls());
        case WalletCommand.torOn:
          await _changePrivacy(true);
        case WalletCommand.torOff:
          await _changePrivacy(false);
        case WalletCommand.nym:
        case WalletCommand.vpn:
          _message(
              'Nym and external VPNs are managed in their own app. Zipher cannot verify whether they are connected. Built-in Tor is available for Zcash.',
              card: _privacyControls());
        case WalletCommand.history:
          FocusScope.of(context).unfocus();
          setState(() => _homeTab = WalletHomeTab.activity);
        case WalletCommand.memos:
          await _showMemos();
        case WalletCommand.clear:
          _clearChat();
        case WalletCommand.help:
          _message('What would you like to do?', card: _helpCard());
        case WalletCommand.cancel:
        case WalletCommand.unknown:
          break;
      }
    });
  }

  Future<void> _refreshAccountName() async {
    if (_walletId == null) return;
    final accounts = await WalletRegistry.instance.getAllVisibleAccounts();
    final matches = accounts.where((a) =>
        a.walletId == _walletId && a.accountIndex == _account.accountIndex);
    if (mounted && matches.isNotEmpty) {
      final name = matches.first.displayName;
      if (_displayName != name) setState(() => _displayName = name);
    }
  }

  static const _contactChains = [
    'zec',
    'btc',
    'sol',
    'eth',
    'arb',
    'base',
    'op',
    'pol',
    'bsc'
  ];

  Widget _managementAction(String label, Future<void> Function() action,
      {bool danger = false}) {
    final epoch = _reviewEpoch.value;
    return ValueListenableBuilder<int>(
        valueListenable: _reviewEpoch,
        builder: (_, value, __) => TextButton(
            style: danger
                ? TextButton.styleFrom(foregroundColor: ZipherColors.red)
                : null,
            onPressed: value != epoch
                ? null
                : () => _run(() async {
                      if (!_current || _reviewEpoch.value != epoch) return;
                      await action();
                    }),
            child: Text(label)));
  }

  Future<bool> _manage(String text) async {
    final tool = chatTool(text);
    final command = WalletConversation.command(text);
    if (command == WalletCommand.cancel) {
      _managementStep = null;
      return false;
    }
    // Once prompted, treat the reply as data (a contact can be named "Send").
    if (_managementStep != null && tool != ChatTool.scan) {
      final value = text.trim();
      switch (_managementStep!) {
        case ChatManagementStep.contactChain:
          final chain = WalletReceiveAddress.requestedChain(value);
          if (chain == null || !_contactChains.contains(chain)) {
            _message('Choose one of the supported chains above.');
            return true;
          }
          _contactChain = chain;
          _managementStep = ChatManagementStep.contactName;
          _message('What’s their name?');
        case ChatManagementStep.contactName:
          if (value.isEmpty || value.length > 60) {
            _message('Use a name between 1 and 60 characters.');
            return true;
          }
          _contactName = value;
          _managementStep = ChatManagementStep.contactAddress;
          _message(
              'Paste their ${ChainInfo.byId(_contactChain)?.name ?? _contactChain} address, or tap scan.');
        case ChatManagementStep.contactAddress:
          await _reviewContact(value);
        case ChatManagementStep.rename:
          if (value.isEmpty || value.length > 60) {
            _message('Use a name between 1 and 60 characters.');
            return true;
          }
          if (_walletId == null) return true;
          await WalletRegistry.instance.rename(_walletId, value);
          if (!_current) return true;
          _account.name = value;
          _clearDraft();
          _message('Account renamed.');
          AppLog.instance.event('wallet', 'renamed');
        case ChatManagementStep.review:
          _message('Use the confirmation button above, or type cancel.');
      }
      return true;
    }
    if (tool == null) return false;
    AppLog.instance.event('chat', 'tool', detail: tool.name);
    if (tool != ChatTool.scan) _clearDraft();
    switch (tool) {
      case ChatTool.addContact:
        _managementStep = ChatManagementStep.contactChain;
        _message('Which chain is the contact on?',
            card: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final id in _contactChains)
                ZChatShortcut(
                    leading: WalletChainLogo(id),
                    label: ChainInfo.byId(id)?.name ?? id,
                    onTap: () => _submit(ChainInfo.byId(id)?.name ?? id)),
            ]));
      case ChatTool.contacts:
        await contacts.fetchContacts();
        if (!_current) return true;
        if (contacts.loadError.value != null) {
          _message(contacts.loadError.value!);
          return true;
        }
        final saved = contacts.contacts.toList();
        final legacy = await ContactChainStore.loadAll();
        if (!_current) return true;
        _message(
            saved.isEmpty
                ? 'No contacts yet. Type add contact to save one.'
                : 'Your contacts',
            card: saved.isEmpty
                ? null
                : Column(children: [
                    for (final c in saved)
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: WalletChainLogo(
                              c.chainId ?? legacy[c.address] ?? 'zec'),
                          title: Text(c.name ?? 'Contact'),
                          subtitle: Text(ChainInfo.byId(
                                      c.chainId ?? legacy[c.address] ?? 'zec')
                                  ?.name ??
                              'Address'),
                          onTap: () => _run(() async {
                                _clearDraft();
                                final chain =
                                    c.chainId ?? legacy[c.address] ?? 'zec';
                                _message(c.name ?? 'Contact',
                                    card: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          SelectableText(c.address ?? '',
                                              style: const TextStyle(
                                                  fontSize: 12)),
                                          Row(children: [
                                            TextButton.icon(
                                                icon: const Icon(
                                                    Icons.copy_rounded,
                                                    size: 16),
                                                label: const Text('Copy'),
                                                onPressed: () async {
                                                  await Clipboard.setData(
                                                      ClipboardData(
                                                          text:
                                                              c.address ?? ''));
                                                  if (_current)
                                                    _message('Address copied.');
                                                }),
                                            if (chain == 'zec')
                                              _managementAction('Send ZEC',
                                                  () async {
                                                _clearDraft();
                                                final reply = _conversation
                                                    .accept(c.address ?? '');
                                                _message(reply.prompt ??
                                                    'Enter the amount in ZEC.');
                                              }),
                                          ])
                                        ]));
                              })),
                  ]));
      case ChatTool.accounts:
        FocusScope.of(context).unfocus();
        showWalletAccountSwitcher(context);
      case ChatTool.renameAccount:
        _managementStep = ChatManagementStep.rename;
        _message('What would you like to call this account?');
      case ChatTool.deleteAccount:
        final choices = (await WalletRegistry.instance.getAllVisibleAccounts())
            .where((a) => a.accountIndex == 0 && a.walletId != _walletId)
            .toList();
        if (!_current) return true;
        _message(
            choices.isEmpty
                ? 'Switch to another account before removing this one. Your active account stays on this device.'
                : 'Which account would you like to remove from this device?',
            card: choices.isEmpty
                ? null
                : Column(children: [
                    for (final a in choices)
                      _managementAction(a.displayName, () async {
                        _clearDraft();
                        _managementStep = ChatManagementStep.review;
                        _message(
                            'Remove ${a.displayName}? This deletes its local wallets and keys on both networks. You need your backed-up seed phrase to restore access. Funds stay on-chain.',
                            card: _managementAction('Remove account', () async {
                              final epoch = _reviewEpoch.value;
                              final authorized = await authenticate(context,
                                  'Remove ${a.displayName} from this device');
                              if (!_current ||
                                  !authorized ||
                                  epoch != _reviewEpoch.value ||
                                  _wallet.activeWalletId == a.walletId) return;
                              await _wallet.deleteWalletById(a.walletId);
                              if (!_current) return;
                              _clearDraft();
                              _message('Account removed from this device.');
                              AppLog.instance.event('wallet', 'removed');
                            }, danger: true));
                      }),
                  ]));
      case ChatTool.scan:
        await _scanCode();
    }
    return true;
  }

  Future<void> _reviewContact(String address) async {
    final validation = _contactChain == 'zec'
        ? ((await _wallet.validateAddress(address)).isValid
            ? null
            : 'Invalid Zcash address for this network.')
        : chainAddressValidator(address, _contactChain!);
    if (!_current) return;
    if (validation != null) {
      _message(validation);
      return;
    }
    final chain = _contactChain!;
    final name = _contactName!;
    _managementStep = ChatManagementStep.review;
    _message('Save contact',
        card: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
              contentPadding: EdgeInsets.zero,
              leading: WalletChainLogo(chain),
              title: Text(name),
              subtitle: Text(ChainInfo.byId(chain)?.name ?? chain)),
          SelectableText(address, style: const TextStyle(fontSize: 12)),
          _managementAction('Save contact', () async {
            // Chain, name and address are one secure-storage write.
            await contacts.add(
                Contact(id: 0, name: name, address: address, chainId: chain));
            if (!_current) return;
            _clearDraft();
            _message('Contact saved. Type contacts to find them.');
            AppLog.instance.event('contacts', 'saved', detail: 'chain=$chain');
          }),
        ]));
  }

  Future<void> _scanCode() async {
    FocusScope.of(context).unfocus();
    final epoch = _reviewEpoch.value;
    AppLog.instance.event('qr', 'opened');
    final text = await scanQRCode(context);
    if (!_current || epoch != _reviewEpoch.value) return;
    if (text.isEmpty) {
      AppLog.instance.event('qr', 'cancelled');
      return;
    }
    if (_managementStep == ChatManagementStep.contactAddress) {
      await _reviewContact(text.trim());
      return;
    }
    if (_managementStep != null) {
      _message(
          'Choose a contact chain and name before scanning their address.');
      return;
    }
    if (_swapRequest != null && _swapToken != null) {
      await _continueSwap(text.trim());
      return;
    }
    try {
      var payment = scannedPayment(text, testnet: _testnet);
      final valid = await _wallet.validateAddress(payment.recipient!);
      if (!_current) return;
      if (!valid.isValid)
        throw const FormatException(
            'That Zcash address is invalid for this network.');
      final pending = _conversation.pending;
      if (payment.zatoshis == null && pending?.command == WalletCommand.send) {
        payment = WalletRequest(WalletCommand.send,
            recipient: payment.recipient,
            zatoshis: pending?.zatoshis,
            memo: payment.memo ?? pending?.memo);
      }
      _clearDraft();
      AppLog.instance.event('qr', 'payment_read');
      if (payment.zatoshis == null) {
        _conversation.pending = payment;
        _message('Address scanned. How much ZEC would you like to send?',
            card: Text(
                '${WalletConversation.formatZec(_account.poolBalances.shielded)} ZEC available · fee applies',
                style: const TextStyle(fontSize: 12)));
      } else {
        await _prepareSend(payment);
      }
    } on FormatException catch (e) {
      AppLog.instance.event('qr', 'rejected');
      _message(e.message);
    }
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
                      leading: WalletChainLogo(choice.id),
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
    AppLog.instance
        .event('receive', 'address_shown', detail: 'chain=${choice.id}');
    if (choice.id == 'zec' && _wallet.isWalletOpen) boostSyncPolling();
    _message(
        'Your ${choice.label} ${choice.id == 'zec' ? 'shielded ' : 'mainnet '}receive address.',
        card: Column(children: [
          Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImage(data: choice.address, size: 180)),
          const SizedBox(height: 12),
          SelectableText(choice.address, style: TextStyle(fontSize: 12)),
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
                  AppLog.instance.event('receive', 'address_copied',
                      detail: 'chain=${choice.id}');
                  _message('${choice.label} address copied.');
                } catch (_) {
                  _message(
                      'Copy failed. You can select and copy the full address above.');
                }
              }),
        ]));
  }

  Widget _portfolioDetails({VoidCallback? onRefresh}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final t in _portfolio?.tokens ?? <EvmTokenBalance>[])
          _assetRow(
              chain: t.chainLabel,
              symbol: t.symbol,
              amount: t.balance,
              dollars: t.priceAvailable ? t.balanceUsd : null,
              stale: t.stale),
        if (_portfolio?.unavailableChains.isNotEmpty == true)
          Text('Unavailable: ${_portfolio!.unavailableChains.join(", ")}',
              style: TextStyle(fontSize: 11, color: ZipherColors.text40)),
        if (_portfolio == null && !_testnet)
          Text(
              _loadingPortfolio
                  ? 'Loading assets…'
                  : 'Other assets unavailable',
              style: TextStyle(fontSize: 11, color: ZipherColors.text40)),
        if (onRefresh != null)
          TextButton(
              onPressed: _loadingPortfolio ? null : onRefresh,
              child: const Text('Refresh balances')),
      ]);

  void _openTransaction(String txid) {
    if (!_current) return;
    final index = _account.txs.items.indexWhere((tx) => tx.fullTxId == txid);
    if (index < 0) {
      _message('This transaction is refreshing. Try history again.');
      return;
    }
    AppLog.instance.event('history', 'transaction_opened');
    gotoTx(context, index);
  }

  Widget _activityList(Iterable<Tx> records, {bool showMemo = false}) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        for (final tx in records)
          WalletActivityRow(
              transaction: tx,
              showMemo: showMemo,
              onTap: () => _openTransaction(tx.fullTxId))
      ]);

  Future<void> _showMemos() async {
    await _account.updateTransactions();
    if (!_current) return;
    final records = _account.txs.items
        .where((tx) => tx.memo?.trim().isNotEmpty ?? false)
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (records.isEmpty) {
      _message(
          'No memos yet. Incoming and outgoing memos appear here as your wallet syncs.');
    } else {
      _message('Latest memos · tap to read the transaction',
          card: _activityList(records.take(10), showMemo: true));
    }
  }

  void _clearChat() {
    if (_busy) return;
    _clearDraft();
    _input.clear();
    setState(() {
      _messages
        ..clear()
        ..add((text: 'What would you like to do?', user: false, card: null));
      _balanceExpanded = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    AppLog.instance.event('chat', 'cleared');
  }

  Widget _helpCard() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (command, example, icon) in [
          ('Send', 'Send 0.01 ZEC to an address', Icons.north_east_rounded),
          (
            'Receive',
            'Choose a chain, then copy your address',
            Icons.qr_code_rounded
          ),
          (
            'Swap',
            'Choose an asset and review the quote',
            Icons.swap_horiz_rounded
          ),
          (
            'Balance',
            'See your assets and available funds',
            Icons.account_balance_wallet_outlined
          ),
          (
            'Add contact',
            'Save a name, chain and address',
            Icons.person_add_alt_rounded
          ),
          (
            'Contacts',
            'Find or pay a saved Zcash contact',
            Icons.people_outline_rounded
          ),
          (
            'Scan',
            'Scan an address or Zcash payment request',
            Icons.qr_code_scanner_rounded
          ),
          ('Rename account', 'Change this account’s name', Icons.edit_outlined),
          (
            'Delete account',
            'Remove an inactive account from this device',
            Icons.person_remove_outlined
          ),
          ('Accounts', 'Choose another account', Icons.account_circle_rounded),
          (
            'Memos',
            'Read your latest wallet messages',
            Icons.chat_bubble_outline_rounded
          ),
          (
            'Privacy',
            'Manage your Zcash Tor connection',
            Icons.vpn_key_rounded
          ),
        ])
          ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(icon, size: 18, color: ZipherColors.cyan),
              title: Text(command,
                  style: const TextStyle(color: ZipherColors.textPrimary)),
              subtitle: Text(example,
                  style: const TextStyle(
                      color: ZipherColors.text40, fontSize: 12)),
              onTap: () => _submit(command)),
        const SizedBox(height: 8),
        const Text(
            'Review, tap Send, then confirm with Face ID or your device passcode. Activity contains pending and completed transfers. Type cancel to discard a draft.',
            style: TextStyle(
                fontSize: 12, color: ZipherColors.textSecondary, height: 1.5)),
        const SizedBox(height: 8),
        TextButton.icon(
            onPressed: _clearChat,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Clear chat')),
        const Text('Clearing chat keeps your wallet and transaction history.',
            style: TextStyle(fontSize: 11, color: ZipherColors.text40)),
      ]);

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
    var proposal = await _wallet.proposeSend(address, request.zatoshis!,
        memo: request.memo);
    if (!_current) return;
    if (!proposal.isExact || proposal.sendAmount != request.zatoshis) {
      _message(
          'The wallet couldn’t prepare that exact amount. Start again with a smaller amount.');
      return;
    }
    var revision = _wallet.proposalRevision;
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
    FocusScope.of(context).unfocus();
    AppLog.instance.event(quote == null ? 'send' : 'swap', 'review_shown');
    _message('',
        card: WalletReviewCard(
          epoch: _reviewEpoch,
          expectedEpoch: epoch,
          details: details,
          onPriorityChanged: (priority) async {
            if (_busy || !_current || _reviewEpoch.value != epoch) {
              throw StateError('Review no longer available');
            }
            setState(() {
              _busy = true;
              _busyLabel = 'Updating fee…';
            });
            try {
              if (quote != null && !_quoteValid(quote, request.zatoshis!)) {
                _reviewEpoch.value++;
                _message(
                    'This quote expired. Start a new swap for a fresh review.');
                throw StateError('Quote expired');
              }
              final next = await _wallet.proposeSend(address, request.zatoshis!,
                  memo: request.memo, priority: priority);
              if (!_current ||
                  _reviewEpoch.value != epoch ||
                  !next.isExact ||
                  next.sendAmount != request.zatoshis) {
                throw StateError('Review changed');
              }
              proposal = next;
              revision = _wallet.proposalRevision;
              AppLog.instance.event('send', 'fee_updated',
                  detail: 'priority=$priority fee=${next.fee}');
              return {
                ...details,
                'Network fee': '${WalletConversation.formatZec(next.fee)} ZEC',
                'Total':
                    '${WalletConversation.formatZec(next.sendAmount + next.fee)} ZEC'
              };
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
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
    if (_swapAwaitingAmount) {
      final amount = WalletConversation.parseZatoshis(input);
      if (amount == null || amount <= 0) {
        _message('Enter an amount in ZEC, or cancel.');
        return;
      }
      _swapRequest = _swapRequest!.withFields(zatoshis: amount);
      _swapAwaitingAmount = false;
      input = _swapRecipient!;
    }
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
      _swapAwaitingAmount = false;
      return;
    }
    final request = WalletRequest(WalletCommand.send,
        recipient: quote.depositAddress, zatoshis: _swapRequest!.zatoshis);
    final destination = _swapToken!;
    final recipient = _swapRecipient!;
    _swapRequest = null;
    _swapAwaitingAmount = false;
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
        walletId: _walletId,
        testnet: _testnet,
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
    _swapTracker
        .track(_storedSwap(quote, token, recipient, zatoshis, txid: txid));
    await _swapTracker.refresh();
  }

  void _onSwapUpdate() {
    if (!_current || _trackedDeposit == null) return;
    final entry = _swapTracker.entries
        .where((entry) => entry.swap.depositAddress == _trackedDeposit)
        .firstOrNull;
    final status = entry?.status;
    if (status == null || status.status == _lastSwapStatus) return;
    _lastSwapStatus = status.status;
    _message(status.isSuccess
        ? 'Swap complete. The destination tokens have been delivered.'
        : status.isRefunded
            ? 'The swap was refunded. Check your Zcash balance as it syncs.'
            : status.isFailed
                ? 'The swap did not complete. Open Activity to check the deposit and refund.'
                : status.isProcessing
                    ? 'Deposit detected. The swap is processing.'
                    : 'Waiting for the swap provider to confirm the deposit.');
    if (status.isTerminal) {
      _trackedDeposit = null;
      boostSyncPolling();
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
            centerTitle: false,
            automaticallyImplyLeading: false,
            title: TextButton.icon(
              onPressed: () {
                FocusScope.of(context).unfocus();
                AppLog.instance.event('wallet', 'account_switcher_opened');
                showWalletAccountSwitcher(context);
              },
              icon: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                      color: ZipherColors.cyan.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(ZipherRadius.md)),
                  child: Icon(Icons.account_circle_rounded,
                      size: 18,
                      color: ZipherColors.cyan.withValues(alpha: .7))),
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                    child: Text(_displayName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: ZipherColors.textPrimary, fontSize: 15))),
                const Icon(Icons.expand_more, size: 18),
              ]),
            ),
            actions: [
              _walletIndicators(),
              if (_testnet)
                const Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: Center(child: Text('Testnet')))
            ],
          ),
          body: Column(children: [
            _buildBalanceHeader(),
            Expanded(
                child: _buildHomeViews(Column(children: [
              Expanded(
                  child: ListView.builder(
                controller: _scroll,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: _messages.length + (_busy ? 1 : 0),
                itemBuilder: (_, index) {
                  if (index == _messages.length)
                    return ZChatTypingIndicator(label: _busyLabel);
                  final msg = _messages[index];
                  return ZChatMessage(
                    key: index == _messages.length - 1
                        ? _latestMessageKey
                        : null,
                    text: index == 0 ? '' : msg.text,
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
                                _managementStep != null ||
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
                onScan: () => _submit('scan'),
                hint: _managementStep != null
                    ? switch (_managementStep!) {
                        ChatManagementStep.contactChain => 'Choose a chain',
                        ChatManagementStep.contactName => 'Contact name',
                        ChatManagementStep.contactAddress =>
                          'Paste the wallet address',
                        ChatManagementStep.rename => 'New account name',
                        ChatManagementStep.review => 'Review above, or cancel',
                      }
                    : _swapRequest != null
                        ? (_swapAwaitingAmount
                            ? 'Amount in ZEC'
                            : _swapToken == null
                                ? 'Choose a network'
                                : 'Paste the recipient address')
                        : _choosingAddress
                            ? 'Choose a chain'
                            : _conversation.hint,
              ),
            ]))),
          ]),
        ),
      );

  Widget _buildSuggestionChips() => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('What would you like to do?',
            style: TextStyle(
                fontSize: 15,
                color: ZipherColors.textPrimary,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (icon, label) in [
            (Icons.arrow_upward_rounded, 'Send'),
            (Icons.qr_code_rounded, 'Receive'),
            (Icons.swap_horiz, 'Swap'),
          ])
            ZChatShortcut(
                icon: icon,
                label: label,
                onTap: _busy ? null : () => _submit(label)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 4, runSpacing: 4, children: [
          for (final (icon, label) in [
            (Icons.account_balance_wallet_outlined, 'Balance'),
            (Icons.people_outline_rounded, 'Contacts'),
            (Icons.help_outline, 'Help'),
          ])
            ZChatShortcut(
                icon: icon,
                label: label,
                secondary: true,
                onTap: _busy ? null : () => _submit(label)),
        ]),
      ]));

  void _showPools() {
    FocusScope.of(context).unfocus();
    AppLog.instance.event('balance', 'pool_breakdown_opened');
    showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: ZipherColors.surface,
        builder: (_) => SafeArea(
            child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                child: Observer(
                    builder: (_) =>
                        WalletPoolDetails(_account.poolBalances)))));
  }

  String _dollars(double amount) =>
      NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(amount);

  double? get _zecUsdPrice => appSettings.currency.toUpperCase() == 'USD'
      ? marketPrice.price ?? _portfolio?.zecPriceUsd
      : _portfolio?.zecPriceUsd;

  String _assetAmount(double amount) {
    if (amount > 0 && amount < 0.00000001) return '<0.00000001';
    return amount.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  Widget _assetRow(
          {required String chain,
          required String symbol,
          required double amount,
          double? dollars,
          bool stale = false,
          VoidCallback? onTap}) =>
      InkWell(
          onTap: onTap,
          onLongPress: onTap,
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(children: [
                WalletChainLogo(chain, size: 24),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(symbol,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: ZipherColors.textPrimary)),
                      const SizedBox(height: 2),
                      Text(chain,
                          style: TextStyle(
                              fontSize: 11, color: ZipherColors.text40)),
                    ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(
                      stale
                          ? 'Last known'
                          : dollars == null
                              ? '—'
                              : _dollars(dollars),
                      style: TextStyle(
                          fontSize: 14, color: ZipherColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text('${_assetAmount(amount)} $symbol',
                      style:
                          TextStyle(fontSize: 11, color: ZipherColors.text40)),
                ]),
              ])));

  Future<void> _changePrivacy(bool enabled) async {
    if (_privacy.busy) {
      _message('A connection change is already in progress.');
      return;
    }
    _message(
        enabled ? 'Connecting to Tor…' : 'Switching to a direct connection…');
    try {
      await _privacy.setTor(enabled);
      if (_current) {
        _message(
            enabled
                ? 'Tor is verified for Zcash sync and broadcasts. Prices, other chains and swap services use separate connections.'
                : 'Zcash now uses a direct connection.',
            card: _privacyControls());
        // The backend replaced live channels. Refresh the UI's start flag too
        // after a failed bootstrap previously stopped the workers.
        if (_wallet.isWalletOpen) await syncStatus2.sync(restart: true);
      }
    } catch (_) {
      if (_current)
        _message(
            'Tor could not be verified. Retry, or explicitly turn Tor off to use a direct connection.',
            card: _privacyControls());
    }
  }

  Widget _privacyControls() => ListenableBuilder(
      listenable: _privacy,
      builder: (_, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_privacy.label,
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: ZipherColors.textPrimary)),
                const SizedBox(height: 12),
                const Text(
                    'Tor covers Zcash sync and transaction broadcasts. Prices, other chains and swap services use separate connections.',
                    style: TextStyle(
                        color: ZipherColors.textSecondary, height: 1.5)),
                const SizedBox(height: 12),
                const Text('External VPN / Nym: not verified by Zipher.',
                    style: TextStyle(color: ZipherColors.text40, fontSize: 12)),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (_privacy.state != NetworkPrivacyState.tor)
                    OutlinedButton.icon(
                        onPressed:
                            _privacy.busy ? null : () => _submit('enable Tor'),
                        icon: const Icon(Icons.vpn_key_rounded, size: 16),
                        label: Text(_privacy.state == NetworkPrivacyState.error
                            ? 'Retry Tor'
                            : 'Enable Tor')),
                  if (_privacy.state != NetworkPrivacyState.direct)
                    TextButton(
                        onPressed:
                            _privacy.busy ? null : () => _submit('disable Tor'),
                        child: const Text('Turn Tor off')),
                ]),
              ]));

  void _showNetworkPrivacy() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        backgroundColor: ZipherColors.surface,
        showDragHandle: true,
        builder: (_) => SafeArea(
            child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: _privacyControls())));
  }

  Widget _walletIndicators() => Observer(builder: (_) {
        final b = _account.poolBalances;
        final shielded = b.total > 0 && !b.hasTransparent;
        final error =
            !syncStatus2.connected || syncStatus2.connectionError != null;
        final synced = !error && !syncStatus2.paused && syncStatus2.isSynced;
        final progress = syncStatus2.blocksProgress;
        final status = error
            ? 'Sync error'
            : syncStatus2.paused
                ? 'Sync paused'
                : synced
                    ? 'Synced'
                    : 'Syncing${progress == null ? "" : " ${(progress * 100).toStringAsFixed(1)}%"}';
        return Row(mainAxisSize: MainAxisSize.min, children: [
          ListenableBuilder(
              listenable: _privacy,
              builder: (_, __) => IconButton(
                  tooltip: _privacy.label,
                  onPressed: _showNetworkPrivacy,
                  icon: Icon(Icons.vpn_key_rounded,
                      size: 17,
                      color: switch (_privacy.state) {
                        NetworkPrivacyState.tor => ZipherColors.cyan,
                        NetworkPrivacyState.connecting =>
                          ZipherColors.syncPending,
                        NetworkPrivacyState.error => ZipherColors.red,
                        NetworkPrivacyState.direct => ZipherColors.text40,
                      }))),
          IconButton(
              tooltip: shielded ? 'ZEC fully shielded' : 'ZEC pool details',
              onPressed: _showPools,
              icon: Icon(
                  shielded ? Icons.shield_rounded : Icons.shield_outlined,
                  size: 17,
                  color: shielded ? ZipherColors.cyan : ZipherColors.text40)),
          Tooltip(
              message: status,
              child: Semantics(
                  button: true,
                  label: status,
                  child: InkResponse(
                      onTap: () => context.push('/more/debug_log'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox(
                            height: 44,
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: error
                                          ? ZipherColors.red
                                          : syncStatus2.paused
                                              ? ZipherColors.text40
                                              : synced
                                                  ? ZipherColors.green
                                                  : ZipherColors.syncPending)),
                              if (!synced && progress != null) ...[
                                const SizedBox(width: 6),
                                Text('${(progress * 100).toStringAsFixed(1)}%',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: ZipherColors.text60)),
                              ],
                            ])),
                      )))),
          const SizedBox(width: 8),
        ]);
      });

  Widget _buildBalanceHeader() => Observer(builder: (_) {
        final b = _account.poolBalances;
        final price = _zecUsdPrice;
        final zecValue = price != null && price > 0 && !_testnet
            ? b.total / 1e8 * price
            : null;
        final total = (zecValue ?? 0) + (_portfolio?.evmTotalUsd ?? 0);
        final hasPrice = zecValue != null ||
            (_portfolio?.tokens.any((t) => t.priceAvailable && !t.stale) ??
                false);
        final expanded =
            _balanceExpanded && MediaQuery.viewInsetsOf(context).bottom == 0;
        final incomplete = (b.total > 0 && zecValue == null) ||
            (_portfolio != null &&
                (!_portfolio!.complete || !_portfolio!.fullyPriced));
        return Container(
            decoration: BoxDecoration(
                gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: .7,
                    colors: [
                  Color.alphaBlend(ZipherColors.cyan.withValues(alpha: .045),
                      ZipherColors.bg),
                  ZipherColors.bg
                ])),
            child: Column(children: [
              Semantics(
                  button: true,
                  label: (expanded
                          ? 'Collapse balance details'
                          : 'Expand balance details') +
                      (incomplete ? ', some assets unavailable' : ''),
                  child: InkWell(
                      onLongPress: _showPools,
                      onTap: () {
                        setState(() => _balanceExpanded = !_balanceExpanded);
                        if (_balanceExpanded) _refreshPortfolio();
                      },
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(28, 14, 28, 18),
                          child: Column(children: [
                            FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                    _testnet
                                        ? '${WalletConversation.formatZec(b.total)} ZEC'
                                        : hasPrice
                                            ? _dollars(total)
                                            : '—',
                                    style: TextStyle(
                                        fontSize: 38,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -1.5,
                                        color: ZipherColors.textPrimary))),
                            const SizedBox(height: 10),
                            Text(
                                '${_assetAmount(b.shielded / 1e8)} ZEC available',
                                style: const TextStyle(
                                    fontFamily: 'JetBrains Mono',
                                    fontSize: 12,
                                    color: ZipherColors.textSecondary)),
                            if (!_testnet &&
                                (!syncStatus2.isSynced ||
                                    (expanded && incomplete)))
                              Padding(
                                  padding: const EdgeInsets.only(top: 7),
                                  child: Text(
                                      !syncStatus2.isSynced
                                          ? 'Updating balance…'
                                          : 'Some assets unavailable',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: ZipherColors.text40))),
                          ])))),
              if (expanded)
                ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * .30),
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 0, 32, 12),
                        child: Column(children: [
                          _assetRow(
                              chain: 'Zcash',
                              symbol: 'ZEC',
                              amount: b.total / 1e8,
                              dollars: zecValue,
                              onTap: _showPools),
                          _portfolioDetails(),
                        ]))),
            ]));
      });

  Widget _buildHomeViews(Widget chat) => ListenableBuilder(
      listenable: _swapTracker,
      builder: (_, __) => Observer(
          builder: (_) => WalletActivityPanel(
              chat: chat,
              selectedTab: _homeTab,
              showTabs: MediaQuery.viewInsetsOf(context).bottom == 0,
              onTabChanged: (tab) {
                FocusScope.of(context).unfocus();
                AppLog.instance.event('activity', '${tab.name}_opened');
                setState(() => _homeTab = tab);
              },
              transactions: _account.txs.items.toList(),
              swaps: _swapTracker.entries,
              onTransaction: _openTransaction,
              onSwap: (deposit) =>
                  context.push('/swap/status', extra: deposit))));
}
