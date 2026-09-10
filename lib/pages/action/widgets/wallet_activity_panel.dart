import 'package:flutter/material.dart';
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
      this.showTabs = true});
  final List<Tx> transactions;
  final List<WalletSwapActivity> swaps;
  final ValueChanged<String> onTransaction;
  final ValueChanged<String> onSwap;
  final Widget chat;
  final WalletHomeTab selectedTab;
  final ValueChanged<WalletHomeTab> onTabChanged;
  final bool showTabs;

  bool _pending(Tx tx) => tx.height == 0 && !tx.expiredUnmined;
  List<Tx> get _transactions {
    final deposits =
        swaps.map((entry) => entry.swap.txId).whereType<String>().toSet();
    return transactions.where((tx) => !deposits.contains(tx.fullTxId)).toList();
  }

  Widget _tab(String title, WalletHomeTab tab, {int count = 0}) {
    final selected = selectedTab == tab;
    return Semantics(
        selected: selected,
        button: true,
        child: TextButton(
            onPressed: () => onTabChanged(tab),
            style: TextButton.styleFrom(
                minimumSize: const Size(64, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: selected
                    ? ZipherColors.textPrimary
                    : ZipherColors.textSecondary,
                backgroundColor: Colors.transparent,
                shape: const RoundedRectangleBorder(),
                textStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color: selected
                                ? ZipherColors.cyan
                                : Colors.transparent,
                            width: 2))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(title),
                  if (count > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: ZipherColors.cyan.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(count > 99 ? '99+' : '$count',
                            style: const TextStyle(
                                color: ZipherColors.cyan, fontSize: 10))),
                  ],
                ]))));
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        if (showTabs)
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: ZipherColors.borderSubtle, width: .5))),
              child: Row(children: [
                Expanded(child: _tab('Chat', WalletHomeTab.chat)),
                Expanded(
                    child: _tab('Activity', WalletHomeTab.activity,
                        count: _transactions.where(_pending).length +
                            swaps.where((entry) => entry.isLive).length)),
              ])),
        Expanded(
            child: IndexedStack(index: selectedTab.index, children: [
          chat,
          _activity(),
        ])),
      ]);

  Widget _activity() {
    final pending = <({int time, Widget child})>[];
    final recent = <({int time, Widget child})>[];
    for (final tx in _transactions) {
      (_pending(tx) ? pending : recent).add((
        time: tx.timestamp.millisecondsSinceEpoch,
        child: WalletActivityRow(
            transaction: tx, onTap: () => onTransaction(tx.fullTxId))
      ));
    }
    for (final entry in swaps) {
      (entry.isLive ? pending : recent)
          .add((time: entry.swap.timestamp * 1000, child: _swapRow(entry)));
    }
    pending.sort((a, b) => b.time.compareTo(a.time));
    recent.sort((a, b) => b.time.compareTo(a.time));
    if (pending.isEmpty && recent.isEmpty) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No activity yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: ZipherColors.text40))));
    }
    final rows = <Widget>[
      if (pending.isNotEmpty) ...[
        _section('In progress'),
        ...pending.map((row) => row.child),
      ],
      if (recent.isNotEmpty) ...[
        if (pending.isNotEmpty) _section('Recent'),
        ...recent.map((row) => row.child),
      ],
    ];
    return ListView.builder(
        key: const PageStorageKey('wallet-activity'),
        primary: false,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        itemCount: rows.length,
        itemBuilder: (_, index) => rows[index]);
  }

  Widget _section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
      child: Text(title,
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ZipherColors.text40)));

  Widget _swapRow(WalletSwapActivity entry) => InkWell(
      onTap: () => onSwap(entry.swap.depositAddress),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
          child: Row(children: [
            const CircleAvatar(
                radius: 17,
                backgroundColor: ZipherColors.surfaceLight,
                child: Icon(Icons.swap_horiz_rounded,
                    size: 17, color: ZipherColors.cyan)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('${entry.swap.fromCurrency} → ${entry.swap.toCurrency}',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: ZipherColors.textPrimary)),
                  const SizedBox(height: 4),
                  Text('NEAR Intents · ${entry.label}',
                      style: TextStyle(
                          fontSize: 11,
                          color: entry.unavailable ||
                                  entry.status?.isFailed == true
                              ? ZipherColors.syncPending
                              : ZipherColors.text40)),
                  const SizedBox(height: 4),
                  Text('${entry.swap.fromAmount} ${entry.swap.fromCurrency}',
                      style: const TextStyle(
                          fontSize: 12, color: ZipherColors.textSecondary)),
                ])),
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: ZipherColors.text40),
          ])));
}
