import 'package:flutter/material.dart';

import '../../../services/near_intents.dart' show CurrencyIcon;
import '../../../zipher_theme.dart';
import '../wallet_transfer_progress.dart';

/// Where a send or swap stands, updated in place while it progresses.
class WalletTransferStatusCard extends StatelessWidget {
  const WalletTransferStatusCard(
      {super.key,
      required this.progress,
      this.swapChain,
      this.transactionId,
      this.onDetails,
      this.detailsLabel = 'View details',
      this.onCopyId,
      this.onRetry,
      this.retryLabel = 'Try again'});

  final TransferProgress progress;

  /// Provider network id of the swap's destination, for the token badge.
  final String? swapChain;
  final String? transactionId;
  final VoidCallback? onDetails;
  final String detailsLabel;
  final VoidCallback? onCopyId;
  final VoidCallback? onRetry;
  final String retryLabel;

  Color get _toneColor => switch (progress.tone) {
        TransferTone.success => ZipherColors.green,
        TransferTone.failure => ZipherColors.red,
        TransferTone.warning => ZipherColors.warm,
        TransferTone.progress => ZipherColors.cyan,
      };

  Widget _stepIcon(TransferStepState state) => SizedBox(
      width: 16,
      height: 16,
      child: switch (state) {
        TransferStepState.done => const Icon(Icons.check_circle_rounded,
            size: 16, color: ZipherColors.green),
        TransferStepState.failed =>
          const Icon(Icons.error_rounded, size: 16, color: ZipherColors.red),
        TransferStepState.active => const Padding(
            padding: EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 1.6)),
        TransferStepState.pending => const Icon(Icons.circle_outlined,
            size: 16, color: ZipherColors.text20),
      });

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final steps = p.steps;
    final notice = p.notice;
    final id = transactionId;
    return Semantics(
        liveRegion: true,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                SizedBox(
                    width: p.isSwap ? 46 : 28,
                    height: 28,
                    child: Stack(children: [
                      const CurrencyIcon(symbol: 'ZEC', size: 28),
                      if (p.isSwap)
                        Positioned(
                            left: 18,
                            child: Container(
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: ZipherColors.cardBg, width: 2)),
                                child: CurrencyIcon(
                                    symbol: p.swapSymbol!,
                                    blockchain: swapChain,
                                    size: 24))),
                    ])),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(p.title,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: ZipherColors.textPrimary))),
                const SizedBox(width: 8),
                Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: _toneColor.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(ZipherRadius.full)),
                    child: Text(p.badge,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _toneColor))),
              ]),
              if (steps.isNotEmpty) const SizedBox(height: 12),
              for (final step in steps)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      _stepIcon(step.state),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(step.title,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: step.state == TransferStepState.pending
                                      ? ZipherColors.text40
                                      : step.state == TransferStepState.failed
                                          ? ZipherColors.red
                                          : ZipherColors.textSecondary))),
                    ])),
              if (notice != null)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(notice,
                        style: const TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: ZipherColors.textSecondary))),
              if (id != null || onDetails != null || onRetry != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                        spacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (onRetry != null)
                            TextButton(
                                onPressed: onRetry, child: Text(retryLabel)),
                          if (onDetails != null)
                            TextButton(
                                onPressed: onDetails,
                                child: Text(detailsLabel)),
                          if (id != null && onCopyId != null)
                            TextButton.icon(
                                onPressed: onCopyId,
                                icon: const Icon(Icons.copy_rounded, size: 14),
                                label: Text(
                                    'ID ${id.length > 12 ? '${id.substring(0, 6)}…${id.substring(id.length - 4)}' : id}')),
                        ])),
            ]));
  }
}
