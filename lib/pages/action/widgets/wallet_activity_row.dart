import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../zipher_theme.dart';
import '../../utils.dart' show Tx;

/// Leading glyph for an activity row: a tinted circle with a direction icon,
/// or any widget (a token logo for swaps).
class WalletActivityGlyph extends StatelessWidget {
  const WalletActivityGlyph(
      {super.key, required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
          color: color.withValues(alpha: .13), shape: BoxShape.circle),
      child: Icon(icon, size: 19, color: color));
}

/// Shared layout for transaction and swap rows: glyph, title over a quiet
/// subtitle, amount over an optional status. Status appears only when there
/// is something to know (pending, failed); settled rows stay calm.
class WalletActivityTile extends StatelessWidget {
  const WalletActivityTile(
      {super.key,
      required this.leading,
      required this.title,
      required this.subtitle,
      required this.amount,
      this.amountColor = ZipherColors.text90,
      this.detail,
      this.status,
      this.statusColor = ZipherColors.text40,
      this.memo,
      this.semanticLabel,
      required this.onTap});
  final Widget leading;
  final String title;
  final String subtitle;
  final String amount;
  final Color amountColor;

  /// Secondary amount under the main one, e.g. what a swap delivers.
  final String? detail;
  final String? status;
  final Color statusColor;

  /// Full memo text, shown under the title (memo inbox).
  final String? memo;
  final String? semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: ZipherSpacing.smMd, horizontal: ZipherSpacing.md),
              child: Row(children: [
                leading,
                const SizedBox(width: ZipherSpacing.smMd),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ZipherType.rowTitle),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ZipherType.footnote),
                      if (memo != null) ...[
                        const SizedBox(height: ZipherSpacing.sm),
                        Text(memo!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: ZipherType.subhead),
                      ],
                    ])),
                const SizedBox(width: ZipherSpacing.smMd),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(amount,
                      style: ZipherType.rowValue.copyWith(color: amountColor)),
                  if (detail != null || status != null) ...[
                    const SizedBox(height: 3),
                    Text(status ?? detail!,
                        style: ZipherType.footnote.copyWith(
                            color: status != null
                                ? statusColor
                                : ZipherColors.text40,
                            fontWeight: status != null
                                ? FontWeight.w500
                                : FontWeight.w400)),
                  ],
                ]),
              ]))));
}

/// One presentation for history in the Activity tab, chat, and memo inbox.
class WalletActivityRow extends StatelessWidget {
  const WalletActivityRow(
      {super.key,
      required this.transaction,
      required this.onTap,
      this.showMemo = false,
      this.timeOnly = false});
  final Tx transaction;
  final VoidCallback onTap;
  final bool showMemo;

  /// Under a day heading the date is already known; show only the time.
  final bool timeOnly;

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
            : null;
    final displayValue = !received && !internal && !feeOnly && tx.fee != null
        ? max(0.0, tx.value.abs() - tx.fee!)
        : tx.value.abs();
    final amount =
        displayValue.toStringAsFixed(8).replaceFirst(RegExp(r'\.?0+$'), '');
    final known = tx.timestamp.year > 1970;
    final when = !known
        ? 'Just now'
        : timeOnly
            ? DateFormat('HH:mm').format(tx.timestamp)
            : DateFormat('MMM d · HH:mm').format(tx.timestamp);
    final memo = tx.memo?.trim();
    final hasMemo = memo != null && memo.isNotEmpty;
    final amountText =
        '${internal || feeOnly ? 'Fee ' : received ? '+' : '−'}${amount.isEmpty ? '0' : amount} ZEC';
    return WalletActivityTile(
        onTap: onTap,
        semanticLabel:
            '$title, $amountText, ${status ?? 'Confirmed'}, $when${hasMemo ? ', with memo' : ''}',
        leading: WalletActivityGlyph(
            icon: internal
                ? Icons.shield_rounded
                : received
                    ? Icons.south_west_rounded
                    : Icons.north_east_rounded,
            color: internal
                ? ZipherColors.cyan
                : received
                    ? ZipherColors.positive
                    : ZipherColors.text60),
        title: title,
        subtitle: hasMemo && !showMemo ? '$when · “$memo”' : when,
        memo: showMemo && hasMemo ? memo : null,
        amount: amountText,
        amountColor: received && !pending
            ? ZipherColors.positive
            : tx.expiredUnmined
                ? ZipherColors.text40
                : ZipherColors.text90,
        status: status,
        statusColor:
            tx.expiredUnmined ? ZipherColors.negative : ZipherColors.pending);
  }
}
