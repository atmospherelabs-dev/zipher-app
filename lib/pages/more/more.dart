import 'dart:async';

import 'package:YWallet/appsettings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../accounts.dart';
import '../../zipher_theme.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../utils.dart';
import '../widgets.dart';

class MorePage extends StatefulWidget {
  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  bool _advancedExpanded = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(16),

              // ── Main Section ──────────────────────────
              _buildSectionLabel('Essentials'),
              const Gap(8),
              ZipherWidgets.surfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _MoreItem(
                      icon: Icons.key_rounded,
                      iconColor: ZipherColors.orange,
                      label: s.seedKeys,
                      subtitle: 'Export your seed phrase',
                      onTap: () => _navSecured('/more/backup'),
                    ),
                    _divider(),
                    if (aa.seed != null) ...[
                      _MoreItem(
                        icon: Icons.vpn_key_outlined,
                        iconColor: ZipherColors.purple,
                        label: s.keyTool,
                        subtitle: 'Export viewing key',
                        onTap: () => _navSecured('/more/keytool'),
                      ),
                      _divider(),
                    ],
                    _MoreItem(
                      icon: Icons.people_outline_rounded,
                      iconColor: ZipherColors.cyan,
                      label: s.contacts,
                      subtitle: 'Manage saved addresses',
                      onTap: () => _nav('/more/contacts'),
                    ),
                    _divider(),
                    _MoreItem(
                      icon: Icons.info_outline_rounded,
                      iconColor: ZipherColors.textSecondary,
                      label: s.about,
                      subtitle: 'Version & disclaimer',
                      onTap: () async {
                        final contentTemplate =
                            await rootBundle.loadString('assets/about.md');
                        if (!mounted) return;
                        GoRouter.of(context)
                            .push('/more/about', extra: contentTemplate);
                      },
                    ),
                  ],
                ),
              ),

              const Gap(24),

              // ── Advanced Section ──────────────────────
              GestureDetector(
                onTap: () =>
                    setState(() => _advancedExpanded = !_advancedExpanded),
                child: Row(
                  children: [
                    _buildSectionLabel('Advanced'),
                    const Gap(6),
                    Icon(
                      _advancedExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                      color: ZipherColors.textMuted,
                    ),
                  ],
                ),
              ),
              const Gap(8),

              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: _buildAdvancedSection(s),
                crossFadeState: _advancedExpanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
              ),

              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdvancedSection(S s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Accounts & Funds
        ZipherWidgets.surfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _MoreItem(
                icon: Icons.people_outline,
                iconColor: ZipherColors.textSecondary,
                label: s.accounts,
                onTap: () => _nav('/more/account_manager', isAccountManager: true),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.receipt_long_outlined,
                iconColor: ZipherColors.textSecondary,
                label: s.notes,
                subtitle: 'Coin control',
                onTap: () => _nav('/more/coins'),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.swap_horiz_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.pools,
                subtitle: 'Pool transfer',
                onTap: () => _nav('/more/transfer'),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.group_outlined,
                iconColor: ZipherColors.textSecondary,
                label: s.multiPay,
                onTap: () async {
                  if (appSettings.protectSend) {
                    final auth = await authenticate(context, s.secured);
                    if (!auth) return;
                  }
                  if (!mounted) return;
                  GoRouter.of(context).push('/account/multi_pay');
                },
              ),
            ],
          ),
        ),
        const Gap(12),

        // Data & Backup
        ZipherWidgets.surfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _MoreItem(
                icon: Icons.cloud_download_outlined,
                iconColor: ZipherColors.textSecondary,
                label: s.appData,
                subtitle: 'App data backup',
                onTap: () => _navSecured('/more/batch_backup'),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.show_chart_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.budget,
                onTap: () => _nav('/more/budget'),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.trending_up_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.marketPrice,
                onTap: () => _nav('/more/market'),
              ),
            ],
          ),
        ),
        const Gap(12),

        // Sync
        ZipherWidgets.surfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _MoreItem(
                icon: Icons.sync_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.rescan,
                onTap: () => _nav('/more/rescan'),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.history_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.rewind,
                onTap: () => _nav('/more/rewind'),
              ),
            ],
          ),
        ),
        const Gap(12),

        // Cold Storage & Tools
        ZipherWidgets.surfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _MoreItem(
                icon: Icons.edit_note_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.signOffline,
                subtitle: 'Cold storage signing',
                onTap: () => _nav('/more/cold/sign'),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.cell_tower_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.broadcast,
                onTap: () => _nav('/more/cold/broadcast'),
              ),
              _divider(),
              _MoreItem(
                icon: Icons.cleaning_services_rounded,
                iconColor: ZipherColors.textSecondary,
                label: s.sweep,
                onTap: () => _nav('/more/sweep'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: ZipherColors.textMuted,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _divider() {
    return const Divider(
      height: 1,
      color: ZipherColors.border,
      indent: 52,
      endIndent: 16,
    );
  }

  void _nav(String url, {bool isAccountManager = false}) async {
    final router = GoRouter.of(context);
    final res = await router.push(url);
    if (isAccountManager && res != null) {
      Timer(Durations.short1, () {
        router.go('/account');
      });
    }
  }

  void _navSecured(String url) async {
    final s = S.of(context);
    final auth = await authenticate(context, s.secured);
    if (!auth) return;
    if (!mounted) return;
    GoRouter.of(context).push(url);
  }
}

class _MoreItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _MoreItem({
    required this.icon,
    required this.iconColor,
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
                  borderRadius: BorderRadius.circular(ZipherRadius.sm),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: ZipherColors.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const Gap(1),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: ZipherColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: ZipherColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
