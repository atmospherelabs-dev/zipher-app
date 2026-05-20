import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../accounts.dart';
import '../../services/wallet_service.dart';
import '../../init.dart';
import '../../zipher_theme.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../src/version.dart';
import '../settings.dart';
import '../../settings.pb.dart';
import '../utils.dart';
import '../../store2.dart';

// ═══════════════════════════════════════════════════════════
// SETTINGS HUB (bottom tab)
// ═══════════════════════════════════════════════════════════

class MorePage extends StatefulWidget {
  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Gap(topPad + 20),

              // Title
              Text(
                'More',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: ZipherColors.text90,
                ),
              ),
              const Gap(24),

              // ── General ──
              _sectionLabel('General'),
              const Gap(8),
              _card([
                _SettingsItem(
                  icon: Icons.bolt_rounded,
                  label: 'Action',
                  subtitle: 'Command your wallet with text',
                  badge: 'BETA',
                  onTap: () => _nav('/account/action'),
                ),
                _SettingsItem(
                  icon: Icons.receipt_long_rounded,
                  label: 'Activity',
                  subtitle: 'Full transaction history',
                  onTap: () => _nav('/more/history'),
                ),
                _SettingsItem(
                  icon: Icons.all_inbox_rounded,
                  label: 'Memos',
                  subtitle: 'Received transaction memos',
                  onTap: () => _nav('/more/memos'),
                ),
                _SettingsItem(
                  icon: Icons.people_outline_rounded,
                  label: s.contacts,
                  subtitle: 'Manage saved addresses',
                  onTap: () => _nav('/more/contacts'),
                ),
                _SettingsItem(
                  icon: Icons.tune_rounded,
                  label: 'Preferences',
                  subtitle: 'Currency, memo, server, sync',
                  onTap: () => GoRouter.of(context).push('/settings'),
                ),
                _SettingsItem(
                  icon: Icons.info_outline_rounded,
                  label: 'About Zipher',
                  subtitle: 'Version & disclaimer',
                  onTap: () async {
                    final content =
                        await rootBundle.loadString('assets/about.md');
                    if (!mounted) return;
                    GoRouter.of(context)
                        .push('/more/about', extra: content);
                  },
                ),
              ]),
              const Gap(20),

              // ── Security & Tools ──
              _sectionLabel('Security & Tools'),
              const Gap(8),
              _card([
                _SettingsItem(
                  icon: Icons.cleaning_services_outlined,
                  label: s.sweep,
                  subtitle: 'Import funds from a key',
                  onTap: () => GoRouter.of(context).push('/more/sweep'),
                ),
                _SettingsItem(
                  icon: Icons.sync_rounded,
                  label: 'Recover Transactions',
                  subtitle: 'Re-sync if balance looks wrong',
                  onTap: () => GoRouter.of(context).push('/more/rescan'),
                ),
                _SettingsItem(
                  icon: Icons.cloud_download_outlined,
                  label: s.appData,
                  subtitle: 'Backup & restore app data',
                  onTap: () => _navSecured('/more/batch_backup'),
                ),
              ]),
              const Gap(20),

              // ── Developer ──
              _sectionLabel('Developer'),
              const Gap(8),
              _card([
                _SettingsItem(
                  icon: Icons.terminal_rounded,
                  label: 'Debug Log',
                  subtitle: 'Live sync & engine log',
                  onTap: () => _nav('/more/debug_log'),
                ),
              ]),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.cardBg,
                  borderRadius: BorderRadius.circular(ZipherRadius.lg),
                  border: Border.all(
                    color: ZipherColors.borderSubtle,
                  ),
                ),
                child: _TestnetToggle(),
              ),
              const Gap(20),

              // ── Danger Zone ──
              _sectionLabel('Danger Zone'),
              const Gap(8),
              _card([
                _SettingsItem(
                  icon: Icons.key_rounded,
                  iconColor: ZipherColors.orange,
                  label: s.seedKeys,
                  subtitle: 'Export seed phrase & keys',
                  onTap: () => _navSecured('/more/backup'),
                ),
                _SettingsItem(
                  icon: Icons.restart_alt_rounded,
                  iconColor: ZipherColors.red,
                  label: 'Reset App',
                  subtitle: 'Delete all data and start fresh',
                  onTap: () => _resetApp(),
                ),
              ]),

              // Version footer
              const Gap(40),
              Center(
                child: Column(
                  children: [
                    Image.asset(
                      'assets/zipher_logo.png',
                      width: 28,
                      height: 28,
                      opacity: const AlwaysStoppedAnimation(0.15),
                    ),
                    const Gap(8),
                    Text(
                      'Zipher',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: ZipherColors.text10,
                      ),
                    ),
                    const Gap(2),
                    Text(
                      'by CipherScan',
                      style: TextStyle(
                        fontSize: 11,
                        color: ZipherColors.cyan.withValues(alpha: 0.12),
                      ),
                    ),
                    const Gap(2),
                    Text(
                      'v$packageVersion',
                      style: TextStyle(
                        fontSize: 10,
                        color: ZipherColors.text40,
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: ZipherColors.text40,
      ),
    );
  }

  Widget _card(List<_SettingsItem> items) {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(
          color: ZipherColors.borderSubtle,
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            items[i],
            if (i < items.length - 1)
              Divider(
                height: 1,
                color: ZipherColors.cardBg,
                indent: 52,
                endIndent: 16,
              ),
          ],
        ],
      ),
    );
  }

  void _nav(String url) async {
    await GoRouter.of(context).push(url);
  }

  void _navSecured(String url) async {
    final s = S.of(context);
    final auth = await authenticate(context, s.secured);
    if (!auth) return;
    if (mounted) GoRouter.of(context).push(url);
  }

  void _resetApp() async {
    final confirm1 = await showConfirmDialog(
      context,
      'Reset App',
      'This will delete ALL accounts, keys, and settings. '
          'Make sure you have backed up your seed phrase before continuing.',
      isDanger: true,
    );
    if (!confirm1) return;

    final confirm2 = await showConfirmDialog(
      context,
      'Are you sure?',
      'This action is permanent and cannot be undone. '
          'All your data will be erased.',
      isDanger: true,
    );
    if (!confirm2) return;

    try {
      for (final c in coins) {
        await c.delete();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}

    if (mounted) GoRouter.of(context).go('/welcome');
  }
}


// ═══════════════════════════════════════════════════════════
// SETTINGS ITEM WIDGET
// ═══════════════════════════════════════════════════════════

class _TestnetToggle extends StatefulWidget {
  @override
  State<_TestnetToggle> createState() => _TestnetToggleState();
}

class _TestnetToggleState extends State<_TestnetToggle> {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: ZipherColors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(ZipherRadius.sm),
              ),
              child: Icon(Icons.science_outlined,
                  size: 16, color: ZipherColors.orange),
            ),
            const Gap(12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Testnet Mode',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: ZipherColors.text90,
                    ),
                  ),
                  const Gap(1),
                  Text(
                    isTestnet
                        ? 'Using Zcash testnet (TAZ)'
                        : 'Switch to testnet for testing',
                    style: TextStyle(
                      fontSize: 11,
                      color: isTestnet
                          ? ZipherColors.orange.withValues(alpha: 0.7)
                          : ZipherColors.text40,
                    ),
                  ),
                ],
              ),
            ),
            _switching
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ZipherColors.orange,
                    ),
                  )
                : Switch.adaptive(
                    value: isTestnet,
                    activeTrackColor: ZipherColors.orange,
                    onChanged: (v) => _toggleTestnet(v),
                  ),
          ],
        ),
      ),
    );
  }

  bool _switching = false;

  void _toggleTestnet(bool enable) async {
    final confirmed = await showConfirmDialog(
      context,
      '${enable ? "Enable" : "Disable"} Testnet',
      enable
          ? 'Switch to Zcash testnet. Testnet coins (TAZ) have no real value. '
              'Your mainnet wallet is preserved.'
          : 'Switch back to mainnet. Your testnet data is preserved.',
    );
    if (!confirmed) return;

    setState(() => _switching = true);

    try {
      final ws = WalletService.instance;
      final activeId = ws.activeWalletId;

      // 1. Always stop sync and close the current wallet first
      try { await ws.stopSync(); } catch (_) {}
      if (ws.isWalletOpen) {
        await ws.closeWallet();
      }

      // 2. Switch the network flag
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('testnet', enable);
      isTestnet = enable;
      testnetNotifier.value = enable;
      await initCoins();
      syncStatus2.resetForWalletSwitch();
      aa.reset(0);
      aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;

      // 3. Open or create the wallet for the target network.
      // switchWallet handles all cases: existing DB, seed-but-no-DB
      // (restores from seed), and no-seed-no-DB (creates fresh wallet).
      bool opened = false;
      if (activeId != null) {
        await ws.switchWallet(activeId);
        opened = true;
      }

      if (opened) {
        setActiveAccount(activeCoin.coin, 1);
        await aa.updateAddress();
        // Balance may not be available yet on a freshly created wallet;
        // sync will update it once blocks are scanned.
        try { await aa.updateBalance(); } catch (_) {}
        aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
        await aa.save(prefs);
        if (mounted) {
          GoRouter.of(context).go('/account');
          Future.delayed(const Duration(milliseconds: 500), () => startAutoSync());
        }
      } else {
        if (mounted) GoRouter.of(context).go('/welcome');
      }
    } catch (e) {
      logger.e('Testnet toggle error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error switching network: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }
}

class _SettingsItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? subtitle;
  final String? badge;
  final VoidCallback onTap;

  const _SettingsItem({
    required this.icon,
    this.iconColor = const Color(0x66FFFFFF),
    required this.label,
    this.subtitle,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(ZipherRadius.sm),
                ),
                child: Icon(icon, size: 16, color: iconColor),
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: ZipherColors.text90,
                          ),
                        ),
                        if (badge != null) ...[
                          const Gap(6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ZipherColors.cyan.withValues(alpha: 0.12),
                              borderRadius:
                                  BorderRadius.circular(ZipherRadius.xs),
                            ),
                            child: Text(
                              badge!,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: ZipherColors.cyan.withValues(alpha: 0.8),
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (subtitle != null) ...[
                      const Gap(1),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 11,
                          color: ZipherColors.text40,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18,
                  color: ZipherColors.text10),
            ],
          ),
        ),
      ),
    );
  }
}
