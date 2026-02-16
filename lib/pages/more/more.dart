import 'dart:async';

import 'package:YWallet/appsettings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../accounts.dart';
import '../../zipher_theme.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../src/version.dart';
import '../utils.dart';

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
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              const Gap(24),

              // ── General ──
              _sectionLabel('General'),
              const Gap(8),
              _card([
                _SettingsItem(
                  icon: Icons.tune_rounded,
                  label: 'Preferences',
                  subtitle: 'Currency, memo, server, sync',
                  onTap: () => GoRouter.of(context).push('/settings'),
                ),
                _SettingsItem(
                  icon: Icons.people_outline_rounded,
                  iconColor: ZipherColors.cyan,
                  label: s.contacts,
                  subtitle: 'Manage saved addresses',
                  onTap: () => _nav('/more/contacts'),
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
                  icon: Icons.key_rounded,
                  iconColor: ZipherColors.orange,
                  label: s.seedKeys,
                  subtitle: 'Export seed phrase & keys',
                  onTap: () => _navSecured('/more/backup'),
                ),
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

              // ── Danger Zone ──
              _sectionLabel('Danger Zone'),
              const Gap(8),
              _card([
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
                        color: Colors.white.withValues(alpha: 0.12),
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
                        color: Colors.white.withValues(alpha: 0.06),
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
        color: Colors.white.withValues(alpha: 0.25),
      ),
    );
  }

  Widget _card(List<_SettingsItem> items) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            items[i],
            if (i < items.length - 1)
              Divider(
                height: 1,
                color: Colors.white.withValues(alpha: 0.04),
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
    final s = S.of(context);
    final confirm1 = await showConfirmDialog(
      context,
      'Reset App',
      'This will delete ALL accounts, keys, and settings. '
          'Make sure you have backed up your seed phrase before continuing.',
    );
    if (!confirm1) return;

    final confirm2 = await showConfirmDialog(
      context,
      'Are you sure?',
      'This action is permanent and cannot be undone. '
          'All your data will be erased.',
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

class _SettingsItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _SettingsItem({
    required this.icon,
    this.iconColor = const Color(0x66FFFFFF),
    required this.label,
    this.subtitle,
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
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: iconColor),
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const Gap(1),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.12)),
            ],
          ),
        ),
      ),
    );
  }
}
