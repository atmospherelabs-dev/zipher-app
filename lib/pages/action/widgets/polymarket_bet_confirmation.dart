import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../../zipher_theme.dart';
import '../../../services/action_executor.dart';

class PolymarketBetConfirmation extends StatefulWidget {
  final String conditionId;
  final String marketTitle;
  final double amount;
  final int outcomeIndex;
  final String outcomeTitle;
  final String tokenId;
  final double price;
  final bool negRisk;
  final void Function(String text) onResult;
  final VoidCallback? onBalanceChanged;

  const PolymarketBetConfirmation({
    super.key,
    required this.conditionId,
    required this.marketTitle,
    required this.amount,
    required this.outcomeIndex,
    required this.outcomeTitle,
    required this.tokenId,
    required this.price,
    required this.negRisk,
    required this.onResult,
    this.onBalanceChanged,
  });

  @override
  State<PolymarketBetConfirmation> createState() => _PolymarketBetConfirmationState();
}

class _PolymarketBetConfirmationState extends State<PolymarketBetConfirmation> {
  bool _executing = false;
  bool _done = false;
  bool _failed = false;
  ActionProgress? _currentProgress;
  String? _resultDetail;
  StreamSubscription<ActionProgress>? _executionSub;
  String _flowLabel = '...';

  @override
  void initState() {
    super.initState();
    _computeFlow();
  }

  Future<void> _computeFlow() async {
    try {
      final executor = ActionExecutor.instance;
      final addr = await executor.getPolygonAddress();
      if (addr == null) {
        if (mounted) setState(() => _flowLabel = 'ZEC → POL → USDC.e → Polymarket');
        return;
      }

      final bridged = await executor.getPolygonUsdcBridgedBalance(addr);
      final native = await executor.getPolygonUsdcNativeBalance(addr);
      final pol = await executor.getPolygonPolBalance(addr);
      final totalUsdc = bridged + native;
      final needed = widget.amount * 1.02;

      if (bridged >= needed) {
        if (mounted) setState(() => _flowLabel = 'USDC.e → Polymarket');
      } else if (totalUsdc >= needed && native > 0) {
        if (mounted) setState(() => _flowLabel = 'USDC → USDC.e → Polymarket');
      } else if (pol > 0.5) {
        if (mounted) setState(() => _flowLabel = 'POL → USDC.e → Polymarket');
      } else {
        if (mounted) setState(() => _flowLabel = 'ZEC → POL → USDC.e → Polymarket');
      }
    } catch (_) {
      if (mounted) setState(() => _flowLabel = 'ZEC → POL → USDC.e → Polymarket');
    }
  }

  @override
  void dispose() {
    _executionSub?.cancel();
    super.dispose();
  }

  void _startExecution() {
    setState(() {
      _executing = true;
      _done = false;
      _failed = false;
      _currentProgress = null;
      _resultDetail = null;
    });
    HapticFeedback.mediumImpact();

    final stream = ActionExecutor.instance.executeBetPolymarket(
      tokenId: widget.tokenId,
      amountUsd: widget.amount,
      side: 'BUY',
      price: widget.price,
      negRisk: widget.negRisk,
      marketTitle: widget.marketTitle,
    );

    _executionSub = stream.listen(
      (progress) {
        setState(() => _currentProgress = progress);
        if (progress.isComplete) {
          HapticFeedback.heavyImpact();
          setState(() { _executing = false; _done = true; _resultDetail = progress.detail; });
          widget.onBalanceChanged?.call();
        }
        if (progress.isFailed) {
          HapticFeedback.vibrate();
          setState(() { _executing = false; _failed = true; _resultDetail = progress.detail; });
          widget.onBalanceChanged?.call();
        }
      },
      onError: (e) {
        setState(() { _executing = false; _failed = true; _resultDetail = '$e'; });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _done
        ? ZipherColors.cyan.withValues(alpha: 0.5)
        : _failed
            ? Colors.redAccent.withValues(alpha: 0.4)
            : _executing
                ? const Color(0xFF6366F1).withValues(alpha: 0.3)
                : ZipherColors.borderSubtle;

    final shares = widget.price > 0 ? widget.amount / widget.price : 0.0;
    final payout = shares;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
              _done ? Icons.check_circle : _failed ? Icons.error_outline : Icons.casino_rounded,
              color: _done ? ZipherColors.cyan : _failed ? Colors.redAccent : const Color(0xFF6366F1),
              size: 18,
            ),
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3)),
              child: const Text('PM',
                  style: TextStyle(color: Color(0xFF6366F1), fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'JetBrains Mono')),
            ),
            const Gap(6),
            Expanded(
              child: Text(
                _done ? 'Bet Placed' : _failed ? 'Bet Failed' : 'Polymarket Bet',
                style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          const Gap(12),

          if (widget.marketTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(widget.marketTitle,
                  style: TextStyle(color: ZipherColors.text60, fontSize: 12, height: 1.3),
                  maxLines: 3, overflow: TextOverflow.ellipsis),
            ),

          _row('Outcome', widget.outcomeTitle),
          _row('Amount', '\$${widget.amount.toStringAsFixed(2)} USDC'),
          _row('Price', '${(widget.price * 100).toStringAsFixed(1)}%'),
          _row('Est. Shares', shares.toStringAsFixed(2)),
          _row('Max Payout', '\$${payout.toStringAsFixed(2)}'),

          if (!_executing && !_done && !_failed) ...[
            _row('Flow', _flowLabel),
            const Gap(12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.15)),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, color: const Color(0xFF6366F1), size: 16),
                const Gap(8),
                Expanded(
                  child: Text(
                    'Polymarket uses USDC.e on Polygon. Native USDC is converted on-chain (ParaSwap). '
                    'If you are short, ZEC is bridged to POL (NEAR Intents), then POL is swapped to USDC.e; '
                    'a small POL reserve is kept for gas (configurable in secure storage).',
                    style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4),
                  ),
                ),
              ]),
            ),
            const Gap(16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => widget.onResult('Bet cancelled.'),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: ZipherColors.text20),
                    foregroundColor: ZipherColors.textSecondary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const Gap(12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _startExecution,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
                  ),
                  child: const Text('Confirm Bet'),
                ),
              ),
            ]),
          ],

          if (_executing && _currentProgress != null) ...[
            const Gap(16),
            _buildInlineProgress(_currentProgress!),
          ],

          if (_done && _resultDetail != null) ...[
            const Gap(12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ZipherColors.cyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.2)),
              ),
              child: Text(_resultDetail!,
                  style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4)),
            ),
          ],

          if (_failed) ...[
            const Gap(12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.2)),
              ),
              child: Text(_resultDetail ?? 'Unknown error',
                  style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4)),
            ),
            const Gap(12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _startExecution,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: ZipherColors.text20),
                  foregroundColor: ZipherColors.textSecondary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
                ),
                child: const Text('Retry'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInlineProgress(ActionProgress progress) {
    final pct = progress.totalSteps > 0 ? progress.step / progress.totalSteps : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: const Color(0xFF6366F1),
                  value: progress.status == ActionStatus.waiting ? null : pct)),
          const Gap(10),
          Expanded(child: Text(progress.label,
              style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500))),
          Text('${progress.step}/${progress.totalSteps}',
              style: TextStyle(color: ZipherColors.text40, fontSize: 11, fontFamily: 'JetBrains Mono')),
        ]),
        const Gap(8),
        ClipRRect(borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: pct, backgroundColor: ZipherColors.cardBgElevated,
                valueColor: const AlwaysStoppedAnimation(Color(0xFF6366F1)), minHeight: 3)),
        if (progress.detail.isNotEmpty) ...[
          const Gap(6),
          Text(progress.detail, style: TextStyle(color: ZipherColors.text40, fontSize: 11, height: 1.3),
              maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 80, child: Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13))),
          Expanded(child: Text(value, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13))),
        ],
      ),
    );
  }
}
