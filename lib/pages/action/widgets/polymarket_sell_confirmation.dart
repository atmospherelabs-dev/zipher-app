import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../../zipher_theme.dart';
import '../../../services/action_executor.dart';

/// Confirm and execute a Polymarket CLOB sell (FOK) for an open position.
class PolymarketSellConfirmation extends StatefulWidget {
  final String tokenId;
  final String marketTitle;
  final String outcomeTitle;
  final double shares;
  final double worstPrice;
  final bool negRisk;
  final void Function(String text) onResult;
  final VoidCallback? onBalanceChanged;

  const PolymarketSellConfirmation({
    super.key,
    required this.tokenId,
    required this.marketTitle,
    required this.outcomeTitle,
    required this.shares,
    required this.worstPrice,
    required this.negRisk,
    required this.onResult,
    this.onBalanceChanged,
  });

  @override
  State<PolymarketSellConfirmation> createState() => _PolymarketSellConfirmationState();
}

class _PolymarketSellConfirmationState extends State<PolymarketSellConfirmation>
    with AutomaticKeepAliveClientMixin {
  bool _executing = false;
  bool _done = false;
  bool _failed = false;
  ActionProgress? _currentProgress;
  String? _resultDetail;
  StreamSubscription<ActionProgress>? _executionSub;

  @override
  bool get wantKeepAlive => true;

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

    final stream = ActionExecutor.instance.executeSellPolymarket(
      tokenId: widget.tokenId,
      shares: widget.shares,
      worstPrice: widget.worstPrice,
      negRisk: widget.negRisk,
      marketTitle: widget.marketTitle,
    );

    _executionSub = stream.listen(
      (progress) {
        setState(() => _currentProgress = progress);
        if (progress.isComplete) {
          HapticFeedback.heavyImpact();
          setState(() {
            _executing = false;
            _done = true;
            _resultDetail = progress.detail;
          });
          widget.onBalanceChanged?.call();
        }
        if (progress.isFailed) {
          HapticFeedback.vibrate();
          setState(() {
            _executing = false;
            _failed = true;
            _resultDetail = progress.detail;
          });
          widget.onBalanceChanged?.call();
        }
      },
      onError: (e) {
        setState(() {
          _executing = false;
          _failed = true;
          _resultDetail = '$e';
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final borderColor = _done
        ? ZipherColors.cyan.withValues(alpha: 0.5)
        : _failed
            ? Colors.redAccent.withValues(alpha: 0.4)
            : _executing
                ? const Color(0xFF6366F1).withValues(alpha: 0.3)
                : ZipherColors.borderSubtle;

    final estUsd = widget.shares * widget.worstPrice;

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
              _done ? Icons.check_circle : _failed ? Icons.error_outline : Icons.sell_rounded,
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
                _done ? 'Sell complete' : _failed ? 'Sell failed' : 'Sell on Polymarket',
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
          _row('Shares', widget.shares.toStringAsFixed(4)),
          _row('Min. price', '${(widget.worstPrice * 100).toStringAsFixed(1)}% (slippage floor)'),
          _row('Est. USDC (min)', '\$${estUsd.toStringAsFixed(2)}'),
          if (!_executing && !_done && !_failed) ...[
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
                    'FOK sell on Polygon. You pay POL gas. Outcome tokens are approved for the CLOB once if needed.',
                    style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4),
                  ),
                ),
              ]),
            ),
            const Gap(16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => widget.onResult('Sell cancelled.'),
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
                  child: const Text('Confirm sell'),
                ),
              ),
            ]),
          ],
          if (_executing && _currentProgress != null) ...[
            const Gap(16),
            _buildInlineProgress(_currentProgress!),
          ],
          if (_done) ...[
            const Gap(12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ZipherColors.cyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.2)),
              ),
              child: Row(children: [
                Icon(Icons.check_circle_outline, color: ZipherColors.cyan, size: 16),
                const Gap(8),
                Expanded(
                  child: Text(
                    (_resultDetail != null && _resultDetail!.isNotEmpty)
                        ? _resultDetail!
                        : 'Sell order submitted to Polymarket.',
                    style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4),
                  ),
                ),
              ]),
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
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: const Color(0xFF6366F1),
                  value: progress.status == ActionStatus.waiting ? null : pct)),
          const Gap(10),
          Expanded(
              child: Text(progress.label,
                  style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500))),
          Text('${progress.step}/${progress.totalSteps}',
              style: TextStyle(color: ZipherColors.text40, fontSize: 11, fontFamily: 'JetBrains Mono')),
        ]),
        const Gap(8),
        ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
                value: pct,
                backgroundColor: ZipherColors.cardBgElevated,
                valueColor: const AlwaysStoppedAnimation(Color(0xFF6366F1)),
                minHeight: 3)),
        if (progress.detail.isNotEmpty) ...[
          const Gap(6),
          Text(progress.detail,
              style: TextStyle(color: ZipherColors.text40, fontSize: 11, height: 1.3),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
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
          SizedBox(width: 100, child: Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13))),
          Expanded(child: Text(value, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13))),
        ],
      ),
    );
  }
}
