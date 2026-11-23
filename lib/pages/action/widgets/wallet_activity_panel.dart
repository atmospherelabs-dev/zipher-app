import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../services/near_intents.dart' show CurrencyIcon;
import '../../../services/wallet_swap_tracker.dart';
import '../../../zipher_theme.dart';
import '../../utils.dart' show Tx;
import 'wallet_activity_row.dart';

enum WalletHomeTab { chat, activity }

/// Mutually exclusive home views. Keeping each child mounted preserves drafts
/// and scroll positions without exposing chat controls in activity views.
class WalletActivityPanel extends StatelessWidget {
  const WalletActivityPanel(
      {super.key,
      required this.transactions,
      required this.swaps,
      required this.onTransaction,
      required this.onSwap,
      required this.chat,
      required this.selectedTab,
      required this.onTabChanged,
      this.now});
  final List<Tx> transactions;
  final List<WalletSwapActivity> swaps;
  final ValueChanged<String> onTransaction;
  final ValueChanged<String> onSwap;
  final Widget chat;
  final WalletHomeTab selectedTab;
  final ValueChanged<WalletHomeTab> onTabChanged;

  /// Clock for day headings; the device clock unless a test supplies one.
  final DateTime Function()? now;

  static bool _pending(Tx tx) => tx.height == 0 && !tx.expiredUnmined;

  /// Transactions minus swap deposits, which their swap row represents.
  static List<Tx> _withoutDeposits(
      List<Tx> transactions, List<WalletSwapActivity> swaps) {
    final deposits =
        swaps.map((entry) => entry.swap.txId).whereType<String>().toSet();
    return transactions.where((tx) => !deposits.contains(tx.fullTxId)).toList();
  }

  List<Tx> get _transactions => _withoutDeposits(transactions, swaps);

  /// Items still in progress, for the badge on the home Activity button.
  static int pendingCount(
          List<Tx> transactions, List<WalletSwapActivity> swaps) =>
      _withoutDeposits(transactions, swaps).where(_pending).length +
      swaps.where((entry) => entry.isLive).length;

  /// No switcher: the home header's Activity button selects the view, and
  /// Activity has its own title with Done to go back to the conversation.
  @override
  Widget build(BuildContext context) =>
      IndexedStack(index: selectedTab.index, children: [
        chat,
        Column(children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZipherSpacing.md + ZipherSpacing.xs, ZipherSpacing.xs,
                  ZipherSpacing.sm, 0),
              child: Row(children: [
                const Expanded(
                    child: Text('Activity', style: ZipherType.title)),
                ZipherButton(
                    label: 'Done',
                    kind: ZipherButtonKind.plain,
                    size: ZipherButtonSize.small,
                    onPressed: () => onTabChanged(WalletHomeTab.chat)),
              ])),
          Expanded(child: _activity()),
        ]),
      ]);

  /// Day heading: Today, Yesterday, a weekday this week, else the date.
  String _day(DateTime at, DateTime today) {
    final day = DateTime(at.year, at.month, at.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return DateFormat('EEEE').format(at);
    if (at.year == today.year) return DateFormat('EEEE, MMM d').format(at);
    return DateFormat('MMM d, y').format(at);
  }

  Widget _activity() {
    final clock = (now ?? DateTime.now)();
    final today = DateTime(clock.year, clock.month, clock.day);
    final pending = <({DateTime time, Widget child})>[];
    final settled = <({DateTime time, Widget child})>[];
    for (final tx in _transactions) {
      final live = _pending(tx);
      (live ? pending : settled).add((
        time: tx.timestamp,
        child: WalletActivityRow(
            transaction: tx,
            timeOnly: !live,
            onTap: () => onTransaction(tx.fullTxId))
      ));
    }
    for (final entry in swaps) {
      final time =
          DateTime.fromMillisecondsSinceEpoch(entry.swap.timestamp * 1000);
      (entry.isLive ? pending : settled)
          .add((time: time, child: _swapRow(entry, timeOnly: !entry.isLive)));
    }
    if (pending.isEmpty && settled.isEmpty) return _empty();
    pending.sort((a, b) => b.time.compareTo(a.time));
    settled.sort((a, b) => b.time.compareTo(a.time));

    final sections = <(String, List<Widget>)>[];
    if (pending.isNotEmpty) {
      sections.add(('In progress', pending.map((r) => r.child).toList()));
    }
    for (final row in settled) {
      final title = row.time.year > 1970 ? _day(row.time, today) : 'Recent';
      if (sections.isEmpty || sections.last.$1 != title) {
        sections.add((title, []));
      }
      sections.last.$2.add(row.child);
    }
    return ListView.builder(
        key: const PageStorageKey('wallet-activity'),
        primary: false,
        padding: const EdgeInsets.fromLTRB(
            ZipherSpacing.md, 0, ZipherSpacing.md, ZipherSpacing.lg),
        itemCount: sections.length,
        itemBuilder: (_, index) {
          final (title, rows) = sections[index];
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(ZipherSpacing.xs,
                        ZipherSpacing.md, ZipherSpacing.xs, ZipherSpacing.sm),
                    child: Text(title, style: ZipherType.section)),
                ZipherWidgets.group(rows, inset: 68),
              ]);
        });
  }

  Widget _empty() => const Center(
      child: Padding(
          padding: EdgeInsets.all(ZipherSpacing.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            WalletActivityGlyph(
                icon: Icons.receipt_long_rounded, color: ZipherColors.text40),
            SizedBox(height: ZipherSpacing.smMd),
            Text('No activity yet', style: ZipherType.headline),
            SizedBox(height: ZipherSpacing.xs),
            Text('Payments and swaps will appear here.',
                textAlign: TextAlign.center, style: ZipherType.footnote),
          ])));

  Widget _swapRow(WalletSwapActivity entry, {bool timeOnly = false}) {
    final swap = entry.swap;
    final status = entry.status;
    final problem = entry.unavailable ||
        status?.isFailed == true ||
        status?.isRefunded == true ||
        entry.neverFunded;
    final done = status?.isSuccess == true;
    final at = DateTime.fromMillisecondsSinceEpoch(swap.timestamp * 1000);
    final when = timeOnly
        ? DateFormat('HH:mm').format(at)
        : DateFormat('MMM d · HH:mm').format(at);
    return WalletActivityTile(
        onTap: () => onSwap(swap.depositAddress),
        semanticLabel:
            'Swap ${swap.fromCurrency} to ${swap.toCurrency}, ${entry.label}',
        leading: SizedBox(
            width: 40,
            height: 40,
            child: CurrencyIcon(
                symbol: swap.toCurrency,
                blockchain: swap.toBlockchain,
                size: 40)),
        title: '${swap.fromCurrency} → ${swap.toCurrency}',
        subtitle: 'Swap · $when',
        amount: '−${swap.fromAmount} ${swap.fromCurrency}',
        // The stored amount is the provider's quote, not a delivered figure.
        detail: '≈ ${swap.toAmount} ${swap.toCurrency}',
        status: done ? null : entry.label,
        statusColor: problem ? ZipherColors.negative : ZipherColors.pending);
  }
}
