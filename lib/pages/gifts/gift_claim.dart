import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../coin/coins.dart';
import '../../services/app_log.dart';
import '../../services/gift_engine.dart';
import '../../services/gift_links.dart';
import '../../services/wallet_service.dart';
import '../../src/rust/api/engine_api.dart' show EngineGiftSummary;
import '../../store2.dart' show boostSyncPolling;
import '../../zipher_theme.dart';
import '../utils.dart';

/// Reads a gift link, syncs the gift's own temporary wallet, and sweeps it
/// into this wallet after the user confirms and authenticates.
class GiftClaimPage extends StatefulWidget {
  const GiftClaimPage({super.key, required this.link});
  final String link;
  @override
  State<GiftClaimPage> createState() => _GiftClaimPageState();
}

class _GiftClaimPageState extends State<GiftClaimPage> {
  EngineGiftSummary? _summary;
  GiftClaimState _state = GiftClaimState.unchecked;
  GiftBalance? _balance;
  String? _handle;
  String? _destination;
  String? _txid;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    final h = _handle;
    // Deletes the temporary wallet; the key is still in the link.
    if (h != null) GiftEngine.instance.close(h);
    super.dispose();
  }

  void _to(GiftClaimEvent e, {GiftBalance? balance}) {
    _state = nextClaimState(_state, e, balance: balance);
  }

  Future<void> _start() async {
    try {
      final summary = await GiftEngine.instance.summary(widget.link);
      if (!mounted) return;
      setState(() => _summary = summary);
      if (!summary.networkMatches) {
        setState(() => _error = summary.testnet
            ? 'This is a testnet gift. Switch to a testnet wallet to claim it.'
            : 'This gift is for mainnet. Switch to a mainnet wallet to claim it.');
        return;
      }
      _handle = await GiftEngine.instance.open(widget.link);
      _destination = await GiftEngine.instance.claimAddress();
      await _check();
    } catch (e) {
      AppLog.instance.event('gift', 'open_failed', error: e);
      if (mounted) setState(() => _error = _message(e));
    }
  }

  Future<void> _check() async {
    final h = _handle;
    if (h == null) return;
    setState(() {
      _to(GiftClaimEvent.check);
      _error = null;
    });
    try {
      final b = await GiftEngine.instance.check(h, destination: _destination);
      if (!mounted) return;
      setState(() {
        _balance = b;
        _to(GiftClaimEvent.found, balance: b);
      });
    } catch (e) {
      AppLog.instance.event('gift', 'check_failed', error: e);
      if (mounted) {
        setState(() {
          _to(GiftClaimEvent.error);
          _error = _message(e);
        });
      }
    }
  }

  Future<void> _claim() async {
    final h = _handle, b = _balance, dest = _destination;
    if (h == null || b == null || dest == null || _state != GiftClaimState.ready) return;
    final walletId = WalletService.instance.activeWalletId;
    final ok = await requireSigningAuthorization(context,
        actionSummary:
            'Claim ${GiftMath.formatZec(b.redeemable)} ZEC gift into this wallet');
    if (!mounted || !ok || WalletService.instance.activeWalletId != walletId) return;
    setState(() => _to(GiftClaimEvent.approve));
    try {
      final r = await GiftEngine.instance.sweep(h, dest);
      if (!mounted) return;
      setState(() {
        _txid = r.txid;
        _to(r.accepted ? GiftClaimEvent.accepted : GiftClaimEvent.unconfirmed);
      });
      await _markReclaimed(walletId);
      boostSyncPolling();
    } catch (e) {
      // The engine errors only before a claim transaction exists.
      AppLog.instance.event('gift', 'claim_not_sent', error: e);
      if (mounted) {
        setState(() {
          _to(GiftClaimEvent.notSent);
          _error = _message(e);
        });
      }
    }
  }

  Future<void> _resend() async {
    final h = _handle;
    if (h == null) return;
    try {
      final r = await GiftEngine.instance.resend(h);
      if (mounted) {
        setState(() =>
            _to(r.accepted ? GiftClaimEvent.accepted : GiftClaimEvent.unconfirmed));
      }
    } catch (e) {
      AppLog.instance.event('gift', 'resend_failed', error: e);
    }
  }

  /// Taking back your own gift updates its record.
  Future<void> _markReclaimed(String? walletId) async {
    final address = _summary?.fundingAddress;
    if (walletId == null || address == null) return;
    for (final g in await SentGiftStore.instance.list(walletId, isTestnet)) {
      if (g.fundingAddress == address) {
        try {
          await SentGiftStore.instance.save(walletId, g.apply(SentGiftEvent.reclaimed));
        } on IllegalGiftTransition {
          // A record that was never funded stays as it is.
        }
      }
    }
  }

  String _message(Object e) {
    final text = '$e';
    for (final known in [
      'testnet gift',
      'for mainnet',
      'not a gift link',
      'damaged',
      'newer app',
      'nothing to claim',
      'Tor',
    ]) {
      if (text.toLowerCase().contains(known.toLowerCase())) {
        return text.replaceFirst(RegExp(r'^(Exception|AnyhowException)\(?:?\s*'), '').replaceAll(')', '');
      }
    }
    return 'Couldn’t reach the Zcash network. Check your connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    final b = _balance;
    final shown = b != null && b.redeemable > 0 ? b.redeemable : s?.statedAmount?.toInt();
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Column(children: [
        ZipherWidgets.pageHeader(context, 'Claim a gift'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                ZipherColors.pagePadding, 16, ZipherColors.pagePadding, 24),
            children: [
              Center(
                child: Column(children: [
                  Icon(
                      _state == GiftClaimState.claimed
                          ? Icons.check_circle_rounded
                          : Icons.redeem_rounded,
                      size: 52,
                      color: _state == GiftClaimState.claimed
                          ? ZipherColors.green
                          : ZipherColors.warm),
                  const SizedBox(height: ZipherSpacing.md),
                  Text(shown == null ? 'ZEC gift' : '${GiftMath.formatZec(shown)} ZEC',
                      style: ZipherType.hero.copyWith(fontSize: 38)),
                  const SizedBox(height: 6),
                  Text(_headline, textAlign: TextAlign.center, style: ZipherType.subhead),
                ]),
              ),
              if (s?.message != null) ...[
                const SizedBox(height: ZipherSpacing.lg),
                ZipherWidgets.surfaceCard(
                  padding: const EdgeInsets.all(ZipherSpacing.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Message from the sender', style: ZipherType.caption),
                    const SizedBox(height: 6),
                    Text(s!.message!, style: ZipherType.body),
                  ]),
                ),
              ],
              const SizedBox(height: ZipherSpacing.lg),
              if (b != null && _state == GiftClaimState.ready)
                ZipherWidgets.card(
                  padding: const EdgeInsets.all(ZipherSpacing.md),
                  child: Column(children: [
                    _line('Gift holds', '${GiftMath.formatZec(b.spendable)} ZEC'),
                    _line('Network fee', '${GiftMath.formatZec(b.fee)} ZEC'),
                    _line('You receive', '${GiftMath.formatZec(b.redeemable)} ZEC', strong: true),
                    _line('To', 'This wallet · shielded'),
                  ]),
                ),
              if (_txid != null) ...[
                const SizedBox(height: ZipherSpacing.md),
                Text('Transaction ${_txid!.substring(0, 8)}…${_txid!.substring(_txid!.length - 6)}',
                    textAlign: TextAlign.center, style: ZipherType.caption),
              ],
              if (_error != null) ...[
                const SizedBox(height: ZipherSpacing.md),
                ZipherWidgets.errorBanner(_error!,
                    onRetry: _handle != null && _state != GiftClaimState.claiming
                        ? _check
                        : null),
              ],
              const SizedBox(height: ZipherSpacing.lg),
              const Text(
                  'Claiming moves the gift into your shielded balance. '
                  'Zipher checks the chain from when the gift was made; this can take a moment.',
                  style: ZipherType.footnote),
            ],
          ),
        ),
        ZipherWidgets.bottomActions([_action]),
      ]),
    );
  }

  String get _headline => switch (_state) {
        _ when _error != null && _summary == null => 'This link couldn’t be read.',
        GiftClaimState.unchecked || GiftClaimState.checking => 'Looking for the gift on chain…',
        GiftClaimState.ready => 'Ready to claim',
        GiftClaimState.pending =>
          'Found ${GiftMath.formatZec(_balance?.pending ?? 0)} ZEC. It needs a few more confirmations (about 15 minutes).',
        GiftClaimState.empty =>
          'Nothing to claim. It was already claimed, or it hasn’t been mined yet.',
        GiftClaimState.dust => 'This gift holds less than the network fee.',
        GiftClaimState.claiming => 'Claiming…',
        GiftClaimState.claimed => 'Claimed! It will show in your balance shortly.',
        GiftClaimState.unconfirmed =>
          'The claim was created but no server confirmed it yet.',
        GiftClaimState.failed => 'Something went wrong.',
      };

  Widget get _action => switch (_state) {
        GiftClaimState.ready => ZipherButton(
            label: 'Claim ${GiftMath.formatZec(_balance!.redeemable)} ZEC',
            onPressed: _claim),
        GiftClaimState.checking || GiftClaimState.unchecked || GiftClaimState.claiming =>
          ZipherButton(label: 'Claim', loading: _error == null, onPressed: null),
        GiftClaimState.unconfirmed =>
          ZipherButton(label: 'Send again', onPressed: _resend),
        GiftClaimState.claimed =>
          ZipherButton(label: 'Done', onPressed: () => GoRouter.of(context).pop()),
        _ => ZipherButton(
            label: 'Check again',
            kind: ZipherButtonKind.secondary,
            onPressed: _handle == null ? null : _check),
      };

  Widget _line(String label, String value, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Text(label, style: ZipherType.subhead),
          const Spacer(),
          Text(value,
              style: ZipherType.rowValue.copyWith(
                  fontSize: 15, fontWeight: strong ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );
}
