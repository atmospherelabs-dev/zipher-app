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
import '../../services/hitl_watch_service.dart';
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
import '../../services/backup_status.dart';
import 'widgets/wallet_balance_details.dart';
import 'widgets/wallet_activity_row.dart';
import 'widgets/wallet_activity_panel.dart';
import '../utils.dart';
import 'wallet_amounts.dart';
import 'wallet_conversation.dart';
import 'wallet_swap_flow.dart';
import 'wallet_transfer_progress.dart';
import 'widgets/wallet_review_card.dart';
import 'widgets/wallet_transfer_status_card.dart';
import 'widgets/z_chat_widgets.dart';

/// The home and Z entry points share one conversation. No model initialization,
/// remote language parsing is needed. Public EVM balances refresh separately.
class WalletChatPage extends StatelessWidget {
  final String? initialIntent;
  final EvmBalanceReader? balanceReader;
  final NetworkPrivacy? privacy;
  final NearIntentsService? swapService;
  const WalletChatPage(
      {super.key,
      this.initialIntent,
      this.balanceReader,
      this.privacy,
      this.swapService});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: testnetNotifier,
      builder: (_, network, __) => Observer(
          builder: (_) => _WalletChat(
                key: ValueKey('${aaSequence.seqno}:$network'),
                initialIntent: initialIntent,
                balanceReader: balanceReader,
                privacy: privacy,
                swapService: swapService,
              )));
}

class _WalletChat extends StatefulWidget {
  final String? initialIntent;
  final EvmBalanceReader? balanceReader;
  final NetworkPrivacy? privacy;
  final NearIntentsService? swapService;
  const _WalletChat(
      {super.key,
      this.initialIntent,
      this.balanceReader,
      this.privacy,
      this.swapService});
  @override
  State<_WalletChat> createState() => _WalletChatState();
}

class _WalletChatState extends State<_WalletChat> with WidgetsBindingObserver {
  final _conversation = WalletConversation(zcashContacts: _zcashContacts);

  /// Saved Zcash contacts (older entries without a chain are Zcash).
  static List<ZcashContact> _zcashContacts() => [
        for (final c in contacts.contacts)
          if ((c.chainId == null || c.chainId!.toLowerCase() == 'zec') &&
              (c.name?.trim().isNotEmpty ?? false) &&
              (c.address?.isNotEmpty ?? false))
            (name: c.name!.trim(), address: c.address!)
      ];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _latestMessageKey = GlobalKey();

  /// The open review pins its Cancel / Confirm above the composer here.
  final _reviewActions = ReviewActionHost();
  final _messages = <({String text, bool user, Widget? card, bool plain})>[];
  final _wallet = WalletService.instance;
  late final NearIntentsService _near =
      widget.swapService ?? NearIntentsService();
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
  // Missing prices are retried a few times (10 s, 20 s); dots show meanwhile.
  // After that the value reads "—" until the regular refresh finds a price.
  int _priceMisses = 0;
  Timer? _priceRetry;
  static const _maxPriceRetries = 3;
  bool get _pricePending =>
      !_testnet && (_loadingPortfolio || _priceMisses < _maxPriceRetries);
  SwapDraft? _swap;
  late final WalletSwapTracker _swapTracker;
  final _reviewPhases = <ValueNotifier<ReviewPhase>>[];
  ValueNotifier<ReviewPhase>? _openReview;
  final _transfers = <_Transfer>[];

  /// Swaps started here whose final result still gets one closing message.
  final _announce = <String, NearToken>{};
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
    // Ready for "send … to <contact>" before the first sync completes.
    unawaited(contacts.fetchContacts());
    unawaited(BackupStatus.instance.load(_walletId));
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
    _messages.add((
      text: 'What would you like to do?',
      user: false,
      card: null,
      plain: false
    ));
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
    _priceRetry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    _reviewEpoch.dispose();
    _portfolioUpdates.dispose();
    for (final phase in _reviewPhases) {
      phase.dispose();
    }
    for (final transfer in _transfers) {
      transfer.dispose();
    }
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
        _schedulePriceRetry();
      }
    }
  }

  void _schedulePriceRetry() {
    if (_testnet) return;
    if (_zecUsdPrice != null) {
      _priceMisses = 0;
      return;
    }
    if (_priceRetry?.isActive == true) return;
    setState(() => _priceMisses++);
    if (_priceMisses >= _maxPriceRetries) return;
    _priceRetry = Timer(Duration(seconds: 10 * _priceMisses), () {
      if (!mounted) return;
      marketPrice.update().catchError((Object _) {});
      _refreshPortfolio(force: true);
    });
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

  /// [plain] cards (choices, one-line facts) are shown without a box.
  void _message(String text,
      {bool user = false, Widget? card, bool plain = false}) {
    if (!_current) return;
    if (!user) AppLog.instance.event('chat', 'response', detail: text);
    setState(() =>
        _messages.add((text: text, user: user, card: card, plain: plain)));
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
    _swap = null;
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
        // Do not echo raw RPC errors, which can contain request addresses.
        final text = e.toString().toLowerCase();
        _message(text.contains('insufficient')
            ? 'There isn’t enough spendable shielded ZEC to cover this amount and its fee. ${_swap != null ? 'Enter a smaller amount to continue, or cancel.' : 'Check your balance or wait for confirmations.'}'
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
              'command=${command.name} draft=${_conversation.pending?.command.name ?? (_swap == null ? "none" : "swap")}');
      if (_choosingAddress && command == WalletCommand.unknown) {
        await _receive(text);
        return;
      }
      _choosingAddress = false;
      // Anything that is not a command answers the active swap: an amount,
      // token, network or recipient. It is never guessed to be something else.
      if (_swap != null && command == WalletCommand.unknown) {
        await _continueSwap(text.trim());
        return;
      }
      // Looking something up keeps a draft; any other command replaces it.
      if (command != WalletCommand.unknown &&
          !WalletConversation.informational.contains(command)) {
        if (command == WalletCommand.cancel &&
            _openReview?.value == ReviewPhase.open) {
          _openReview!.value = ReviewPhase.cancelled;
        }
        _swap = null;
        _reviewEpoch.value++;
      }
      // Contacts load with the wallet; a send can name one without waiting.
      final reply = _conversation.accept(text);
      if (reply.prompt != null) {
        final pending = _conversation.pending;
        final sending = pending?.command == WalletCommand.send;
        final askingAmount = sending && pending?.zatoshis == null;
        final known = sending && pending?.recipient == null
            ? _zcashContacts().take(6).toList()
            : const <ZcashContact>[];
        _message(reply.prompt!,
            plain: true,
            card: !askingAmount && known.isEmpty
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        if (askingAmount)
                          Observer(
                              builder: (_) => Text(
                                  '${_assetAmount(_account.poolBalances.shielded / 1e8)} ZEC available · fee applies',
                                  style: ZipherType.caption)),
                        if (known.isNotEmpty) ...[
                          const SizedBox(height: ZipherSpacing.smMd),
                          // Tapping a contact answers with its name.
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final c in known)
                              ZChatShortcut(
                                  icon: Icons.person_outline_rounded,
                                  secondary: true,
                                  label: c.name,
                                  onTap: () {
                                    if (!_current || _busy) return;
                                    _submit(c.name);
                                  }),
                          ]),
                        ],
                      ]));
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
            plain: true,
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
    if (_swap?.token != null) {
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
            plain: true,
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
      await _showReceiveAddress(matching.single);
      return;
    }
    _choosingAddress = true;
    _message(
        choices.isEmpty
            ? 'Your addresses are still loading. Try receive again in a moment.'
            : requested != null
                ? 'That chain’s address is unavailable in this wallet. Choose an available chain.'
                : 'Which chain would you like to receive on?',
        plain: true,
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

  Future<void> _showReceiveAddress(WalletReceiveAddress choice) async {
    if (!_current) return;
    _choosingAddress = false;
    // Zcash: hand out a new shielded-only address each time, so payers can't
    // link payments to each other. Earlier addresses keep receiving. If a new
    // one can't be made right now, the wallet's existing address still works.
    var fresh = false;
    if (choice.id == 'zec' && _wallet.isWalletOpen) {
      try {
        final address = await _wallet.nextShieldedAddress();
        if (!_current) return;
        choice = WalletReceiveAddress(choice.id, choice.label, address);
        fresh = true;
      } catch (e) {
        AppLog.instance.event('receive', 'fresh_address_failed', error: e);
        if (!_current) return;
      }
    }
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
          if (fresh)
            const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                    'A new address each time, for privacy. Earlier ones keep working.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 12, color: ZipherColors.text40))),
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
      ZipherWidgets.group([
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
          card: _activityList(records.take(10), showMemo: true), plain: true);
    }
  }

  void _clearChat() {
    if (_busy) return;
    _clearDraft();
    _input.clear();
    setState(() {
      _messages
        ..clear()
        ..add((
          text: 'What would you like to do?',
          user: false,
          card: null,
          plain: false
        ));
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

  String? _ownAddress(String blockchain) {
    final addresses = _account.chainAddresses;
    final own = switch (blockchain.toLowerCase()) {
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
    return own == null || own.isEmpty ? null : own;
  }

  /// A name for an address the user already knows, from loaded data only.
  String? _recipientNote(String address, {String? chain}) {
    if (chain != null && _ownAddress(chain) == address) return 'Your wallet';
    for (final c in contacts.contacts) {
      final name = c.name;
      if (c.address == address && name != null && name.isNotEmpty) return name;
    }
    return null;
  }

  Widget _action(String label, VoidCallback onTap,
          {IconData icon = Icons.refresh_rounded}) =>
      Align(
          alignment: Alignment.centerLeft,
          child: ZChatShortcut(icon: icon, label: label, onTap: onTap));

  /// Why signing stopped before a transaction existed. Never echoes raw
  /// engine text, which can contain addresses.
  String _notSentReason(Object error) {
    final text = error.toString().toLowerCase();
    if (error is WalletBusyException) {
      return 'The wallet was busy with another task.';
    }
    if (text.contains('insufficient')) {
      return 'There isn’t enough spendable ZEC for this amount and its fee.';
    }
    if (text.contains('network_upgrade')) {
      return 'The network rules changed since this review.';
    }
    if (text.contains('sync') || text.contains('checkpoint')) {
      return 'The wallet is still syncing.';
    }
    if (text.contains('expired') ||
        text.contains('review') ||
        text.contains('changed') ||
        text.contains('replaced')) {
      return 'The review went out of date before signing.';
    }
    return 'The transaction could not be prepared.';
  }

  void _reviewExpired(ValueNotifier<ReviewPhase> phase, VoidCallback? requote) {
    _reviewEpoch.value++;
    phase.value = ReviewPhase.expired;
    _message('That quote expired before it was confirmed. Nothing was sent.',
        plain: true,
        card: requote == null ? null : _action('Get a new quote', requote));
  }

  Future<void> _prepareSend(WalletRequest request,
      {NearQuoteResponse? quote,
      NearToken? destination,
      String? recipient,
      String? refundAddress,
      SwapDraft? draft}) async {
    if (request.memo != null && utf8.encode(request.memo!).length > 512) {
      _message(
          'The memo is too long. Use at most 512 UTF-8 bytes, then start the send again.');
      return;
    }
    if (!await _canSend()) return;
    final address = request.recipient!;
    final zatoshis = request.zatoshis!;
    final validation = await _wallet.validateAddress(address);
    if (!_current) return;
    if (!validation.isValid) {
      _message(quote == null
          ? 'That address is invalid for this wallet. Check the full address and network, then start again with send.'
          : 'The swap provider returned a deposit address this wallet cannot pay. Nothing was sent.');
      return;
    }
    final isTransparent = address.startsWith('t');
    if (quote == null &&
        isTransparent &&
        request.memo != null &&
        request.memo!.isNotEmpty) {
      _message(
          'Transparent addresses cannot receive a private memo. Use a shielded address or start again without a memo.');
      return;
    }
    setState(() => _busyLabel = quote == null
        ? 'Checking funds and the exact fee…'
        : 'Preparing the deposit and its fee…');
    var proposal =
        await _wallet.proposeSend(address, zatoshis, memo: request.memo);
    if (!_current) return;
    if (!proposal.isExact || proposal.sendAmount != zatoshis) {
      _message(
          'The wallet couldn’t prepare that exact amount. ${draft == null ? 'Start again with a smaller amount.' : 'Enter a smaller amount to continue.'}');
      return;
    }
    var revision = _wallet.proposalRevision;
    final epoch = ++_reviewEpoch.value;
    final phase = ValueNotifier(ReviewPhase.open);
    _reviewPhases.add(phase);
    _openReview = phase;
    final destinationAddress = quote == null ? address : recipient!;
    final VoidCallback? requote = draft == null
        ? null
        : () {
            if (_current && !_busy && identical(_swap, draft)) {
              _run(() => _quoteSwap(draft));
            }
          };
    void retry() {
      if (!_current || _busy) return;
      if (requote != null) {
        requote();
      } else {
        _run(() => _prepareSend(request));
      }
    }

    final data = ReviewData(
        zatoshis: proposal.sendAmount,
        fee: proposal.fee,
        recipient: destinationAddress,
        recipientNote:
            _recipientNote(destinationAddress, chain: destination?.blockchain),
        memo: request.memo,
        warning: quote == null && isTransparent
            ? 'This is a transparent address: the recipient and amount will be public.'
            : null,
        zecUsd: _testnet ? null : _zecUsdPrice,
        swap: quote == null
            ? null
            : SwapReview(
                symbol: destination!.symbol,
                chain: destination.blockchain,
                network: SwapNetworks.name(destination.blockchain),
                estimated:
                    WalletAmounts.token(quote.amountOut, destination.decimals),
                minimum: WalletAmounts.token(
                    quote.minAmountOut!, destination.decimals),
                rate: WalletAmounts.rate(
                    zatoshis: zatoshis,
                    amountOut: quote.amountOut,
                    decimals: destination.decimals,
                    symbol: destination.symbol),
                usd: quote.amountOutUsd,
                expiry: quote.expiry,
                eta: quote.estimatedTime,
                depositAddress: quote.depositAddress,
                refundAddress: refundAddress!));
    FocusScope.of(context).unfocus();
    AppLog.instance.event(quote == null ? 'send' : 'swap', 'review_shown');
    _message('',
        card: WalletReviewCard(
          actions: _reviewActions,
          epoch: _reviewEpoch,
          expectedEpoch: epoch,
          data: data,
          phase: phase,
          onRequote: requote,
          onPriorityChanged: (priority) async {
            if (_busy || !_current || _reviewEpoch.value != epoch) {
              throw StateError('Review no longer available');
            }
            setState(() {
              _busy = true;
              _busyLabel = 'Updating fee…';
            });
            try {
              if (quote != null && !_quoteValid(quote, zatoshis)) {
                _reviewExpired(phase, requote);
                throw StateError('Quote expired');
              }
              final next = await _wallet.proposeSend(address, zatoshis,
                  memo: request.memo, priority: priority);
              if (!_current ||
                  _reviewEpoch.value != epoch ||
                  !next.isExact ||
                  next.sendAmount != zatoshis) {
                throw StateError('Review changed');
              }
              proposal = next;
              revision = _wallet.proposalRevision;
              AppLog.instance.event('send', 'fee_updated',
                  detail: 'priority=$priority fee=${next.fee}');
              return next.fee;
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
          confirmLabel: quote == null ? 'Send ZEC' : 'Confirm swap',
          onCancel: () {
            phase.value = ReviewPhase.cancelled;
            _clearDraft();
            _message('Cancelled. Nothing was sent.');
          },
          onConfirm: () => _run(() async {
            if (_reviewEpoch.value != epoch || !_current) return;
            if (_wallet.proposalRevision != revision) {
              _reviewEpoch.value++;
              phase.value = ReviewPhase.failed;
              _message(
                  'Another transaction replaced this review, so nothing was sent.',
                  plain: true,
                  card: _action('Review again', retry));
              return;
            }
            if (quote != null && !_quoteValid(quote, zatoshis)) {
              _reviewExpired(phase, requote);
              return;
            }
            final fee = WalletConversation.formatZec(proposal.fee);
            final amount = WalletConversation.formatZec(proposal.sendAmount);
            final authorized = await requireSigningAuthorization(context,
                actionSummary: quote == null
                    ? 'Send $amount ZEC + $fee ZEC fee to $address'
                    : 'Swap $amount ZEC + $fee ZEC fee for ${destination!.symbol} on ${SwapNetworks.name(destination.blockchain)}');
            if (!_current) return;
            if (!authorized) {
              _reviewEpoch.value++;
              phase.value = ReviewPhase.cancelled;
              _message('Not approved, so nothing was sent.',
                  plain: true, card: _action('Review again', retry));
              return;
            }
            if (_reviewEpoch.value != epoch) {
              phase.value = ReviewPhase.failed;
              _message('The request changed while approving. Nothing was sent.',
                  plain: true, card: _action('Review again', retry));
              return;
            }
            if (quote != null && !_quoteValid(quote, zatoshis)) {
              _reviewExpired(phase, requote);
              return;
            }
            phase.value = ReviewPhase.sending;
            if (quote != null) {
              // Persist recovery information before signing. Even if the app
              // closes during broadcast, swap history can query the deposit.
              await SwapStore.save(
                  _storedSwap(quote, destination!, recipient!, zatoshis));
              if (!_current) return;
            }
            final transfer = _Transfer(
                zatoshis: zatoshis,
                token: destination,
                deposit: quote?.depositAddress,
                retry: retry);
            _transfers.add(transfer);
            setState(() => _busyLabel = 'Signing and sending…');
            _message('', card: _transferCard(transfer));
            final SendOutcome outcome;
            try {
              outcome = await _wallet.confirmSendDetailed(
                  expectedRevision: revision,
                  expectedWalletId: _walletId,
                  expectedTestnet: _testnet);
            } on SendUncertainException catch (e) {
              // Never offer a re-send: a transaction may exist.
              AppLog.instance.event('send', 'outcome_unknown', error: e);
              if (!_current) return;
              _reviewEpoch.value++;
              phase.value = ReviewPhase.approved;
              transfer.update(TransferBroadcast.unreachable, resubmits: false);
              _swap = null;
              boostSyncPolling();
              return;
            } catch (e) {
              // The engine reports an error only before a transaction exists.
              AppLog.instance
                  .event(quote == null ? 'send' : 'swap', 'not_sent', error: e);
              if (quote != null) {
                try {
                  await SwapStore.remove(quote.depositAddress);
                } catch (error) {
                  AppLog.instance
                      .event('swap', 'record_remove_failed', error: error);
                }
              }
              if (!_current) return;
              _reviewEpoch.value++;
              phase.value = ReviewPhase.failed;
              transfer.update(TransferBroadcast.notSent,
                  reason: _notSentReason(e));
              return;
            }
            AppLog.instance.event(quote == null ? 'send' : 'swap', 'submitted',
                detail:
                    'broadcast=${outcome.broadcast.name} resubmits=${outcome.resubmits}',
                error: outcome.detail);
            // The transaction exists. Keep its swap record whatever happens
            // to this screen, and never let bookkeeping read as a failure.
            final stored = quote == null
                ? null
                : await _saveSwap(
                    quote, destination!, recipient!, zatoshis, outcome);
            if (!_current) return;
            _reviewEpoch.value++;
            phase.value =
                outcome.accepted ? ReviewPhase.sent : ReviewPhase.approved;
            transfer.update(
                switch (outcome.broadcast) {
                  SendBroadcast.accepted => TransferBroadcast.accepted,
                  SendBroadcast.unreachable => TransferBroadcast.unreachable,
                  SendBroadcast.rejected => TransferBroadcast.rejected,
                },
                txid: outcome.txid,
                resubmits: outcome.resubmits);
            _swap = null;
            boostSyncPolling();
            if (stored != null) {
              _announce[stored.depositAddress] = destination!;
              _swapTracker.track(stored);
              await _swapTracker.refresh();
            }
            try {
              await _account.updateBalance();
            } catch (e) {
              AppLog.instance.event('send', 'balance_refresh_failed', error: e);
            }
          }),
        ));
  }

  Widget _transferCard(_Transfer transfer) => ListenableBuilder(
      listenable: Listenable.merge([transfer, _swapTracker]),
      builder: (context, __) => Observer(builder: (_) {
            final id = transfer.txid;
            final tx = id == null
                ? null
                : _account.txs.items
                    .where((tx) => tx.fullTxId == id)
                    .firstOrNull;
            final deposit = transfer.deposit;
            final swap = deposit == null
                ? null
                : _swapTracker.entries
                    .where((e) => e.swap.depositAddress == deposit)
                    .firstOrNull;
            final token = transfer.token;
            final progress = TransferProgress(
                zatoshis: transfer.zatoshis,
                broadcast: transfer.broadcast,
                resubmits: transfer.resubmits,
                mined: tx != null && tx.height > 0,
                expired: tx?.expiredUnmined ?? false,
                swapSymbol: token?.symbol,
                swapNetwork:
                    token == null ? null : SwapNetworks.name(token.blockchain),
                swapStatus: swap?.status?.status,
                reason: transfer.reason);
            return WalletTransferStatusCard(
                progress: progress,
                swapChain: token?.blockchain,
                transactionId: id,
                onRetry: transfer.broadcast == TransferBroadcast.notSent
                    ? transfer.retry
                    : null,
                retryLabel: token == null ? 'Review again' : 'Get a new quote',
                onDetails: id == null
                    ? null
                    : deposit != null
                        ? () => context.push('/swap/status', extra: deposit)
                        : tx == null
                            ? null
                            : () => _openTransaction(id),
                detailsLabel:
                    deposit != null ? 'Swap details' : 'Transaction details',
                onCopyId: id == null
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: id));
                        if (_current) _message('Transaction ID copied.');
                      });
          }));

  // ---- Swap -----------------------------------------------------------------

  Future<void> _beginSwap(WalletRequest request) async {
    if (_testnet) {
      _message(
          'Cross-chain swaps are available on mainnet. Your testnet ZEC stays on testnet.');
      return;
    }
    if (!await _canSend()) return;
    final List<NearToken> tokens;
    try {
      tokens = await _near.getTokens();
    } catch (e) {
      AppLog.instance.event('swap', 'tokens_unavailable', error: e);
      if (_current) {
        _message(
            'Swap options couldn’t be loaded. Check your connection and try again.',
            plain: true,
            card: _action('Try again', () {
              if (_current && !_busy) _run(() => _beginSwap(request));
            }));
      }
      return;
    }
    if (!_current) return;
    final draft = SwapDraft(SwapCatalog(tokens));
    _swap = draft;
    final seeded = draft.seed(
        zatoshis: request.zatoshis,
        token: request.token,
        network: request.network);
    await _advanceSwap(
        draft,
        seeded.problem == null && request.unreadAmount
            ? const SwapReply(
                problem:
                    'Amounts are in ZEC, with up to 8 decimal places. For example: 0.5')
            : seeded);
  }

  Future<void> _continueSwap(String input) async {
    final draft = _swap!;
    final reviewing = draft.step == SwapStep.ready;
    final reply = draft.accept(input);
    if (reviewing) {
      if (reply.change == SwapChange.none) {
        _message(
            '${reply.problem ?? ''} Confirm the review above, or type a new amount, token, network or address.'
                .trim());
        return;
      }
      // The reviewed quote no longer matches what is being asked for.
      _reviewEpoch.value++;
    }
    await _advanceSwap(draft, reply);
  }

  Widget _swapChips(List<Widget> chips, {String? more}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, children: chips),
        if (more != null)
          Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(more,
                  style: const TextStyle(
                      fontSize: 12, height: 1.4, color: ZipherColors.text40))),
      ]);

  Widget _swapChip(SwapDraft draft, String label, String value,
          {Widget? leading, IconData icon = Icons.circle_outlined}) =>
      ZChatShortcut(
          leading: leading,
          icon: icon,
          label: label,
          onTap: () {
            if (_current && !_busy && identical(_swap, draft)) _submit(value);
          });

  /// Ask for whatever is still missing; quote once nothing is.
  Future<void> _advanceSwap(SwapDraft draft, SwapReply reply) async {
    // A correction is acknowledged so the same question is not just repeated.
    final problem = reply.problem ??
        (!reply.replaced
            ? null
            : switch (reply.change) {
                SwapChange.amount =>
                  'Amount changed to ${WalletConversation.formatZec(draft.zatoshis!)} ZEC.',
                SwapChange.token => 'Token changed to ${draft.symbol}.',
                SwapChange.network =>
                  'Network changed to ${draft.networkName}.',
                SwapChange.recipient || SwapChange.none => null,
              });
    String say(String prompt) => problem == null ? prompt : '$problem $prompt';
    switch (draft.step) {
      case SwapStep.amount:
        _message(say('How much ZEC would you like to swap?'),
            plain: true,
            card: Observer(
                builder: (_) => Text(
                    '${_assetAmount(_account.poolBalances.shielded / 1e8)} ZEC available · fee applies',
                    style: const TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: 12,
                        color: ZipherColors.textSecondary))));
      case SwapStep.token:
        final offered = reply.suggestions.isEmpty
            ? draft.catalog.popularSymbols
            : reply.suggestions;
        _message(
            reply.problem == null
                ? say('Which token would you like to receive?')
                : reply.suggestions.isEmpty
                    ? '$problem Which token would you like to receive?'
                    : '$problem Did you mean one of these?',
            plain: true,
            card: _swapChips([
              for (final symbol in offered)
                _swapChip(draft, symbol, symbol,
                    leading: CurrencyIcon(symbol: symbol, size: 18)),
            ], more: 'Or type another token, for example DAI or DOGE.'));
      case SwapStep.network:
        final shown = draft.networks.take(8).toList();
        final rest = draft.networks.skip(8).toList();
        _message(say('Which network should receive your ${draft.symbol}?'),
            plain: true,
            card: _swapChips([
              for (final token in shown)
                _swapChip(draft, SwapNetworks.name(token.blockchain),
                    SwapNetworks.name(token.blockchain),
                    leading: _ownAddress(token.blockchain) == null
                        ? WalletChainLogo(token.blockchain, size: 18)
                        : Stack(clipBehavior: Clip.none, children: [
                            WalletChainLogo(token.blockchain, size: 18),
                            const Positioned(
                                right: -3,
                                bottom: -3,
                                child: Icon(Icons.account_circle_rounded,
                                    size: 10, color: ZipherColors.cyan)),
                          ])),
            ],
                more: rest.isEmpty
                    ? null
                    : 'Also available: ${rest.map((t) => SwapNetworks.name(t.blockchain)).join(', ')}. Type its name.'));
      case SwapStep.recipient:
        final token = draft.token!;
        final network = SwapNetworks.name(token.blockchain);
        final own = _ownAddress(token.blockchain);
        final known = [
          for (final c in contacts.contacts)
            if (c.chainId?.toLowerCase() == token.blockchain.toLowerCase() &&
                (c.address?.isNotEmpty ?? false) &&
                (c.name?.isNotEmpty ?? false))
              c
        ].take(3).toList();
        _message(
            say('Where should the ${token.symbol} go? Paste a $network address.'),
            plain: true,
            card: own == null && known.isEmpty
                ? null
                : _swapChips([
                    if (own != null)
                      _swapChip(draft, 'My $network address', own,
                          icon: Icons.account_circle_rounded),
                    for (final c in known)
                      _swapChip(draft, c.name!, c.address!,
                          icon: Icons.person_outline_rounded),
                  ]));
      case SwapStep.ready:
        await _quoteSwap(draft);
    }
  }

  Future<void> _quoteSwap(SwapDraft draft) async {
    final zatoshis = draft.zatoshis!;
    final destination = draft.token!;
    final recipient = draft.recipient!;
    setState(() => _busyLabel = 'Getting a quote…');
    void unavailable(String text) => _message(text,
        plain: true,
        card: _action('Try again', () {
          if (_current && !_busy && identical(_swap, draft)) {
            _run(() => _quoteSwap(draft));
          }
        }));
    final NearQuoteResponse quote;
    final String refundAddress;
    try {
      final zec = _near.findZecToken(await _near.getTokens());
      if (!_current || !identical(_swap, draft)) return;
      if (zec == null || zec.decimals != 8) throw StateError('ZEC unavailable');
      final refundAddresses = await _wallet.getTransparentAddresses();
      if (!_current || !identical(_swap, draft)) return;
      if (refundAddresses.isEmpty) {
        unavailable(
            'A Zcash refund address isn’t available yet. Try again once the wallet has loaded.');
        return;
      }
      refundAddress = refundAddresses.first;
      quote = await _near.getQuote(
          dry: false,
          originAsset: zec.assetId,
          destinationAsset: destination.assetId,
          amount: BigInt.from(zatoshis),
          refundTo: refundAddress,
          recipient: recipient);
    } on NearIntentsException catch (e) {
      // Provider text is logged in sanitised form and never shown.
      AppLog.instance.event('swap', 'quote_refused', error: e);
      if (!_current || !identical(_swap, draft)) return;
      final minimum = e.minimumZatoshis;
      if (minimum != null) {
        draft.zatoshis = null;
        await _advanceSwap(
            draft,
            SwapReply(
                problem:
                    'This route needs at least ${WalletConversation.formatZec(minimum)} ZEC.'));
      } else if (e.invalidRecipient) {
        draft.recipient = null;
        await _advanceSwap(
            draft,
            SwapReply(
                problem:
                    'The swap provider didn’t accept that address for ${SwapNetworks.name(destination.blockchain)}.'));
      } else {
        unavailable('A quote for ${draft.summary} isn’t available right now.');
      }
      return;
    } catch (e) {
      AppLog.instance.event('swap', 'quote_failed', error: e);
      if (!_current || !identical(_swap, draft)) return;
      unavailable(
          'The quote request didn’t finish. Check your connection and try again.');
      return;
    }
    if (!_current || !identical(_swap, draft)) return;
    if (!_quoteValid(quote, zatoshis)) {
      unavailable(
          'The provider returned an incomplete or already expired quote.');
      return;
    }
    await _prepareSend(
        WalletRequest(WalletCommand.send,
            recipient: quote.depositAddress, zatoshis: zatoshis),
        quote: quote,
        destination: destination,
        recipient: recipient,
        refundAddress: refundAddress,
        draft: draft);
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

  /// Storage and the provider hint only: safe after this screen is gone.
  Future<StoredSwap> _saveSwap(NearQuoteResponse quote, NearToken token,
      String recipient, int zatoshis, SendOutcome outcome) async {
    final stored =
        _storedSwap(quote, token, recipient, zatoshis, txid: outcome.txid);
    try {
      await SwapStore.save(stored);
    } catch (e) {
      AppLog.instance.event('swap', 'record_save_failed', error: e);
    }
    if (outcome.accepted) {
      // Only a hint: the provider also detects the deposit on its own.
      try {
        await _near.submitDeposit(
            txHash: outcome.txid, depositAddress: quote.depositAddress);
      } catch (e) {
        AppLog.instance.event('swap', 'deposit_hint_failed', error: e);
      }
    }
    return stored;
  }

  /// One closing line per swap; progress in between lives in its status card.
  void _onSwapUpdate() {
    if (!_current || _announce.isEmpty) return;
    for (final entry in _swapTracker.entries) {
      final status = entry.status;
      final token = _announce[entry.swap.depositAddress];
      if (token == null || status == null || !status.isTerminal) continue;
      _announce.remove(entry.swap.depositAddress);
      final network = SwapNetworks.name(token.blockchain);
      _message(status.isSuccess
          ? 'Swap complete. Your ${token.symbol} was delivered on $network.'
          : status.isRefunded
              ? 'The swap was refunded. The ZEC returns to your balance as it confirms.'
              : 'The swap did not complete. Open Activity to check the deposit and refund.');
      boostSyncPolling();
    }
  }

  /// What is being prepared, for the bar above the composer.
  ({IconData icon, String label})? get _draft {
    final swap = _swap;
    if (swap != null) {
      return (
        icon: Icons.swap_horiz_rounded,
        label: swap.summary.isEmpty ? 'Swap ZEC' : 'Swap ${swap.summary}'
      );
    }
    final send = _conversation.pending;
    if (send != null) {
      return (
        icon: Icons.arrow_upward_rounded,
        label: [
          'Send',
          if (send.zatoshis != null)
            '${WalletConversation.formatZec(send.zatoshis!)} ZEC',
          if (send.recipient != null)
            'to ${WalletAmounts.shortAddress(send.recipient!)}',
        ].join(' ')
      );
    }
    return switch (_managementStep) {
      null => null,
      ChatManagementStep.rename => (
          icon: Icons.edit_outlined,
          label: 'Rename account'
        ),
      ChatManagementStep.review => (
          icon: Icons.fact_check_outlined,
          label: 'Waiting for your confirmation'
        ),
      _ => (icon: Icons.person_add_alt_rounded, label: 'New contact'),
    };
  }

  // Keep the existing Z page's quiet header, expandable balance and chat
  // layout. The shared presentation widgets also render the original page.
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          backgroundColor: ZipherColors.bg,
          body: Stack(children: [
            // The glow sits behind the header and balance, unclipped, and
            // fades out before the tabs so nothing cuts it off.
            Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 380 + MediaQuery.paddingOf(context).top,
                child: const IgnorePointer(
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: RadialGradient(
                                center: Alignment(0, -.45),
                                // Relative to the width; reaches zero well
                                // before the bottom of the box.
                                radius: .72,
                                colors: [
                      Color(0x1A00D4FF),
                      Color(0x0800D4FF),
                      Color(0x0000D4FF),
                    ],
                                stops: [
                      0,
                      .5,
                      1
                    ]))))),
            Column(children: [
              SafeArea(bottom: false, child: _header()),
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
                              : msg.plain
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: msg.card)
                                  : ZChatCard(child: msg.card!),
                    );
                  },
                )),
                ReviewActionBar(host: _reviewActions),
                ListenableBuilder(
                    listenable: _reviewActions,
                    builder: (_, __) => ZChatComposer(
                          prefix: _draft == null || _reviewActions.active
                              ? null
                              : ZChatDraftBar(
                                  icon: _draft!.icon,
                                  label: _draft!.label,
                                  onCancel:
                                      _busy ? null : () => _submit('cancel')),
                          controller: _input,
                          busy: _busy,
                          onSubmit: _submit,
                          onScan: () => _submit('scan'),
                          hint: _managementStep != null
                              ? switch (_managementStep!) {
                                  ChatManagementStep.contactChain =>
                                    'Choose a chain',
                                  ChatManagementStep.contactName =>
                                    'Contact name',
                                  ChatManagementStep.contactAddress =>
                                    'Paste the wallet address',
                                  ChatManagementStep.rename =>
                                    'New account name',
                                  ChatManagementStep.review =>
                                    'Review above, or cancel',
                                }
                              : _swap != null
                                  ? switch (_swap!.step) {
                                      SwapStep.amount => 'Amount in ZEC',
                                      SwapStep.token =>
                                        'Token, for example USDC',
                                      SwapStep.network => 'Choose a network',
                                      SwapStep.recipient =>
                                        'Paste the recipient address',
                                      SwapStep.ready =>
                                        'Change the amount, token or address',
                                    }
                                  : _choosingAddress
                                      ? 'Choose a chain'
                                      : _conversation.hint,
                        )),
              ]))),
            ]),
          ]),
        ),
      );

  /// Account switcher on the left, one status pill on the right.
  Widget _header() => Padding(
      padding: const EdgeInsets.fromLTRB(
          ZipherSpacing.sm, ZipherSpacing.xs, ZipherSpacing.md, 0),
      child: SizedBox(
          height: 48,
          child: Row(children: [
            Expanded(
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                        button: true,
                        label: 'Switch account, $_displayName',
                        child: InkWell(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.full),
                            onTap: () {
                              FocusScope.of(context).unfocus();
                              AppLog.instance
                                  .event('wallet', 'account_switcher_opened');
                              showWalletAccountSwitcher(context);
                            },
                            child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: ZipherSpacing.sm, vertical: 6),
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                          width: 30,
                                          height: 30,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                              color: ZipherColors.cyan
                                                  .withValues(alpha: .14),
                                              shape: BoxShape.circle),
                                          child: Text(
                                              _displayName.isEmpty
                                                  ? '?'
                                                  : _displayName
                                                      .characters.first
                                                      .toUpperCase(),
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w700,
                                                  color: ZipherColors.cyan))),
                                      const SizedBox(width: 10),
                                      Flexible(
                                          child: Text(_displayName,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color: ZipherColors.text90,
                                                  fontSize: 16,
                                                  fontWeight:
                                                      FontWeight.w600))),
                                      const SizedBox(width: 2),
                                      const Icon(
                                          Icons.keyboard_arrow_down_rounded,
                                          size: 20,
                                          color: ZipherColors.text40),
                                    ])))))),
            const SizedBox(width: ZipherSpacing.sm),
            if (_testnet)
              Container(
                  margin: const EdgeInsets.only(right: ZipherSpacing.sm),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: ZipherColors.orange.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(ZipherRadius.full)),
                  child: const Text('Testnet',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ZipherColors.orange))),
            _activityButton(),
            const SizedBox(width: ZipherSpacing.sm),
            _walletIndicators(),
          ])));

  /// Opens Activity in place of the conversation; the badge counts items
  /// still in progress. Tapping again returns to the conversation.
  Widget _activityButton() => ListenableBuilder(
      listenable: _swapTracker,
      builder: (_, __) => Observer(builder: (_) {
            final open = _homeTab == WalletHomeTab.activity;
            final pending = WalletActivityPanel.pendingCount(
                _account.txs.items.toList(), _swapTracker.entries);
            void toggle() {
              FocusScope.of(context).unfocus();
              final next = open ? WalletHomeTab.chat : WalletHomeTab.activity;
              AppLog.instance.event('activity', '${next.name}_opened');
              setState(() => _homeTab = next);
            }

            return Tooltip(
                message: 'Activity',
                child: Semantics(
                    button: true,
                    selected: open,
                    label: pending > 0
                        ? 'Activity, $pending in progress'
                        : 'Activity',
                    excludeSemantics: true,
                    child: GestureDetector(
                        onTap: toggle,
                        child: SizedBox(
                            width: 40,
                            height: 40,
                            child: Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.center,
                                children: [
                                  AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 180),
                                      width: 36,
                                      height: 36,
                                      decoration: ZipherGlass.decoration(
                                          shape: BoxShape.circle,
                                          tint:
                                              open ? ZipherColors.cyan : null),
                                      child: Icon(Icons.schedule_rounded,
                                          size: 18,
                                          color: open
                                              ? ZipherColors.cyan
                                              : ZipherColors.text60)),
                                  if (pending > 0)
                                    Positioned(
                                        top: -1,
                                        right: -2,
                                        child: Container(
                                            constraints: const BoxConstraints(
                                                minWidth: 17),
                                            height: 17,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4),
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                                color: ZipherColors.cyan,
                                                borderRadius:
                                                    BorderRadius.circular(9),
                                                border: Border.all(
                                                    color: ZipherColors.bg,
                                                    width: 2)),
                                            child: Text(
                                                pending > 99
                                                    ? '99+'
                                                    : '$pending',
                                                style: const TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w700,
                                                    color: ZipherColors
                                                        .textOnBrand)))),
                                ])))));
          }));

  /// Shown until the recovery phrase is backed up. Never reveals the phrase
  /// itself: "Back up now" asks for Face ID first; "Later" hides it a day.
  Widget _backupReminder() => ValueListenableBuilder<bool>(
      valueListenable: BackupStatus.instance.needsReminder,
      builder: (context, needed, _) => !needed || _testnet
          ? const SizedBox.shrink()
          : Container(
              margin: const EdgeInsets.only(bottom: ZipherSpacing.lg),
              padding: const EdgeInsets.all(ZipherSpacing.md),
              decoration: BoxDecoration(
                  color: ZipherColors.warm.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(ZipherRadius.card),
                  border: Border.all(
                      color: ZipherColors.warm.withValues(alpha: .30),
                      width: .5)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.key_rounded,
                              size: 20, color: ZipherColors.warm),
                          const SizedBox(width: ZipherSpacing.smMd),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: const [
                                Text('Back up your wallet',
                                    style: ZipherType.rowTitle),
                                SizedBox(height: 2),
                                Text(
                                    'Write down your recovery phrase somewhere private. It’s the only way back in if you lose this phone.',
                                    style: ZipherType.footnote),
                              ])),
                        ]),
                    const SizedBox(height: ZipherSpacing.smMd),
                    Row(children: [
                      Expanded(
                          child: ZipherButton(
                              label: 'Later',
                              kind: ZipherButtonKind.secondary,
                              size: ZipherButtonSize.small,
                              onPressed: () {
                                AppLog.instance
                                    .event('backup', 'reminder_snoozed');
                                BackupStatus.instance.remindLater(_walletId);
                              })),
                      const SizedBox(width: ZipherSpacing.sm),
                      Expanded(
                          child: ZipherButton(
                              label: 'Back up now',
                              size: ZipherButtonSize.small,
                              onPressed: _openBackup)),
                    ]),
                  ])));

  /// Blocks left before a sync counts as a long first sync worth a card.
  static const _longSyncBlocks = 20000;

  /// "Finding your funds": shown only during a long sync (restore or first
  /// open), so routine catch-ups stay quiet in the header pill.
  Widget _firstSyncCard() => Observer(builder: (_) {
        final total = syncStatus2.blocksTotal;
        final left = total - syncStatus2.blocksScanned;
        if (!syncStatus2.syncing || total == 0 || left < _longSyncBlocks) {
          return const SizedBox.shrink();
        }
        final progress = syncStatus2.blocksProgress ?? 0;
        final eta = syncStatus2.eta.remainingDuration;
        final found = _account.poolBalances.total;
        final timeLeft = eta == null
            ? 'Working out the time left'
            : eta.inMinutes < 1
                ? 'Less than a minute left'
                : eta.inMinutes < 90
                    ? 'About ${eta.inMinutes} min left'
                    : 'About ${(eta.inMinutes / 60).round()} h left';
        return Container(
            margin: const EdgeInsets.only(bottom: ZipherSpacing.lg),
            padding: const EdgeInsets.all(ZipherSpacing.md),
            decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(ZipherRadius.card),
                border:
                    Border.all(color: ZipherColors.borderSubtle, width: .5)),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: ZipherSpacing.smMd),
                    const Expanded(
                        child: Text('Finding your funds',
                            style: ZipherType.rowTitle)),
                    Text('${(progress * 100).round()}%',
                        style: ZipherType.rowValue
                            .copyWith(color: ZipherColors.text60)),
                  ]),
                  const SizedBox(height: ZipherSpacing.smMd),
                  ClipRRect(
                      borderRadius: BorderRadius.circular(ZipherRadius.full),
                      child: LinearProgressIndicator(
                          value: progress, minHeight: 4)),
                  const SizedBox(height: ZipherSpacing.sm),
                  Text(
                      [
                        timeLeft,
                        if (found > 0)
                          'found ${_assetAmount(found / 1e8)} ZEC so far',
                      ].join(' · '),
                      style: ZipherType.footnote),
                  const SizedBox(height: 2),
                  const Text(
                      'You can keep using Zipher. Keeping it open finishes faster.',
                      style: ZipherType.footnote),
                ]));
      });

  Future<void> _openBackup() async {
    FocusScope.of(context).unfocus();
    AppLog.instance.event('backup', 'reminder_opened');
    final ok = await authenticate(context, 'Show your recovery phrase');
    if (!ok || !mounted) return;
    await context.push('/more/backup');
    if (mounted) await BackupStatus.instance.load(_walletId);
  }

  Widget _buildSuggestionChips() => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _firstSyncCard(),
        _backupReminder(),
        const Text('What would you like to do?',
            style: TextStyle(
                fontSize: 15,
                color: ZipherColors.textPrimary,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 14),
        // One row of identical chips, like suggested replies. The main
        // actions get a cyan icon; the rest stay neutral.
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (icon, label, main) in [
            (Icons.arrow_upward_rounded, 'Send', true),
            (Icons.qr_code_rounded, 'Receive', true),
            (Icons.swap_horiz, 'Swap', true),
            (Icons.account_balance_wallet_outlined, 'Balance', false),
            (Icons.people_outline_rounded, 'Contacts', false),
            (Icons.help_outline, 'Help', false),
          ])
            ZChatShortcut(
                icon: icon,
                label: label,
                secondary: !main,
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
                  if (!stale && dollars == null && _pricePending)
                    const SizedBox(
                        height: 20,
                        child: Center(
                            child: ZipherLoadingDots(
                                dotSize: 5, semanticLabel: 'Loading price')))
                  else
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
                    ZipherButton(
                        label: _privacy.state == NetworkPrivacyState.error
                            ? 'Retry Tor'
                            : 'Enable Tor',
                        icon: Icons.vpn_key_rounded,
                        kind: ZipherButtonKind.tinted,
                        size: ZipherButtonSize.small,
                        onPressed:
                            _privacy.busy ? null : () => _submit('enable Tor')),
                  if (_privacy.state != NetworkPrivacyState.direct)
                    ZipherButton(
                        label: 'Turn Tor off',
                        kind: ZipherButtonKind.secondary,
                        size: ZipherButtonSize.small,
                        onPressed: _privacy.busy
                            ? null
                            : () => _submit('disable Tor')),
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

  /// Sync state in words, shared by the pill and the status sheet.
  ({String text, String short, Color color, bool synced}) _syncState() {
    final error = !syncStatus2.connected || syncStatus2.connectionError != null;
    final synced = !error && !syncStatus2.paused && syncStatus2.isSynced;
    final progress = syncStatus2.blocksProgress;
    final percent =
        progress == null ? null : '${(progress * 100).toStringAsFixed(1)}%';
    if (error) {
      return (
        text: 'Sync error',
        short: 'Offline',
        color: ZipherColors.negative,
        synced: false
      );
    }
    if (syncStatus2.paused) {
      return (
        text: 'Sync paused',
        short: 'Paused',
        color: ZipherColors.text40,
        synced: false
      );
    }
    if (synced) {
      return (
        text: 'Synced',
        short: 'Synced',
        color: ZipherColors.positive,
        synced: true
      );
    }
    return (
      text: 'Syncing${percent == null ? '' : ' $percent'}',
      short: percent ?? 'Syncing',
      color: ZipherColors.pending,
      synced: false
    );
  }

  /// One pill for the wallet's health: a sync dot and word, plus a lock when
  /// Zcash traffic goes over Tor. Everything else lives in the status sheet.
  Widget _walletIndicators() => Observer(builder: (_) {
        final sync = _syncState();
        return ListenableBuilder(
            listenable: _privacy,
            builder: (_, __) {
              final tor = _privacy.state == NetworkPrivacyState.tor;
              final torProblem = _privacy.state == NetworkPrivacyState.error;
              return Tooltip(
                  message: sync.text,
                  child: Semantics(
                      button: true,
                      label: '${sync.text}, ${_privacy.label}. Wallet status',
                      excludeSemantics: true,
                      child: ZipherGlass.blur(
                          child: Material(
                              color: ZipherGlass.fillTop,
                              shape: const StadiumBorder(
                                  side: BorderSide(
                                      color: ZipherGlass.edge, width: .5)),
                              child: InkWell(
                                  customBorder: const StadiumBorder(),
                                  onTap: _showStatus,
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 7),
                                      child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ZipherWidgets.statusDot(sync.color,
                                                size: 7),
                                            const SizedBox(width: 7),
                                            Text(sync.short,
                                                style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: ZipherColors.text60,
                                                    fontFeatures: [
                                                      FontFeature
                                                          .tabularFigures()
                                                    ])),
                                            if (tor || torProblem) ...[
                                              const SizedBox(width: 7),
                                              Icon(Icons.lock_rounded,
                                                  size: 13,
                                                  color: torProblem
                                                      ? ZipherColors.negative
                                                      : ZipherColors.cyan),
                                            ],
                                          ])))))));
            });
      });

  /// Wallet status: sync, network route, shielding and the paired agent,
  /// each with a plain explanation and a way to act on it.
  void _showStatus() {
    FocusScope.of(context).unfocus();
    AppLog.instance.event('wallet', 'status_opened');
    showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: ZipherColors.surface,
        builder: (sheet) => SafeArea(
            child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                    ZipherSpacing.md, 0, ZipherSpacing.md, ZipherSpacing.md),
                child: Observer(builder: (_) {
                  final sync = _syncState();
                  final b = _account.poolBalances;
                  final shielded = b.total > 0 && !b.hasTransparent;
                  void go(VoidCallback action) {
                    Navigator.of(sheet).pop();
                    action();
                  }

                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                            padding: EdgeInsets.fromLTRB(
                                ZipherSpacing.xs, 0, 0, ZipherSpacing.md),
                            child:
                                Text('Wallet status', style: ZipherType.title)),
                        ListenableBuilder(
                            listenable: _privacy,
                            builder: (_, __) => ZipherWidgets.group([
                                  ZipherWidgets.row(
                                      icon: Icons.sync_rounded,
                                      iconColor: sync.color,
                                      title: sync.text,
                                      subtitle: sync.synced
                                          ? 'Up to date with the Zcash network'
                                          : 'Balance updates as blocks are scanned',
                                      onTap: () => go(() =>
                                          context.push('/more/debug_log'))),
                                  ZipherWidgets.row(
                                      icon: Icons.lock_rounded,
                                      iconColor: switch (_privacy.state) {
                                        NetworkPrivacyState.tor =>
                                          ZipherColors.cyan,
                                        NetworkPrivacyState.connecting =>
                                          ZipherColors.pending,
                                        NetworkPrivacyState.error =>
                                          ZipherColors.negative,
                                        NetworkPrivacyState.direct =>
                                          ZipherColors.text40,
                                      },
                                      title: _privacy.label,
                                      subtitle: _privacy.state ==
                                              NetworkPrivacyState.tor
                                          ? 'Sync and broadcasts hide your IP'
                                          : 'Your IP is visible to the server',
                                      onTap: () => go(_showNetworkPrivacy)),
                                  ZipherWidgets.row(
                                      icon: shielded
                                          ? Icons.shield_rounded
                                          : Icons.shield_outlined,
                                      iconColor: shielded
                                          ? ZipherColors.cyan
                                          : ZipherColors.text40,
                                      title: shielded
                                          ? 'ZEC fully shielded'
                                          : b.hasTransparent
                                              ? 'Some ZEC is transparent'
                                              : 'ZEC pool details',
                                      subtitle: 'Where your ZEC is',
                                      onTap: () => go(_showPools)),
                                  ValueListenableBuilder<bool>(
                                      valueListenable:
                                          HitlWatchService.instance.paired,
                                      builder: (_, paired, __) => ZipherWidgets.row(
                                          icon: Icons.smart_toy_rounded,
                                          iconColor: paired
                                              ? ZipherColors.cyan
                                              : ZipherColors.text40,
                                          title: paired
                                              ? HitlWatchService
                                                      .instance.agentName ??
                                                  'Agent paired'
                                              : 'No agent paired',
                                          subtitle: paired
                                              ? 'Asks you before larger sends'
                                              : 'Let an agent ask before it pays',
                                          onTap: () => go(() =>
                                              context.push('/hitl/agent')))),
                                ])),
                      ]);
                }))));
  }

  Widget _buildBalanceHeader() => Observer(builder: (_) {
        final b = _account.poolBalances;
        final price = _zecUsdPrice;
        final zecValue = price != null && price > 0 && !_testnet
            ? b.total / 1e8 * price
            : null;
        final total = (zecValue ?? 0) + (_portfolio?.evmTotalUsd ?? 0);
        // Never show a dollar total that silently counts ZEC as \$0: with a
        // ZEC balance but no ZEC price, the total is unknown.
        final hasPrice = _testnet
            ? false
            : b.total > 0
                ? zecValue != null
                : () {
                    // No ZEC: a total exists if any held asset is priced, or
                    // if nothing is held at all (an empty wallet is \$0.00).
                    final held = (_portfolio?.tokens ?? const [])
                        .where((t) => t.balance > 0);
                    return held.isEmpty ||
                        held.any((t) => t.priceAvailable && !t.stale);
                  }();
        final expanded =
            _balanceExpanded && MediaQuery.viewInsetsOf(context).bottom == 0;
        final incomplete = (b.total > 0 && zecValue == null) ||
            (_portfolio != null &&
                (!_portfolio!.complete || !_portfolio!.fullyPriced));
        return Column(children: [
          Semantics(
              button: true,
              label: (expanded
                      ? 'Collapse balance details'
                      : 'Expand balance details') +
                  (incomplete ? ', some assets unavailable' : ''),
              // No Material ink: a grey rectangle flashed over the hero.
              child: InkWell(
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  onLongPress: _showPools,
                  onTap: () {
                    setState(() => _balanceExpanded = !_balanceExpanded);
                    if (_balanceExpanded) _refreshPortfolio();
                  },
                  child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 22, 28, 22),
                      child: Column(children: [
                        if (!_testnet && !hasPrice && _pricePending)
                          // Same height as the hero figure so nothing jumps.
                          SizedBox(
                              height: (ZipherType.hero.fontSize ?? 48) *
                                  (ZipherType.hero.height ?? 1.2),
                              child: const Center(
                                  child: ZipherLoadingDots(
                                      dotSize: 10,
                                      semanticLabel: 'Loading balance value')))
                        else
                          FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                  _testnet
                                      ? '${WalletConversation.formatZec(b.total)} ZEC'
                                      : hasPrice
                                          ? _dollars(total)
                                          : '—',
                                  style: ZipherType.hero)),
                        const SizedBox(height: 8),
                        Text('${_assetAmount(b.shielded / 1e8)} ZEC available',
                            style: ZipherType.subhead.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                        // Change and incoming funds are not lost, only not
                        // spendable until they confirm.
                        if (b.unconfirmed > 0)
                          Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(
                                  '${_assetAmount(b.unconfirmed / 1e8)} ZEC pending confirmation',
                                  style: ZipherType.caption)),
                        // Sync progress lives in the header's status
                        // pill; only say when assets are missing.
                        if (!_testnet && expanded && incomplete)
                          Padding(
                              padding: const EdgeInsets.only(top: 7),
                              child: Text('Some assets unavailable',
                                  style: ZipherType.caption)),
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
        ]);
      });

  Widget _buildHomeViews(Widget chat) => ListenableBuilder(
      listenable: _swapTracker,
      builder: (_, __) => Observer(
          builder: (_) => WalletActivityPanel(
              chat: chat,
              selectedTab: _homeTab,
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

/// One confirmed send or swap deposit shown in the chat. Only the confirm flow
/// writes to it; the status card derives the rest from live wallet data.
class _Transfer extends ChangeNotifier {
  _Transfer(
      {required this.zatoshis, this.token, this.deposit, required this.retry});
  final int zatoshis;
  final NearToken? token;
  final String? deposit;
  final VoidCallback retry;
  TransferBroadcast broadcast = TransferBroadcast.signing;
  String? txid;
  bool resubmits = true;
  String? reason;

  void update(TransferBroadcast next,
      {String? txid, bool resubmits = true, String? reason}) {
    broadcast = next;
    this.txid = txid;
    this.resubmits = resubmits;
    this.reason = reason;
    notifyListeners();
  }
}
