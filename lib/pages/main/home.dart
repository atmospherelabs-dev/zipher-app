import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:warp_api/warp_api.dart';

import '../../generated/intl/messages.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../../accounts.dart';
import '../../zipher_theme.dart';
import '../accounts/send.dart';
import '../scan.dart';
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

class _HomeState extends State<HomePageInner> {
  bool _balanceHidden = false;

  @override
  void initState() {
    super.initState();
    syncStatus2.update();
    Future(marketPrice.update);
  }

  String _formatFiat(double x) => '\$${x.toStringAsFixed(2)}';

  Future<void> _onRefresh() async {
    if (syncStatus2.syncing) return;
    if (syncStatus2.paused) syncStatus2.setPause(false);
    syncStatus2.sync(false);
    await Future.delayed(const Duration(milliseconds: 800));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Observer(
        builder: (context) {
          aaSequence.seqno;
          aa.poolBalances;
          syncStatus2.changed;

          final totalBal = aa.poolBalances.transparent +
              aa.poolBalances.sapling +
              aa.poolBalances.orchard;
          final shieldedBal =
              aa.poolBalances.sapling + aa.poolBalances.orchard;
          final transparentBal = aa.poolBalances.transparent;

          final fiatPrice = marketPrice.price;
          final fiatBalance =
              fiatPrice != null ? totalBal * fiatPrice / ZECUNIT : null;
          final fiatStr =
              fiatBalance != null ? _formatFiat(fiatBalance) : null;

          final txs = aa.txs.items;
          final recentTxs = txs.length > 5 ? txs.sublist(0, 5) : txs;

          return RefreshIndicator(
            onRefresh: _onRefresh,
            color: ZipherColors.cyan,
            backgroundColor: ZipherColors.surface,
            child: Stack(
              children: [
                // Radial gradient glow behind balance (Jupiter-style)
                Positioned(
                  top: -80,
                  left: 0,
                  right: 0,
                  height: 380,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.0, -0.3),
                        radius: 1.2,
                        colors: [
                          ZipherColors.cyan.withValues(alpha: 0.08),
                          ZipherColors.purple.withValues(alpha: 0.03),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
                CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // Header: logo + "Main" … QR scan
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, topPad + 14, 20, 0),
                    child: Row(
                      children: [
                        // Zipher logo
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: ZipherColors.cyan.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Image.asset(
                              'assets/zipher_logo.png',
                              width: 20,
                              height: 20,
                            ),
                          ),
                        ),
                        const Gap(10),
                        Text(
                          'Main',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                        const Spacer(),
                        // QR scan shortcut
                        GestureDetector(
                          onTap: () => GoRouter.of(context).push(
                            '/scan',
                            extra: ScanQRContext((code) {
                              try {
                                final sc = SendContext.fromPaymentURI(code);
                                GoRouter.of(context).push(
                                  '/account/quick_send',
                                  extra: sc,
                                );
                              } catch (_) {
                                GoRouter.of(context).push(
                                  '/account/quick_send',
                                );
                              }
                              return true;
                            }),
                          ),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.qr_code_scanner_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Sync banner — only during active sync
                SliverToBoxAdapter(child: SyncStatusWidget()),

                // Balance area (tappable to toggle visibility)
                SliverToBoxAdapter(
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _balanceHidden = !_balanceHidden),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
                      child: Column(
                        children: [
                          // Balance display
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: 0.12),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Image.asset(
                                          'assets/zcash_logo.png',
                                          width: 24,
                                          height: 24,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                    ),
                                    const Gap(10),
                                    Text(
                                      amountToString2(totalBal),
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
                                color:
                                    Colors.white.withValues(alpha: 0.35),
                              ),
                            ),
                          ],
                          if (_balanceHidden) ...[
                            const Gap(6),
                            Text(
                              'Tap to reveal',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    Colors.white.withValues(alpha: 0.2),
                              ),
                            ),
                          ],

                          // Privacy meter — only when there are funds
                          if (totalBal > 0) ...[
                            const Gap(20),
                            _PrivacyMeter(
                              shielded: shieldedBal,
                              total: totalBal,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                // Action buttons
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.move_to_inbox_rounded,
                            label: 'Receive',
                            onTap: () => GoRouter.of(context)
                                .push('/account/pay_uri'),
                          ),
                        ),
                        const Gap(12),
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

                // Shield nudge — show when transparent > 0
                if (transparentBal > 0)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                      child: _ShieldNudge(
                        transparentBal: transparentBal,
                        onShield: () => _shield(transparentBal),
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
                    padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Recent Activity',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color:
                                Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                        if (recentTxs.isNotEmpty)
                          GestureDetector(
                            onTap: () =>
                                GoRouter.of(context).go('/history'),
                            child: Text(
                              'See all',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Colors.white
                                    .withValues(alpha: 0.3),
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
                      padding:
                          const EdgeInsets.fromLTRB(20, 12, 20, 32),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(vertical: 40),
                        decoration: BoxDecoration(
                          color:
                              Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.receipt_long_outlined,
                                size: 28,
                                color: Colors.white
                                    .withValues(alpha: 0.12)),
                            const Gap(8),
                            Text(
                              'No transactions yet',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.white
                                    .withValues(alpha: 0.2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding:
                        const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) =>
                            _TxRow(tx: recentTxs[index], index: index),
                        childCount: recentTxs.length,
                      ),
                    ),
                  ),
              ],
            ),
              ],
            ),
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

  void _shield(int transparentBal) async {
    final protectSend = appSettings.protectSend;
    if (protectSend) {
      final authed = await authBarrier(context, dismissable: true);
      if (!authed) return;
    }
    try {
      final plan = await WarpApi.transferPools(
        aa.coin,
        aa.id,
        0, // from: transparent
        2, // to: orchard (most private pool)
        transparentBal,
        false,
        'Auto-shield via Zipher',
        0,
        appSettings.anchorOffset,
        coinSettings.feeT,
      );
      if (!mounted) return;
      GoRouter.of(context).push('/account/txplan?tab=account', extra: plan);
    } on String catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e), duration: const Duration(seconds: 3)),
      );
    }
  }
}

// ─── Privacy meter ──────────────────────────────────────────

class _PrivacyMeter extends StatelessWidget {
  final int shielded;
  final int total;

  const _PrivacyMeter({required this.shielded, required this.total});

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? (shielded / total).clamp(0.0, 1.0) : 1.0;
    final pctInt = (pct * 100).round();

    // Color gradient: red (0%) → orange (50%) → purple (100%)
    final Color barColor;
    if (pct >= 0.8) {
      barColor = ZipherColors.purple;
    } else if (pct >= 0.5) {
      barColor = Color.lerp(ZipherColors.orange, ZipherColors.purple,
          (pct - 0.5) / 0.3)!;
    } else {
      barColor = Color.lerp(
          const Color(0xFFEF4444), ZipherColors.orange, pct / 0.5)!;
    }

    final String label;
    if (pctInt == 100) {
      label = 'Fully private';
    } else if (pctInt >= 80) {
      label = 'Mostly private';
    } else if (pctInt >= 50) {
      label = 'Partially exposed';
    } else {
      label = 'Low privacy';
    }

    return Column(
      children: [
        // Label row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  pctInt == 100 ? Icons.shield_rounded : Icons.shield_outlined,
                  size: 14,
                  color: barColor.withValues(alpha: 0.8),
                ),
                const Gap(6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: barColor.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
            Text(
              '$pctInt% shielded',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
        const Gap(6),
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 4,
            child: Stack(
              children: [
                // Background track
                Positioned.fill(
                  child: Container(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                // Fill bar
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: pct,
                  child: Container(
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Shield nudge banner ────────────────────────────────────

class _ShieldNudge extends StatelessWidget {
  final int transparentBal;
  final VoidCallback onShield;

  const _ShieldNudge({
    required this.transparentBal,
    required this.onShield,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onShield,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: ZipherColors.cyan.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: ZipherColors.cyan.withValues(alpha: 0.1),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.shield_rounded,
                  size: 16,
                  color: ZipherColors.cyan.withValues(alpha: 0.8),
                ),
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Shield your funds',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    const Gap(1),
                    Text(
                      '${amountToString2(transparentBal)} ZEC exposed on transparent',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Shield',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.cyan,
                  ),
                ),
              ),
            ],
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

// ─── Transaction row (home page — compact) ──────────────────

class _TxRow extends StatelessWidget {
  final Tx tx;
  final int index;
  const _TxRow({required this.tx, required this.index});

  @override
  Widget build(BuildContext context) {
    final isIncoming = tx.value > 0;
    final isShielding = tx.value <= 0 && (tx.address == null || tx.address!.isEmpty);
    final memo = tx.memo ?? '';
    final label = memo.isNotEmpty
        ? memo
        : isShielding
            ? 'Shielded'
            : isIncoming
                ? 'Received'
                : 'Sent';
    final timeStr = timeago.format(tx.timestamp);
    final amountStr = isShielding
        ? '${decimalToString(tx.value.abs())} ZEC'
        : '${isIncoming ? '+' : ''}${decimalToString(tx.value)} ZEC';
    final amountColor = isIncoming
        ? ZipherColors.green
        : isShielding
            ? ZipherColors.purple.withValues(alpha: 0.6)
            : Colors.white.withValues(alpha: 0.6);

    // Fiat
    final price = marketPrice.price;
    final fiat = price != null ? '\$${(tx.value.abs() * price).toStringAsFixed(2)}' : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => GoRouter.of(context).push('/history/details?index=$index'),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.04),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isShielding
                        ? Icons.shield_rounded
                        : isIncoming
                            ? Icons.south_west_rounded
                            : Icons.north_east_rounded,
                    size: 16,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
                const Gap(12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
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
                      amountStr,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: amountColor,
                      ),
                    ),
                    if (fiat.isNotEmpty && !isShielding) ...[
                      const Gap(1),
                      Text(
                        fiat,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                    ],
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
