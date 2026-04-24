import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../zipher_theme.dart';
import '../../../services/action_executor.dart';
import '../intent.dart';

class BetConfirmation extends StatefulWidget {
  final int marketId;
  final String marketTitle;
  final double amount;
  final int outcomeId;
  final String outcomeTitle;
  final String tokenSymbol;
  final void Function(String text, {Widget? card, IntentType? intentType}) onResult;
  final VoidCallback? onBalanceChanged;

  const BetConfirmation({
    super.key,
    required this.marketId,
    required this.marketTitle,
    required this.amount,
    required this.outcomeId,
    required this.outcomeTitle,
    this.tokenSymbol = 'USDT',
    required this.onResult,
    this.onBalanceChanged,
  });

  @override
  State<BetConfirmation> createState() => _BetConfirmationState();
}

class _BetConfirmationState extends State<BetConfirmation> {
  double _slippage = 1.0;
  double _maxPriceMove = 5.0;
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
      final bscAddress = await executor.getBscAddress();
      if (bscAddress == null) {
        if (mounted) setState(() => _flowLabel = 'ZEC → ${widget.tokenSymbol} → Myriad (BSC)');
        return;
      }

      final tokenSymbol = widget.tokenSymbol;
      final needed = widget.amount;
      final existing = await executor.getTokenBalance(bscAddress, tokenSymbol);

      if (existing >= needed * 0.95) {
        if (mounted) setState(() => _flowLabel = '$tokenSymbol (BSC) → Myriad');
        return;
      }

      if (tokenSymbol != 'USDT') {
        final usdtBal = await executor.getTokenBalance(bscAddress, 'USDT');
        final shortfall = needed - existing;
        if (usdtBal >= shortfall * 0.95) {
          if (mounted) setState(() => _flowLabel = 'USDT → $tokenSymbol → Myriad (BSC)');
          return;
        }
      }

      if (mounted) setState(() => _flowLabel = 'ZEC → $tokenSymbol → Myriad (BSC)');
    } catch (_) {
      if (mounted) setState(() => _flowLabel = 'ZEC → ${widget.tokenSymbol} → Myriad (BSC)');
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

    final stream = ActionExecutor.instance.executeBet(
      marketId: widget.marketId,
      outcome: widget.outcomeId,
      amountUsdt: widget.amount,
      slippage: _slippage / 100,
      maxPriceMove: _maxPriceMove,
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
                ? ZipherColors.cyan.withValues(alpha: 0.3)
                : ZipherColors.borderSubtle;

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
          Row(
            children: [
              Icon(
                _done ? Icons.check_circle : _failed ? Icons.error_outline : Icons.casino_rounded,
                color: _done ? ZipherColors.cyan : _failed ? Colors.redAccent : ZipherColors.purple,
                size: 18,
              ),
              const Gap(8),
              Expanded(
                child: Text(
                  _done ? 'Bet Placed' : _failed ? 'Bet Failed' : 'Prediction Market Bet',
                  style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const Gap(12),

          _row('Market', '#${widget.marketId}'),
          if (widget.marketTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(widget.marketTitle,
                  style: TextStyle(color: ZipherColors.text60, fontSize: 12, height: 1.3),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          _row('Outcome', widget.outcomeTitle),
          _row('Amount', '\$${widget.amount.toStringAsFixed(2)}'),
          _row('Token', widget.tokenSymbol),

          if (!_executing && !_done && !_failed) ...[
            _row('Flow', _flowLabel),
            const Gap(16),
            Text('Risk Controls', style: TextStyle(color: ZipherColors.text60, fontSize: 12, fontWeight: FontWeight.w600)),
            const Gap(8),
            _sliderRow('Slippage tolerance', '${_slippage.toStringAsFixed(1)}%', _slippage, 0.1, 10.0, (v) => setState(() => _slippage = v)),
            const Gap(4),
            _sliderRow('Max price movement', '${_maxPriceMove.toStringAsFixed(0)}%', _maxPriceMove, 1.0, 25.0, (v) => setState(() => _maxPriceMove = v)),
            const Gap(8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ZipherColors.warm.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ZipherColors.warm.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: ZipherColors.warm, size: 16),
                  const Gap(8),
                  Expanded(
                    child: Text(
                      'If odds change more than ${_maxPriceMove.toStringAsFixed(0)}% '
                      'during the swap, the bet will be cancelled. USDT stays on BSC.',
                      style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const Gap(16),
            Row(
              children: [
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
                      backgroundColor: ZipherColors.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
                    ),
                    child: const Text('Confirm Bet'),
                  ),
                ),
              ],
            ),
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
              child: _buildResultWithTxLink(_resultDetail!),
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

  static final _txHashPattern = RegExp(r'TX:\s*(0x[a-fA-F0-9]{64})');

  Widget _buildResultWithTxLink(String detail) {
    final match = _txHashPattern.firstMatch(detail);
    if (match == null) {
      return Text(detail, style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4));
    }

    final txHash = match.group(1)!;
    final before = detail.substring(0, match.start);
    final shortHash = '${txHash.substring(0, 10)}...${txHash.substring(txHash.length - 8)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (before.isNotEmpty)
          Text(before.trimRight(), style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4)),
        const Gap(6),
        GestureDetector(
          onTap: () => launchUrl(Uri.parse('https://bscscan.com/tx/$txHash'), mode: LaunchMode.externalApplication),
          child: Row(
            children: [
              const Icon(Icons.open_in_new, size: 12, color: ZipherColors.cyan),
              const Gap(4),
              Text('View on BSCScan ($shortHash)',
                  style: const TextStyle(color: ZipherColors.cyan, fontSize: 11,
                      decoration: TextDecoration.underline, decorationColor: ZipherColors.cyan)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInlineProgress(ActionProgress progress) {
    final pct = progress.totalSteps > 0 ? progress.step / progress.totalSteps : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.cyan,
                    value: progress.status == ActionStatus.waiting ? null : pct)),
            const Gap(10),
            Expanded(child: Text(progress.label,
                style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500))),
            Text('${progress.step}/${progress.totalSteps}',
                style: TextStyle(color: ZipherColors.text40, fontSize: 11, fontFamily: 'JetBrains Mono')),
          ],
        ),
        const Gap(8),
        ClipRRect(borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: pct, backgroundColor: ZipherColors.cardBgElevated,
                valueColor: const AlwaysStoppedAnimation(ZipherColors.cyan), minHeight: 3)),
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

  Widget _sliderRow(String label, String valueStr, double value, double min, double max, ValueChanged<double>? onChanged) {
    return Row(
      children: [
        Expanded(flex: 3, child: Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 12))),
        Expanded(flex: 4, child: SliderTheme(
          data: SliderThemeData(activeTrackColor: ZipherColors.cyan, inactiveTrackColor: ZipherColors.cardBgElevated,
              thumbColor: ZipherColors.cyan, trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
          child: Slider(value: value, min: min, max: max, onChanged: onChanged ?? (_) {}),
        )),
        SizedBox(width: 40, child: Text(valueStr, textAlign: TextAlign.right,
            style: TextStyle(color: ZipherColors.text60, fontSize: 12, fontFamily: 'JetBrains Mono'))),
      ],
    );
  }
}
