import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../generated/intl/messages.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../zipher_theme.dart';
import '../utils.dart';
import 'sync_status.dart';

class HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      final key = ValueKey(aaSequence.seqno);
      return HomePageInner(key: key);
    });
  }
}

class HomePageInner extends StatefulWidget {
  HomePageInner({super.key});
  @override
  State<StatefulWidget> createState() => _HomeState();
}

class _HomeState extends State<HomePageInner>
    with SingleTickerProviderStateMixin {
  bool _balanceHidden = false;
  int _poolTab = 0; // 0=All, 1=Shielded, 2=Transparent
  late final AnimationController _syncSpinController;

  @override
  void initState() {
    super.initState();
    _syncSpinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    syncStatus2.update();
    Future(marketPrice.update);
  }

  @override
  void dispose() {
    _syncSpinController.dispose();
    super.dispose();
  }

  String _formatFiat(double x) =>
      decimalFormat(x, 2, symbol: appSettings.currency);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Observer(
        builder: (context) {
          aaSequence.seqno;
          aa.poolBalances;
          syncStatus2.changed;

          // Drive sync spin animation
          if (syncStatus2.syncing) {
            if (!_syncSpinController.isAnimating) _syncSpinController.repeat();
          } else {
            if (_syncSpinController.isAnimating) _syncSpinController.stop();
          }

          final totalBal = aa.poolBalances.transparent +
              aa.poolBalances.sapling +
              aa.poolBalances.orchard;
          final shieldedBal =
              aa.poolBalances.sapling + aa.poolBalances.orchard;
          final transparentBal = aa.poolBalances.transparent;

          // Pick balance based on selected tab
          final displayBal = _poolTab == 0
              ? totalBal
              : _poolTab == 1
                  ? shieldedBal
                  : transparentBal;

          final fiatPrice = marketPrice.price;
          final fiatBalance =
              fiatPrice != null ? displayBal * fiatPrice / ZECUNIT : null;
          final fiatStr =
              fiatBalance != null ? _formatFiat(fiatBalance) : null;

          final txs = aa.txs.items;
          final recentTxs = txs.length > 5 ? txs.sublist(0, 5) : txs;

          return CustomScrollView(
            slivers: [
              // Sync — only during active sync or disconnect
              SliverToBoxAdapter(child: SyncStatusWidget()),

              // Balance area
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  child: Column(
                    children: [
                      // Utility row: eye (left) + sync (right)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          GestureDetector(
                            onTap: () => setState(
                                () => _balanceHidden = !_balanceHidden),
                            child: Icon(
                              _balanceHidden
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 20,
                              color: Colors.white.withValues(alpha: 0.3),
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              if (syncStatus2.syncing) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Already syncing...'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              } else {
                                if (syncStatus2.paused)
                                  syncStatus2.setPause(false);
                                Future(() => syncStatus2.sync(false));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Syncing...'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            },
                            child: RotationTransition(
                              turns: Tween(begin: 0.0, end: 1.0)
                                  .animate(_syncSpinController),
                              child: Icon(
                                Icons.sync_rounded,
                                size: 20,
                                color: syncStatus2.syncing
                                    ? ZipherColors.cyan
                                        .withValues(alpha: 0.6)
                                    : Colors.white
                                        .withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const Gap(20),

                      // Balance display with ZEC icon inline
                      _balanceHidden
                          ? const Text(
                              '••••••',
                              style: TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: 4,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // ZEC icon inline, white-on-transparent
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color:
                                        Colors.white.withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Image.asset(
                                        'assets/zcash_small.png',
                                        width: 20,
                                        height: 20,
                                        color: Colors.white,
                                        colorBlendMode: BlendMode.srcIn),
                                  ),
                                ),
                                const Gap(10),
                                Text(
                                  amountToString2(displayBal),
                                  style: const TextStyle(
                                    fontSize: 38,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                    letterSpacing: -1,
                                  ),
                                ),
                                const Gap(8),
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    'ZEC',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white
                                          .withValues(alpha: 0.35),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                      // Fiat value
                      if (fiatStr != null && !_balanceHidden) ...[
                        const Gap(4),
                        Text(
                          fiatStr,
                          style: TextStyle(
                            fontSize: 15,
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                        ),
                      ],
                      if (_balanceHidden) ...[
                        const Gap(6),
                        Text(
                          'Tap eye to reveal',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                      ],

                      const Gap(20),

                      // Pool tabs: All / Shielded / Transparent
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            _PoolTab(
                              label: 'All',
                              active: _poolTab == 0,
                              onTap: () => setState(() => _poolTab = 0),
                            ),
                            _PoolTab(
                              label: 'Shielded',
                              active: _poolTab == 1,
                              onTap: () => setState(() => _poolTab = 1),
                            ),
                            _PoolTab(
                              label: 'Transparent',
                              active: _poolTab == 2,
                              onTap: () => setState(() => _poolTab = 2),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Action buttons — rounded rectangles
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.move_to_inbox_rounded,
                          label: 'Receive',
                          onTap: () =>
                              GoRouter.of(context).push('/account/pay_uri'),
                        ),
                      ),
                      const Gap(10),
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.swap_horiz_rounded,
                          label: 'Swap',
                          onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Swap coming soon'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                      ),
                      const Gap(10),
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.send_rounded,
                          label: 'Send',
                          onTap: () => _send(false),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Backup warning
              if (!aa.saved)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: _buildBackupReminder(s),
                  ),
                ),

              // Activity header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Activity',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                      if (recentTxs.isNotEmpty)
                        GestureDetector(
                          onTap: () => GoRouter.of(context).go('/history'),
                          child: Text(
                            'See all',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // Transaction list or empty state
              if (recentTxs.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.receipt_long_outlined,
                              size: 28,
                              color: Colors.white.withValues(alpha: 0.12)),
                          const Gap(8),
                          Text(
                            'No transactions yet',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _TxRow(tx: recentTxs[index]),
                      childCount: recentTxs.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBackupReminder(S s) {
    return GestureDetector(
      onTap: _backup,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: ZipherColors.orange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.shield_outlined,
                size: 18,
                color: ZipherColors.orange.withValues(alpha: 0.8)),
            const Gap(12),
            Expanded(
              child: Text(
                'Back up your wallet',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.orange.withValues(alpha: 0.9),
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 18,
                color: ZipherColors.orange.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  void _send(bool custom) async {
    final protectSend = appSettings.protectSend;
    if (protectSend) {
      final authed = await authBarrier(context, dismissable: true);
      if (!authed) return;
    }
    final c = custom ? 1 : 0;
    GoRouter.of(context).push('/account/quick_send?custom=$c');
  }

  void _backup() {
    GoRouter.of(context).push('/more/backup');
  }
}

// ─── Pool tab pill ──────────────────────────────────────────

class _PoolTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _PoolTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active
                    ? Colors.white.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Action button (rounded rectangle) ──────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.8)),
              const Gap(8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Transaction row ────────────────────────────────────────

class _TxRow extends StatelessWidget {
  final Tx tx;
  const _TxRow({required this.tx});

  @override
  Widget build(BuildContext context) {
    final isIncoming = tx.value > 0;
    final icon =
        isIncoming ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded;
    final sign = isIncoming ? '+' : '';
    final memo = tx.memo ?? tx.contact ?? '';
    final timeStr = timeago.format(tx.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {},
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.5)),
                ),
                const Gap(14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        memo.isNotEmpty
                            ? memo
                            : (isIncoming ? 'Received' : 'Sent'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                      const Gap(2),
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$sign${decimalFormat(tx.value.abs(), 5)}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isIncoming
                            ? Colors.white.withValues(alpha: 0.9)
                            : Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                    const Gap(2),
                    Text(
                      'ZEC',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
