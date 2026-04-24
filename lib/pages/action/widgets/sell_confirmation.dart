import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../zipher_theme.dart';
import '../../../services/action_executor.dart';

class SellConfirmation extends StatefulWidget {
  final int marketId;
  final String marketTitle;
  final String outcomeTitle;
  final int outcomeId;
  final double shares;
  final Function(String) onResult;

  const SellConfirmation({
    super.key,
    required this.marketId,
    required this.marketTitle,
    required this.outcomeTitle,
    required this.outcomeId,
    required this.shares,
    required this.onResult,
  });

  @override
  State<SellConfirmation> createState() => _SellConfirmationState();
}

class _SellConfirmationState extends State<SellConfirmation> {
  bool _executing = false;
  bool _done = false;
  bool _failed = false;
  ActionProgress? _currentProgress;
  String? _resultDetail;

  static final _txHashPattern = RegExp(r'TX:\s*(0x[a-fA-F0-9]{64})');

  Future<void> _startSell() async {
    setState(() { _executing = true; });

    final executor = ActionExecutor.instance;
    final progressCtrl = StreamController<ActionProgress>();
    progressCtrl.stream.listen((p) {
      if (mounted) setState(() { _currentProgress = p; });
    });

    final result = await executor.executeSell(
      marketId: widget.marketId,
      outcomeId: widget.outcomeId,
      shares: widget.shares,
      progress: progressCtrl,
    );

    await progressCtrl.close();

    if (mounted) {
      setState(() {
        _executing = false;
        _done = result.success;
        _failed = !result.success;
        _resultDetail = result.message;
      });
      widget.onResult(result.success ? 'Position sold.' : result.message);
    }
  }

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.sell, size: 16, color: Colors.orangeAccent),
              ),
              const Gap(10),
              const Expanded(
                child: Text('Sell Position',
                    style: TextStyle(color: ZipherColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
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
          _row('Shares', widget.shares.toStringAsFixed(2)),

          if (!_executing && !_done && !_failed) ...[
            const Gap(16),
            Row(
              children: [
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
                    onPressed: _startSell,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
                    ),
                    child: const Text('Sell All'),
                  ),
                ),
              ],
            ),
          ],

          if (_executing && _currentProgress != null) ...[
            const Gap(16),
            LinearProgressIndicator(
              value: _currentProgress!.totalSteps > 0
                  ? _currentProgress!.step / _currentProgress!.totalSteps : null,
              backgroundColor: ZipherColors.text10,
              color: Colors.orangeAccent,
            ),
            const Gap(8),
            Text(_currentProgress!.label, style: TextStyle(color: ZipherColors.text60, fontSize: 12)),
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
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 12)),
          Text(value, style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 12, fontFamily: 'JetBrains Mono')),
        ],
      ),
    );
  }
}
