import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';

import '../../../zipher_theme.dart';
import '../../../services/action_executor.dart';
import '../models.dart';

class SweepConfirmation extends StatefulWidget {
  final List<SweepableToken> tokens;
  final double totalUsd;
  final Function(String) onResult;

  const SweepConfirmation({
    super.key,
    required this.tokens,
    required this.totalUsd,
    required this.onResult,
  });

  @override
  State<SweepConfirmation> createState() => _SweepConfirmationState();
}

class _SweepConfirmationState extends State<SweepConfirmation> {
  late final Set<String> _selected;
  bool _executing = false;
  bool _done = false;
  bool _failed = false;
  ActionProgress? _currentProgress;
  String? _resultDetail;

  @override
  void initState() {
    super.initState();
    _selected = widget.tokens.map((t) => t.symbol).toSet();
  }

  double get _selectedUsd => widget.tokens
      .where((t) => _selected.contains(t.symbol))
      .fold<double>(0, (s, t) => s + t.usdValue);

  bool get _hasSelected => _selected.isNotEmpty;

  Future<void> _startSweep() async {
    final toSweep = widget.tokens.where((t) => _selected.contains(t.symbol)).toList();
    if (toSweep.isEmpty) return;

    setState(() { _executing = true; });

    final executor = ActionExecutor.instance;
    final progressCtrl = StreamController<ActionProgress>();
    progressCtrl.stream.listen((p) {
      if (mounted) setState(() { _currentProgress = p; });
    });

    final results = <String>[];
    var anySuccess = false;

    for (final token in toSweep) {
      ActionResult result;

      if (token.isNative) {
        result = await executor.executeSweepBnbToZec(amount: token.sweepAmount, progress: progressCtrl);
      } else if (token.contractAddress != null && token.defuseAssetId != null) {
        result = await executor.executeSweepTokenToZec(
          tokenSymbol: token.symbol, contractAddress: token.contractAddress!,
          decimals: token.decimals, amount: token.sweepAmount,
          defuseAssetId: token.defuseAssetId!, progress: progressCtrl,
        );
      } else {
        results.add('${token.symbol}: not supported by bridge.');
        continue;
      }

      results.add(result.message.isNotEmpty ? result.message : (result.success ? '${token.symbol} swept.' : '${token.symbol} sweep failed.'));
      if (result.success) anySuccess = true;
    }

    await progressCtrl.close();

    if (mounted) {
      setState(() {
        _executing = false;
        _done = anySuccess;
        _failed = !anySuccess;
        _resultDetail = results.join('\n');
      });
      widget.onResult(anySuccess ? 'Sweep complete.' : (results.join('\n')));
    }
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
                  color: ZipherColors.cyan.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.swap_horiz, size: 16, color: ZipherColors.cyan),
              ),
              const Gap(10),
              Expanded(
                child: Text('Sweep to ZEC  ~\$${_selectedUsd.toStringAsFixed(2)}',
                    style: const TextStyle(color: ZipherColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const Gap(12),

          ...widget.tokens.map((t) {
            final isOn = _selected.contains(t.symbol);
            final canSweep = t.symbol == 'USDT';
            return GestureDetector(
              onTap: (!_executing && !_done && !_failed) ? () {
                setState(() { isOn ? _selected.remove(t.symbol) : _selected.add(t.symbol); });
              } : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(width: 22, height: 22,
                        child: Checkbox(
                          value: isOn,
                          onChanged: (!_executing && !_done && !_failed) ? (v) {
                            setState(() { v == true ? _selected.add(t.symbol) : _selected.remove(t.symbol); });
                          } : null,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: BorderSide(color: ZipherColors.text40),
                          activeColor: ZipherColors.cyan,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        )),
                    const Gap(10),
                    ClipOval(
                      child: Image.asset('assets/tokens/${t.symbol.toLowerCase()}.png', width: 20, height: 20,
                          errorBuilder: (_, __, ___) => Container(width: 20, height: 20,
                              decoration: BoxDecoration(color: ZipherColors.text20, shape: BoxShape.circle),
                              child: Center(child: Text(t.symbol[0], style: const TextStyle(fontSize: 10, color: ZipherColors.textPrimary))))),
                    ),
                    const Gap(8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${t.sweepAmount.toStringAsFixed(t.symbol == 'BNB' ? 6 : 2)} ${t.symbol}',
                              style: TextStyle(color: isOn ? ZipherColors.textPrimary : ZipherColors.text40,
                                  fontSize: 13, fontFamily: 'JetBrains Mono')),
                          if (!canSweep)
                            Text('bridge coming soon',
                                style: TextStyle(color: ZipherColors.text40, fontSize: 10, fontStyle: FontStyle.italic)),
                        ],
                      ),
                    ),
                    Text('\$${t.usdValue.toStringAsFixed(2)}',
                        style: TextStyle(color: isOn ? ZipherColors.text60 : ZipherColors.text20, fontSize: 12)),
                  ],
                ),
              ),
            );
          }),

          const Gap(4),
          Text('Cross-chain swap via NEAR Intents. Takes 10-30 min.',
              style: TextStyle(color: ZipherColors.text40, fontSize: 11)),

          if (!_executing && !_done && !_failed) ...[
            const Gap(16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => widget.onResult('Sweep cancelled.'),
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
                    onPressed: _hasSelected ? _startSweep : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZipherColors.cyan, foregroundColor: Colors.white,
                      disabledBackgroundColor: ZipherColors.text10,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
                    ),
                    child: Text(_selected.length == widget.tokens.length ? 'Sweep All → ZEC' : 'Sweep ${_selected.length} → ZEC'),
                  ),
                ),
              ],
            ),
          ],

          if (_executing && _currentProgress != null) ...[
            const Gap(16),
            LinearProgressIndicator(
              value: _currentProgress!.totalSteps > 0 ? _currentProgress!.step / _currentProgress!.totalSteps : null,
              backgroundColor: ZipherColors.text10, color: ZipherColors.cyan,
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
              child: Text(_resultDetail!, style: TextStyle(color: ZipherColors.text60, fontSize: 11, height: 1.4)),
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
}
