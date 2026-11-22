import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
      this.now});
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

  static const _label = TextStyle(fontSize: 12, color: ZipherColors.text40);
  static const _mono = TextStyle(
      fontFamily: 'JetBrains Mono',
      fontSize: 12,
      color: ZipherColors.textSecondary);

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
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: _label),
        const SizedBox(width: 16),
        Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: _mono.copyWith(
                    fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
                    color: strong
                        ? ZipherColors.textPrimary
                        : ZipherColors.textSecondary))),
      ]));

  Widget _side(
          {required Widget icon,
          required String label,
          required String amount,
          String? caption,
          double? usd}) =>
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        icon,
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                  color: ZipherColors.text40)),
          const SizedBox(height: 3),
          FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(amount,
                  style: const TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -.6,
                      color: ZipherColors.textPrimary))),
          if (caption != null)
            Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(caption, style: _label)),
        ])),
        if (usd != null)
          Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('≈ ${WalletAmounts.dollars(usd)}',
                  style: const TextStyle(
                      fontSize: 12, color: ZipherColors.textSecondary))),
      ]);

  Widget _amounts() {
    final data = widget.data;
    final swap = data.swap;
    final price = data.zecUsd;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _side(
          icon: const CurrencyIcon(symbol: 'ZEC', size: 32),
          label: swap == null ? 'You send' : 'You pay',
          amount: _zec(data.zatoshis),
          usd: price == null ? null : data.zatoshis / 1e8 * price),
      if (swap != null) ...[
        const Padding(
            padding: EdgeInsets.only(left: 8, top: 4, bottom: 4),
            child: Align(
                alignment: Alignment.centerLeft,
                child: Icon(Icons.arrow_downward_rounded,
                    size: 16, color: ZipherColors.text20))),
        _side(
            icon: CurrencyIcon(
                symbol: swap.symbol, blockchain: swap.chain, size: 32),
            label: 'You receive · estimated',
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
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(children: [
                const Text('To', style: _label),
                const SizedBox(width: 16),
                Expanded(
                    child: Text(
                        note == null
                            ? WalletAmounts.shortAddress(data.recipient,
                                head: 12, tail: 12)
                            : '$note · ${WalletAmounts.shortAddress(data.recipient, head: 6, tail: 6)}',
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style:
                            _mono.copyWith(color: ZipherColors.textPrimary))),
                const SizedBox(width: 4),
                Icon(_showAddress ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: ZipherColors.text40),
              ]))),
      if (_showAddress)
        Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(data.recipient,
                style: _mono.copyWith(fontSize: 11, height: 1.5))),
    ]);
  }

  Widget _swapRows(SwapReview swap) {
    final left = _timeLeft;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (swap.rate != null) _row('Rate', swap.rate!),
      _row('Minimum received', '${swap.minimum} ${swap.symbol}'),
      if (swap.eta != null)
        _row('Arrives in', WalletAmounts.duration(swap.eta!)),
      if (left != null && left > Duration.zero && left.inMinutes < 15)
        _row('Quote expires in', '${left.inMinutes + 1} min'),
    ]);
  }

  Widget _swapDetails(SwapReview swap) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
            onTap: () => setState(() => _showDetails = !_showDetails),
            child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  const Expanded(child: Text('Details', style: _label)),
                  Icon(_showDetails ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: ZipherColors.text40),
                ]))),
        if (_showDetails) ...[
          _row('Slippage limit', swap.slippage),
          _row('Swap fee', '${swap.appFee} · included in the rate'),
          if (swap.expiry != null)
            _row('Quote valid until',
                DateFormat('MMM d, HH:mm').format(swap.expiry!.toLocal())),
          _detail('ZEC deposit address', swap.depositAddress),
          _detail('Refund address', swap.refundAddress),
        ],
      ]);

  Widget _detail(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: _label),
        const SizedBox(height: 3),
        SelectableText(value, style: _mono.copyWith(fontSize: 11, height: 1.4)),
      ]));

  Widget _note(IconData icon, String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 13, color: color ?? ZipherColors.text40)),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: color ?? ZipherColors.text40))),
      ]));

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
        final swap = data.swap;
        final current = epoch == widget.expectedEpoch;
        final active = !_used &&
            current &&
            !_lapsed &&
            (widget.phase?.value ?? ReviewPhase.open) == ReviewPhase.open;
        final canConfirm = active && !_updating && !_feeFailed;
        if (!active) {
          final closed = _closed(!current);
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _amounts(),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 10),
                Row(children: [
                  if (closed.icon == null)
                    const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 1.5))
                  else
                    Icon(closed.icon, size: 15, color: closed.color),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(closed.text,
                          style: TextStyle(fontSize: 12, color: closed.color))),
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
              const SizedBox(height: 10),
              const Divider(height: 1),
              _recipient(),
              if (swap != null) _swapRows(swap),
              _row('Network fee', _updating ? 'Updating…' : _zec(_fee)),
              _row('Total', _updating ? '—' : _zec(data.zatoshis + _fee),
                  strong: true),
              if (data.memo != null) _detail('Memo', data.memo!),
              if (widget.onPriorityChanged != null)
                Row(children: [
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('Priority fee',
                            style: TextStyle(
                                fontSize: 13, color: ZipherColors.textPrimary)),
                        Text(
                            _priority
                                ? '10× standard fee rate · confirmation time is not guaranteed'
                                : 'Standard fee · recommended',
                            style: const TextStyle(
                                fontSize: 11,
                                height: 1.4,
                                color: ZipherColors.text40)),
                      ])),
                  Switch.adaptive(
                      value: _priority,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: !_updating ? _changeFee : null),
                ]),
              if (swap != null) _swapDetails(swap),
              if (data.warning != null)
                _note(Icons.visibility_outlined, data.warning!,
                    color: ZipherColors.warm),
              if (swap != null)
                _note(Icons.info_outline_rounded,
                    'NEAR Intents runs this swap and sees the destination and refund addresses. The ${swap.network} transfer is public.'),
              if (_feeFailed)
                TextButton(
                    onPressed: !_updating ? () => _changeFee(_priority) : null,
                    child: const Text('Fee update failed. Retry')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextButton(
                        onPressed: !_updating
                            ? () {
                                if (_used ||
                                    widget.epoch.value != widget.expectedEpoch)
                                  return;
                                setState(() {
                                  _used = true;
                                  _cancelled = true;
                                });
                                widget.onCancel();
                              }
                            : null,
                        child: const Text('Cancel'))),
                const SizedBox(width: 12),
                Expanded(
                    flex: 2,
                    child: FilledButton(
                        onPressed: canConfirm
                            ? () async {
                                if (_used ||
                                    _updating ||
                                    _feeFailed ||
                                    _lapsed ||
                                    widget.epoch.value != widget.expectedEpoch)
                                  return;
                                setState(() => _used = true);
                                await widget.onConfirm();
                              }
                            : null,
                        child: Text(
                            _updating ? 'Updating…' : widget.confirmLabel))),
              ]),
            ]);
      });
}
