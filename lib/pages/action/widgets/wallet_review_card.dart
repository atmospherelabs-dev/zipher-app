import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';

import '../../../services/near_intents.dart' show CurrencyIcon;
import '../../../zipher_theme.dart';
import '../wallet_amounts.dart';
import '../wallet_conversation.dart';

/// The provider's quote for the receiving side of a swap, shown as quoted.
class SwapReview {
  const SwapReview({
    required this.symbol,
    required this.chain,
    required this.network,
    required this.estimated,
    required this.minimum,
    required this.depositAddress,
    required this.refundAddress,
    this.rate,
    this.usd,
    this.expiry,
    this.eta,
    this.slippage = '1%',
    this.appFee = '0.5%',
  });

  final String symbol;

  /// Provider network id, used for the chain badge.
  final String chain;
  final String network;
  final String estimated;
  final String minimum;
  final String? rate;
  final double? usd;
  final DateTime? expiry;
  final Duration? eta;
  final String depositAddress;
  final String refundAddress;
  final String slippage;
  final String appFee;
}

/// Exactly what the user is asked to approve. ZEC amounts are zatoshis.
class ReviewData {
  const ReviewData({
    required this.zatoshis,
    required this.fee,
    required this.recipient,
    this.recipientNote,
    this.memo,
    this.warning,
    this.zecUsd,
    this.swap,
  });

  final int zatoshis;
  final int fee;

  /// Where the value ends up: the destination address, also for swaps.
  final String recipient;

  /// "Your wallet" or a contact name, when the address is recognised.
  final String? recipientNote;
  final String? memo;
  final String? warning;

  /// Display-only price for the approximate dollar value.
  final double? zecUsd;
  final SwapReview? swap;
}

/// Where an open review puts its Cancel / Confirm buttons when the screen
/// pins them to the bottom (the chat). Only the newest open review owns it;
/// a closed, replaced or disposed review gives it up.
class ReviewActionHost extends ChangeNotifier {
  Object? _owner;
  WidgetBuilder? _builder;
  bool _scheduled = false;

  WidgetBuilder? get builder => _builder;
  bool get active => _builder != null;

  void _notifySoon() {
    // Reviews report from their own build; tell listeners after the frame.
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void show(Object owner, WidgetBuilder builder) {
    _owner = owner;
    _builder = builder;
    _notifySoon();
  }

  void release(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _builder = null;
    _notifySoon();
  }
}

/// Pinned action area for [ReviewActionHost]; empty when no review is open.
class ReviewActionBar extends StatelessWidget {
  const ReviewActionBar({super.key, required this.host});
  final ReviewActionHost host;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final builder = host.builder;
        return AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.bottomCenter,
            child: builder == null
                ? const SizedBox(width: double.infinity)
                : Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(ZipherSpacing.md,
                        ZipherSpacing.smMd, ZipherSpacing.md, ZipherSpacing.sm),
                    decoration: const BoxDecoration(
                        color: ZipherColors.bg,
                        border: Border(
                            top: BorderSide(
                                color: ZipherColors.separator, width: .5))),
                    child: builder(context)));
      });
}

enum ReviewPhase {
  open,
  sending,

  /// Approved and accepted by a server.
  sent,

  /// Approved, but the network has not accepted it; the status card explains.
  approved,
  cancelled,
  expired,
  failed
}

/// Single-use payment review. Fee changes disable signing until a new exact
/// proposal is ready; failures leave signing disabled until a successful retry.
/// Once used or replaced it folds into a one-line record of what happened.
class WalletReviewCard extends StatefulWidget {
  final ValueNotifier<int> epoch;
  final int expectedEpoch;
  final ReviewData data;
  final String confirmLabel;
  final Future<void> Function() onConfirm;
  final VoidCallback onCancel;

  /// Rebuilds the proposal at the other fee tier and returns its exact fee.
  final Future<int> Function(bool)? onPriorityChanged;

  /// Outcome reported by the owner after Confirm or Cancel.
  final ValueListenable<ReviewPhase>? phase;

  /// Offered when a swap quote lapses while the review is open.
  final VoidCallback? onRequote;

  /// The quote stops being usable this long before its deadline.
  final Duration expiryMargin;

  /// Clock for the quote deadline; the device clock unless a test supplies one.
  final DateTime Function()? now;

  /// When set, Cancel / Confirm are pinned by the screen instead of inline.
  final ReviewActionHost? actions;

  const WalletReviewCard(
      {super.key,
      required this.epoch,
      required this.expectedEpoch,
      required this.data,
      required this.confirmLabel,
      required this.onConfirm,
      required this.onCancel,
      this.onPriorityChanged,
      this.phase,
      this.onRequote,
      this.expiryMargin = const Duration(minutes: 2),
      this.now,
      this.actions});
  @override
  State<WalletReviewCard> createState() => _WalletReviewCardState();
}

class _WalletReviewCardState extends State<WalletReviewCard> {
  bool _used = false;
  bool _cancelled = false;
  bool _priority = false;
  bool _updating = false;
  bool _feeFailed = false;
  bool _showAddress = false;
  bool _showDetails = false;
  bool _lapsed = false;
  late int _fee = widget.data.fee;
  Timer? _clock;

  static const _label = TextStyle(fontSize: 14, color: ZipherColors.text40);
  static const _value = TextStyle(
      fontSize: 14,
      color: ZipherColors.text90,
      fontFeatures: [FontFeature.tabularFigures()]);
  static final _mono = ZipherType.mono.copyWith(fontSize: 12);

  @override
  void initState() {
    super.initState();
    widget.phase?.addListener(_refresh);
    if (widget.data.swap?.expiry != null) {
      _lapsed = (_timeLeft ?? Duration.zero) <= Duration.zero;
      _clock =
          Timer.periodic(const Duration(seconds: 15), (_) => _checkExpiry());
    }
  }

  @override
  void dispose() {
    widget.phase?.removeListener(_refresh);
    widget.actions?.release(this);
    _clock?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Duration? get _timeLeft {
    final expiry = widget.data.swap?.expiry;
    final now = (widget.now ?? DateTime.now)();
    return expiry?.difference(now.add(widget.expiryMargin));
  }

  void _checkExpiry() {
    final left = _timeLeft;
    if (left == null || !mounted) return;
    if (left <= Duration.zero) {
      _clock?.cancel();
      if (!_lapsed) setState(() => _lapsed = true);
    } else if (left < const Duration(minutes: 15)) {
      setState(() {});
    }
  }

  Future<void> _changeFee(bool priority) async {
    if (_used || _updating || widget.epoch.value != widget.expectedEpoch)
      return;
    setState(() {
      _priority = priority;
      _updating = true;
      _feeFailed = false;
    });
    try {
      final fee = await widget.onPriorityChanged!(priority);
      if (!mounted || widget.epoch.value != widget.expectedEpoch) return;
      setState(() => _fee = fee);
    } catch (_) {
      if (mounted) setState(() => _feeFailed = true);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  String _zec(int zatoshis) => '${WalletConversation.formatZec(zatoshis)} ZEC';

  Widget _row(String label, String value, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Flexible(child: Text(label, style: _label)),
        const SizedBox(width: ZipherSpacing.md),
        Expanded(
            flex: 2,
            child: Text(value,
                textAlign: TextAlign.right,
                style: _value.copyWith(
                    fontWeight: strong ? FontWeight.w600 : FontWeight.w400))),
      ]));

  /// One side of the exchange: logo, what it is, and how much.
  Widget _side(
          {required Widget icon,
          required String label,
          required String amount,
          String? caption,
          double? usd}) =>
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        icon,
        const SizedBox(width: ZipherSpacing.smMd),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: _label.copyWith(fontSize: 13)),
          const SizedBox(height: 2),
          FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(amount, style: ZipherType.amount)),
          if (caption != null || usd != null)
            Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                    [
                      if (usd != null) '≈ ${WalletAmounts.dollars(usd)}',
                      if (caption != null) caption,
                    ].join(' · '),
                    style: ZipherType.footnote)),
        ])),
      ]);

  Widget _amounts() {
    final data = widget.data;
    final swap = data.swap;
    final price = data.zecUsd;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _side(
          icon: const CurrencyIcon(symbol: 'ZEC', size: 36),
          label: swap == null ? 'You send' : 'You pay',
          amount: _zec(data.zatoshis),
          usd: price == null ? null : data.zatoshis / 1e8 * price),
      if (swap != null) ...[
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              const SizedBox(
                  width: 36,
                  child: Icon(Icons.arrow_downward_rounded,
                      size: 16, color: ZipherColors.text20)),
              const SizedBox(width: ZipherSpacing.smMd),
              Expanded(
                  child: Container(height: .5, color: ZipherColors.separator)),
            ])),
        _side(
            icon: CurrencyIcon(
                symbol: swap.symbol, blockchain: swap.chain, size: 36),
            label: 'You receive',
            amount: '${swap.estimated} ${swap.symbol}',
            caption: 'on ${swap.network}',
            usd: swap.usd),
      ],
    ]);
  }

  Widget _recipient() {
    final data = widget.data;
    final note = data.recipientNote;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
          onTap: () => setState(() => _showAddress = !_showAddress),
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                const Text('To', style: _label),
                const SizedBox(width: ZipherSpacing.md),
                Expanded(
                    child: Text(
                        note == null
                            ? WalletAmounts.shortAddress(data.recipient,
                                head: 10, tail: 8)
                            : '$note · ${WalletAmounts.shortAddress(data.recipient, head: 6, tail: 6)}',
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: _value)),
                const SizedBox(width: ZipherSpacing.xs),
                Icon(_showAddress ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: ZipherColors.text40),
              ]))),
      if (_showAddress)
        Padding(
            padding: const EdgeInsets.only(bottom: ZipherSpacing.sm),
            child: SelectableText(data.recipient, style: _mono)),
    ]);
  }

  /// The few facts needed to decide. Everything else is under Details.
  Widget _summary() {
    final data = widget.data;
    final swap = data.swap;
    final left = _timeLeft;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _recipient(),
      if (swap?.rate != null) _row('Rate', swap!.rate!),
      _row('Network fee', _updating ? 'Updating…' : _zec(_fee)),
      if (swap == null)
        _row('Total', _updating ? '—' : _zec(data.zatoshis + _fee),
            strong: true),
      if (swap?.eta != null)
        _row('Arrives in', WalletAmounts.duration(swap!.eta!)),
      if (left != null && left > Duration.zero && left.inMinutes < 15)
        _row('Quote expires in', '${left.inMinutes + 1} min'),
      if (data.memo != null) _detail('Memo', data.memo!),
    ]);
  }

  Widget _details() {
    final data = widget.data;
    final swap = data.swap;
    if (swap == null && widget.onPriorityChanged == null) {
      return const SizedBox.shrink();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
          onTap: () => setState(() => _showDetails = !_showDetails),
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Text('Details',
                    style: _label.copyWith(
                        color: ZipherColors.cyan, fontWeight: FontWeight.w500)),
                const SizedBox(width: 2),
                Icon(_showDetails ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: ZipherColors.cyan),
              ]))),
      if (_showDetails) ...[
        if (swap != null) ...[
          _row('Minimum received', '${swap.minimum} ${swap.symbol}'),
          _row('Total',
              _updating ? '—' : _zec(data.zatoshis + _fee)),
          _row('Swap fee', '${swap.appFee} · included in the rate'),
          _row('Slippage limit', swap.slippage),
          if (swap.expiry != null)
            _row('Quote valid until',
                DateFormat('MMM d, HH:mm').format(swap.expiry!.toLocal())),
        ],
        if (widget.onPriorityChanged != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Priority fee',
                          style: TextStyle(
                              fontSize: 14, color: ZipherColors.text90)),
                      Text(
                          _priority
                              ? '10× standard fee rate · confirmation time is not guaranteed'
                              : 'Standard fee · recommended',
                          style: ZipherType.footnote.copyWith(fontSize: 12)),
                    ])),
                Switch.adaptive(
                    value: _priority,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: !_updating ? _changeFee : null),
              ])),
        if (swap != null) ...[
          _detail('ZEC deposit address', swap.depositAddress),
          _detail('Refund address', swap.refundAddress),
          _note(Icons.info_outline_rounded,
              'NEAR Intents runs this swap and sees the destination and refund addresses. The ${swap.network} transfer is public.'),
        ],
      ],
    ]);
  }

  Widget _detail(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: _label),
        const SizedBox(height: 3),
        SelectableText(value, style: _mono),
      ]));

  Widget _note(IconData icon, String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: ZipherSpacing.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: color ?? ZipherColors.text40)),
        const SizedBox(width: ZipherSpacing.sm),
        Expanded(
            child: Text(text,
                style: ZipherType.footnote
                    .copyWith(fontSize: 12, color: color))),
      ]));

  void _cancel() {
    if (_used || _updating || widget.epoch.value != widget.expectedEpoch) {
      return;
    }
    setState(() {
      _used = true;
      _cancelled = true;
    });
    widget.onCancel();
  }

  Future<void> _confirm() async {
    if (_used ||
        _updating ||
        _feeFailed ||
        _lapsed ||
        widget.epoch.value != widget.expectedEpoch) return;
    setState(() => _used = true);
    await widget.onConfirm();
  }

  /// Cancel / Confirm, inline or in the screen's pinned action bar.
  Widget _buttons(bool canConfirm) => Row(children: [
        Expanded(
            child: TextButton(
                style: TextButton.styleFrom(
                    minimumSize: const Size(64, 52),
                    foregroundColor: ZipherColors.text60,
                    textStyle: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w500)),
                onPressed: !_updating ? _cancel : null,
                child: const FittedBox(
                    fit: BoxFit.scaleDown, child: Text('Cancel')))),
        const SizedBox(width: ZipherSpacing.smMd),
        Expanded(
            flex: 2,
            child: FilledButton(
                onPressed: canConfirm ? _confirm : null,
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child:
                        Text(_updating ? 'Updating…' : widget.confirmLabel)))),
      ]);

  /// What became of a review that can no longer be confirmed.
  ({IconData? icon, String text, Color color}) _closed(bool replaced) {
    const cancelled = (
      icon: Icons.close_rounded,
      text: 'Cancelled · nothing was sent',
      color: ZipherColors.text40
    );
    const expired = (
      icon: Icons.schedule_rounded,
      text: 'Quote expired · nothing was sent',
      color: ZipherColors.text40
    );
    return switch (widget.phase?.value ?? ReviewPhase.open) {
      ReviewPhase.sending => (
          icon: null,
          text: 'Approved · signing and sending…',
          color: ZipherColors.textSecondary
        ),
      ReviewPhase.sent => (
          icon: Icons.check_circle_rounded,
          text: 'Approved and submitted',
          color: ZipherColors.green
        ),
      ReviewPhase.approved => (
          icon: Icons.check_circle_outline_rounded,
          text: 'Approved · see the status below',
          color: ZipherColors.textSecondary
        ),
      ReviewPhase.failed => (
          icon: Icons.error_outline_rounded,
          text: 'Not sent',
          color: ZipherColors.red
        ),
      ReviewPhase.expired => expired,
      ReviewPhase.cancelled => cancelled,
      ReviewPhase.open => _cancelled
          ? cancelled
          : _lapsed && !_used
              ? expired
              : replaced
                  ? (
                      icon: Icons.history_rounded,
                      text: 'Replaced by a newer request',
                      color: ZipherColors.text40
                    )
                  : (
                      icon: null,
                      text: 'Waiting for your approval…',
                      color: ZipherColors.textSecondary
                    ),
    };
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: widget.epoch,
      builder: (_, epoch, __) {
        final data = widget.data;
        final current = epoch == widget.expectedEpoch;
        final active = !_used &&
            current &&
            !_lapsed &&
            (widget.phase?.value ?? ReviewPhase.open) == ReviewPhase.open;
        final host = widget.actions;
        if (host != null) {
          if (active) {
            host.show(this, (_) => _buttons(!_updating && !_feeFailed));
          } else {
            host.release(this);
          }
        }
        if (!active) {
          final closed = _closed(!current);
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _amounts(),
                const SizedBox(height: ZipherSpacing.smMd),
                Container(height: .5, color: ZipherColors.separator),
                const SizedBox(height: ZipherSpacing.smMd),
                Row(children: [
                  if (closed.icon == null)
                    const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5))
                  else
                    Icon(closed.icon, size: 16, color: closed.color),
                  const SizedBox(width: ZipherSpacing.sm),
                  Expanded(
                      child: Text(closed.text,
                          style: TextStyle(fontSize: 13, color: closed.color))),
                  if (_lapsed && !_used && current && widget.onRequote != null)
                    TextButton(
                        onPressed: widget.onRequote,
                        child: const Text('Get a new quote')),
                ]),
              ]);
        }
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _amounts(),
              const SizedBox(height: ZipherSpacing.smMd),
              Container(height: .5, color: ZipherColors.separator),
              const SizedBox(height: 6),
              _summary(),
              if (data.warning != null)
                _note(Icons.visibility_outlined, data.warning!,
                    color: ZipherColors.warm),
              _details(),
              if (_feeFailed)
                TextButton(
                    onPressed: !_updating ? () => _changeFee(_priority) : null,
                    child: const Text('Fee update failed. Retry')),
              if (host == null) ...[
                const SizedBox(height: ZipherSpacing.sm),
                _buttons(!_updating && !_feeFailed),
              ],
            ]);
      });
}
