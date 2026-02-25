import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../accounts.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../utils.dart';

enum _InboxFilter { all, messages, system }

class MemoInboxPage extends StatefulWidget {
  const MemoInboxPage({super.key});
  @override
  State<MemoInboxPage> createState() => _MemoInboxPageState();
}

class _MemoInboxPageState extends State<MemoInboxPage> {
  _InboxFilter _filter = _InboxFilter.all;

  List<ZMessage> get _allMemos {
    return aa.messages.items.where((m) {
      return m.fromAddress == null || m.fromAddress!.isEmpty;
    }).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  void _openTx(ZMessage msg) {
    final index = aa.txs.items.indexWhere((tx) => tx.id == msg.txId);
    if (index >= 0) {
      GoRouter.of(context).push('/more/history/details?index=$index');
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Column(
        children: [
          Gap(topPad + 14),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBgElevated,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.arrow_back_rounded, size: 18,
                        color: ZipherColors.text60),
                  ),
                ),
                const Gap(14),
                Icon(Icons.all_inbox_rounded, size: 18,
                    color: ZipherColors.text40),
                const Gap(10),
                Text('Memos', style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600,
                  color: ZipherColors.text90,
                )),
              ],
            ),
          ),
          const Gap(16),

          // Body
          Expanded(
            child: Observer(
              builder: (context) {
                aaSequence.seqno;
                syncStatus2.changed;
                final allMsgs = _allMemos;

                final msgs = allMsgs.where((m) {
                  final body = parseMemoBody(m.body);
                  switch (_filter) {
                    case _InboxFilter.all: return true;
                    case _InboxFilter.messages: return !_isSystemMemo(body);
                    case _InboxFilter.system: return _isSystemMemo(body);
                  }
                }).toList();

                final systemCount = allMsgs
                    .where((m) => _isSystemMemo(parseMemoBody(m.body))).length;
                final userCount = allMsgs.length - systemCount;

                return Column(
                  children: [
                    // Filter chips
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Row(
                        children: [
                          _FilterChip(
                            label: 'All (${allMsgs.length})',
                            selected: _filter == _InboxFilter.all,
                            onTap: () => setState(() => _filter = _InboxFilter.all),
                          ),
                          const Gap(8),
                          _FilterChip(
                            label: 'Messages ($userCount)',
                            selected: _filter == _InboxFilter.messages,
                            onTap: () => setState(() => _filter = _InboxFilter.messages),
                          ),
                          const Gap(8),
                          _FilterChip(
                            label: 'System ($systemCount)',
                            selected: _filter == _InboxFilter.system,
                            onTap: () => setState(() => _filter = _InboxFilter.system),
                          ),
                        ],
                      ),
                    ),

                    // Cards
                    Expanded(
                      child: msgs.isEmpty
                          ? _EmptyState(_filter)
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                              itemCount: msgs.length,
                              itemBuilder: (context, i) => _MemoCard(
                                message: msgs[i],
                                onViewTx: () => _openTx(msgs[i]),
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

bool _isSystemMemo(String body) {
  final lower = body.toLowerCase().trim();
  return lower.startsWith('auto-shield') ||
      lower.startsWith('sent from zipher') ||
      lower.startsWith('shielding') ||
      lower.startsWith('auto shield') ||
      lower.contains('via zipher');
}

// ─── Filter chip ─────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? ZipherColors.purple.withValues(alpha: 0.15)
              : ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? ZipherColors.purple.withValues(alpha: 0.3)
                : ZipherColors.borderSubtle,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? ZipherColors.purple.withValues(alpha: 0.8)
                : ZipherColors.text40,
          ),
        ),
      ),
    );
  }
}

// ─── Empty state ─────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final _InboxFilter filter;
  const _EmptyState(this.filter);

  @override
  Widget build(BuildContext context) {
    final String title;
    final String subtitle;
    final IconData icon;
    switch (filter) {
      case _InboxFilter.messages:
        title = 'No user messages';
        subtitle = 'Only system memos have been received';
        icon = Icons.mail_outline_rounded;
      case _InboxFilter.system:
        title = 'No system alerts';
        subtitle = 'Auto-shield and system memos appear here';
        icon = Icons.settings_rounded;
      case _InboxFilter.all:
        title = 'Inbox is empty';
        subtitle = 'Received memos will appear here';
        icon = Icons.all_inbox_rounded;
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: ZipherColors.cardBgElevated),
          const Gap(12),
          Text(title, style: TextStyle(
              fontSize: 14, color: ZipherColors.text20)),
          const Gap(4),
          Text(subtitle, style: TextStyle(
              fontSize: 12, color: ZipherColors.text10)),
        ],
      ),
    );
  }
}

// ─── Memo card ───────────────────────────────────────────

class _MemoCard extends StatelessWidget {
  final ZMessage message;
  final VoidCallback onViewTx;
  const _MemoCard({required this.message, required this.onViewTx});

  @override
  Widget build(BuildContext context) {
    final body = parseMemoBody(message.body);
    final isSystem = _isSystemMemo(body);
    final time = _formatTime(message.timestamp);
    final txHash = message.txId > 0
        ? aa.txs.items
            .where((tx) => tx.id == message.txId)
            .map((tx) => tx.fullTxId)
            .firstOrNull
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSystem
            ? ZipherColors.cardBg
            : ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(
            width: 3,
            color: isSystem
                ? ZipherColors.cardBgElevated
                : ZipherColors.purple.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isSystem
                        ? ZipherColors.cardBg
                        : ZipherColors.purple.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSystem ? Icons.settings_rounded : Icons.mail_rounded,
                        size: 10,
                        color: isSystem
                            ? ZipherColors.text20
                            : ZipherColors.purple.withValues(alpha: 0.5),
                      ),
                      const Gap(4),
                      Text(
                        isSystem ? 'System' : 'Memo',
                        style: TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: isSystem
                              ? ZipherColors.text20
                              : ZipherColors.purple.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(time, style: TextStyle(
                  fontSize: 10, color: ZipherColors.text20,
                )),
              ],
            ),
            const Gap(10),
            Text(
              body.isNotEmpty ? body : 'Empty memo',
              style: TextStyle(
                fontSize: 14, height: 1.5,
                color: isSystem
                    ? ZipherColors.text40
                    : ZipherColors.text90,
                fontStyle: isSystem ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            const Gap(10),
            Row(
              children: [
                _CardAction(
                  icon: Icons.copy_rounded, label: 'Copy',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: body));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: const Text('Memo copied'),
                      backgroundColor: ZipherColors.surface,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      duration: const Duration(seconds: 1),
                    ));
                  },
                ),
                const Gap(12),
                _CardAction(
                  icon: Icons.open_in_new_rounded, label: 'View Tx',
                  onTap: onViewTx,
                ),
                if (txHash != null && txHash.isNotEmpty) ...[
                  const Spacer(),
                  Text(
                    txHash.length > 12
                        ? '${txHash.substring(0, 6)}...${txHash.substring(txHash.length - 4)}'
                        : txHash,
                    style: TextStyle(
                      fontSize: 9, fontFamily: 'monospace',
                      color: ZipherColors.text10,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final t = dt.toLocal();
    final now = DateTime.now();
    final h = t.hour;
    final m = t.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    final time = '$hour:$m $period';
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return time;
    }
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month]} ${t.day}, $time';
  }
}

class _CardAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CardAction({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: ZipherColors.text20),
          const Gap(4),
          Text(label, style: TextStyle(
            fontSize: 11, color: ZipherColors.text20,
          )),
        ],
      ),
    );
  }
}
