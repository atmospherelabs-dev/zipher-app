import 'package:flutter/material.dart';
import '../../../zipher_theme.dart';

/// Single-use payment review. Fee changes disable signing until a new exact
/// proposal is ready; failures leave signing disabled until a successful retry.
class WalletReviewCard extends StatefulWidget {
  final ValueNotifier<int> epoch;
  final int expectedEpoch;
  final Map<String, String> details;
  final String confirmLabel;
  final Future<void> Function() onConfirm;
  final VoidCallback onCancel;
  final Future<Map<String, String>> Function(bool)? onPriorityChanged;
  const WalletReviewCard(
      {super.key,
      required this.epoch,
      required this.expectedEpoch,
      required this.details,
      required this.confirmLabel,
      required this.onConfirm,
      required this.onCancel,
      this.onPriorityChanged});
  @override
  State<WalletReviewCard> createState() => _WalletReviewCardState();
}

class _WalletReviewCardState extends State<WalletReviewCard> {
  bool _used = false;
  bool _priority = false;
  bool _updating = false;
  bool _feeFailed = false;
  bool _showAddress = false;
  late Map<String, String> _details = Map.of(widget.details);

  Future<void> _changeFee(bool priority) async {
    if (_used || _updating || widget.epoch.value != widget.expectedEpoch)
      return;
    setState(() {
      _priority = priority;
      _updating = true;
      _feeFailed = false;
    });
    try {
      final details = await widget.onPriorityChanged!(priority);
      if (!mounted || widget.epoch.value != widget.expectedEpoch) return;
      setState(() => _details = details);
    } catch (_) {
      if (mounted) setState(() => _feeFailed = true);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Widget _row(String label, String value, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(fontSize: 12, color: ZipherColors.text40)),
        const SizedBox(width: 16),
        Expanded(
            child: Text(_money(value),
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 12,
                    fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
                    color: strong
                        ? ZipherColors.textPrimary
                        : ZipherColors.textSecondary))),
      ]));

  String _money(String value) => value.replaceAllMapped(
      RegExp(r'(\d+\.\d+)(?= ZEC)'),
      (match) => match[1]!.replaceFirst(RegExp(r'\.?0+$'), ''));

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: widget.epoch,
      builder: (_, epoch, __) {
        final active = !_used && epoch == widget.expectedEpoch;
        final canConfirm = active && !_updating && !_feeFailed;
        final recipient = _details['Recipient'];
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('YOU SEND',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                      color: ZipherColors.text40)),
              const SizedBox(height: 8),
              Text(_money(_details['Amount'] ?? ''),
                  style: const TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -1,
                      color: ZipherColors.textPrimary)),
              const SizedBox(height: 10),
              if (recipient != null) ...[
                InkWell(
                    onTap: () => setState(() => _showAddress = !_showAddress),
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(children: [
                          const Text('To',
                              style: TextStyle(
                                  fontSize: 12, color: ZipherColors.text40)),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(
                                  recipient.length > 32
                                      ? '${recipient.substring(0, 12)}…${recipient.substring(recipient.length - 12)}'
                                      : recipient,
                                  style: const TextStyle(
                                      fontFamily: 'JetBrains Mono',
                                      fontSize: 12,
                                      color: ZipherColors.textPrimary))),
                          Icon(
                              _showAddress
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 16,
                              color: ZipherColors.text40),
                        ]))),
                if (_showAddress)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SelectableText(recipient,
                          style: const TextStyle(
                              fontFamily: 'JetBrains Mono',
                              fontSize: 11,
                              height: 1.5,
                              color: ZipherColors.textSecondary))),
                const SizedBox(height: 4),
              ],
              const Divider(height: 1),
              if (widget.onPriorityChanged != null) ...[
                Row(children: [
                  const Expanded(
                      child: Text('Priority fee',
                          style: TextStyle(
                              fontSize: 13, color: ZipherColors.textPrimary))),
                  Switch.adaptive(
                      value: _priority,
                      onChanged: active && !_updating ? _changeFee : null),
                ]),
                Text(
                    _priority
                        ? '4× fee rate · confirmation time is not guaranteed'
                        : 'Standard fee · recommended',
                    style: const TextStyle(
                        fontSize: 11, height: 1.4, color: ZipherColors.text40)),
                const SizedBox(height: 8),
              ],
              _row('Network fee',
                  _updating ? 'Updating…' : _details['Network fee'] ?? '—'),
              _row('Total', _updating ? '—' : _details['Total'] ?? '—',
                  strong: true),
              for (final entry in _details.entries.where((entry) => ![
                    'Amount',
                    'Recipient',
                    'Network fee',
                    'Total'
                  ].contains(entry.key)))
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.key,
                              style: const TextStyle(
                                  fontSize: 11, color: ZipherColors.text40)),
                          const SizedBox(height: 4),
                          SelectableText(entry.value,
                              style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: ZipherColors.textSecondary)),
                        ])),
              if (_feeFailed)
                TextButton(
                    onPressed: active && !_updating
                        ? () => _changeFee(_priority)
                        : null,
                    child: const Text('Fee update failed. Retry')),
              const SizedBox(height: 10),
              if (active)
                Row(children: [
                  Expanded(
                      child: TextButton(
                          onPressed: !_updating
                              ? () {
                                  if (_used ||
                                      widget.epoch.value !=
                                          widget.expectedEpoch) return;
                                  setState(() => _used = true);
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
                                      widget.epoch.value !=
                                          widget.expectedEpoch) return;
                                  setState(() => _used = true);
                                  await widget.onConfirm();
                                }
                              : null,
                          child: Text(
                              _updating ? 'Updating…' : widget.confirmLabel))),
                ])
              else
                const Text('Review closed',
                    style: TextStyle(fontSize: 12, color: ZipherColors.text40)),
            ]);
      });
}
