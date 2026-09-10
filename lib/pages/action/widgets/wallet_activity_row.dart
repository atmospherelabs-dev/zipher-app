import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../zipher_theme.dart';
import '../../utils.dart' show Tx;

/// One presentation for history in the header, chat, and memo inbox.
class WalletActivityRow extends StatelessWidget {
  const WalletActivityRow(
      {super.key,
      required this.transaction,
      required this.onTap,
      this.showMemo = false});
  final Tx transaction;
  final VoidCallback onTap;
  final bool showMemo;

  @override
  Widget build(BuildContext context) {
    final tx = transaction;
    final internal =
        ['shield', 'shielding', 'send-to-self', 'migration'].contains(tx.kind);
    final received = tx.value > 0 && !internal;
    final pending = tx.height == 0 && !tx.expiredUnmined;
    final feeOnly = !internal &&
        !received &&
        tx.fee != null &&
        (tx.value.abs() * 1e8).round() == (tx.fee! * 1e8).round();
    final title = tx.kind == 'migration'
        ? 'Pool transfer'
        : internal
            ? 'Shielded'
            : feeOnly
                ? 'Transaction'
                : received
                    ? pending
                        ? 'Incoming'
                        : 'Received'
                    : pending
                        ? 'Sending'
                        : 'Sent';
    final status = tx.expiredUnmined
        ? 'Expired'
        : pending
            ? 'Confirming'
            : 'Confirmed';
    final displayValue = !received && !internal && !feeOnly && tx.fee != null
        ? max(0.0, tx.value.abs() - tx.fee!)
        : tx.value.abs();
    final amount =
        displayValue.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
    final date = tx.timestamp.year > 1970
        ? DateFormat('MMM d · HH:mm').format(tx.timestamp)
        : 'Just now';
    final memo = tx.memo?.trim();
    return Semantics(
        button: true,
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                              color: ZipherColors.surfaceLight,
                              shape: BoxShape.circle),
                          child: Icon(
                              internal
                                  ? Icons.shield_outlined
                                  : received
                                      ? Icons.south_west_rounded
                                      : Icons.north_east_rounded,
                              size: 16,
                              color: received
                                  ? ZipherColors.cyan
                                  : ZipherColors.textSecondary)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(title,
                                style: const TextStyle(
                                    color: ZipherColors.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500)),
                            const SizedBox(height: 4),
                            Text(date,
                                style: const TextStyle(
                                    color: ZipherColors.text40, fontSize: 11)),
                            if (showMemo &&
                                memo != null &&
                                memo.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(memo,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: ZipherColors.textSecondary,
                                      fontSize: 13,
                                      height: 1.45)),
                            ],
                          ])),
                      const SizedBox(width: 10),
                      Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                                '${internal || feeOnly ? 'Fee ' : received ? '+' : '−'}${amount.isEmpty ? '0' : amount} ZEC',
                                style: const TextStyle(
                                    color: ZipherColors.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500)),
                            const SizedBox(height: 4),
                            Text(status,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: tx.expiredUnmined
                                        ? ZipherColors.red
                                        : pending
                                            ? ZipherColors.syncPending
                                            : ZipherColors.text40)),
                            if (!showMemo &&
                                memo != null &&
                                memo.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              const Icon(Icons.chat_bubble_outline_rounded,
                                  size: 12, color: ZipherColors.text40),
                            ],
                          ]),
                    ]))));
  }
}
