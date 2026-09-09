import 'package:flutter/material.dart';
import '../../../zipher_theme.dart';

/// A one-use review. Cancelled, replaced and submitted cards cannot be replayed.
/// Kept independent of the wallet engine so lifecycle behavior is testable.
class WalletReviewCard extends StatefulWidget {
  final ValueNotifier<int> epoch;
  final int expectedEpoch;
  final Map<String, String> details;
  final String confirmLabel;
  final Future<void> Function() onConfirm;
  final VoidCallback onCancel;
  const WalletReviewCard(
      {super.key,
      required this.epoch,
      required this.expectedEpoch,
      required this.details,
      required this.confirmLabel,
      required this.onConfirm,
      required this.onCancel});
  @override
  State<WalletReviewCard> createState() => _WalletReviewCardState();
}

class _WalletReviewCardState extends State<WalletReviewCard> {
  bool _used = false;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: widget.epoch,
        builder: (_, epoch, __) {
          final enabled = !_used && epoch == widget.expectedEpoch;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                for (final entry in widget.details.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.key,
                              style: TextStyle(
                                  fontSize: 11, color: ZipherColors.text40)),
                          SelectableText(entry.value,
                              style: const TextStyle(fontSize: 13)),
                        ]),
                  ),
                if (enabled)
                  Wrap(spacing: 12, children: [
                    TextButton(
                        onPressed: () {
                          if (_used ||
                              widget.epoch.value != widget.expectedEpoch)
                            return;
                          setState(() => _used = true);
                          widget.onCancel();
                        },
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          if (_used ||
                              widget.epoch.value != widget.expectedEpoch)
                            return;
                          setState(() => _used = true);
                          await widget.onConfirm();
                        },
                        child: Text(widget.confirmLabel)),
                  ])
                else
                  const Text('Review closed', style: TextStyle(fontSize: 12)),
              ]);
        },
      );
}
