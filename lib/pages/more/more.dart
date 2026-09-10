import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../services/wallet_service.dart';
import '../../init.dart';
import '../../zipher_theme.dart';
import '../../generated/intl/messages.dart';
import '../../src/version.dart';
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
                    GoRouter.of(context).push('/more/about', extra: content);
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
                  label: s.seedKeys,
                  subtitle: 'Back up your recovery phrase and keys',
                  onTap: () => _navSecured('/more/backup'),
                ),
                // Ironwood transfer: only show after NU6.3 activates
                if (_isIronwoodActive())
                  _SettingsItem(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Ironwood Transfer',
                    subtitle: 'Migrate Orchard funds to the new pool (ZIP 318)',
                    onTap: () => _nav('/more/ironwood'),
                  ),
                _SettingsItem(
                  icon: Icons.sync_rounded,
                  label: 'Recover Transactions',
                  subtitle: 'Re-sync if balance looks wrong',
                  onTap: () => GoRouter.of(context).push('/more/rescan'),
                ),
                _SettingsItem(
                  icon: Icons.group_rounded,
                  label: 'Shared Wallet',
                  subtitle: 'Create or join a FROST wallet',
                  onTap: () => GoRouter.of(context).push('/wallet/frost'),
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

              const Gap(24),
              Center(
                  child: Text('Zipher · v$packageVersion',
                      style: const TextStyle(
                          fontSize: 11, color: ZipherColors.text40))),
              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => ZipherWidgets.sectionLabel(text);

  Widget _card(List<_SettingsItem> items) {
    return ZipherWidgets.card(
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

  /// NU6.3 (Ironwood) activation heights.
  static const _ironwoodActivation = {
    'mainnet': 3428143, // July 28, 2026 ~8AM EST
    'testnet': 4134000,
  };

  bool _isIronwoodActive() {
    final network = isTestnet ? 'testnet' : 'mainnet';
    final activationHeight = _ironwoodActivation[network] ?? 0;
    final currentHeight = syncStatus2.latestHeight ?? 0;
    return currentHeight >= activationHeight;
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
      try {
        await ws.stopSync();
      } catch (_) {}
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
        try {
          await aa.updateBalance();
        } catch (_) {}
        aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
        await aa.save(prefs);
        if (mounted) {
          GoRouter.of(context).go('/account');
          Future.delayed(
              const Duration(milliseconds: 500), () => startAutoSync());
        }
      } else {
        if (mounted) GoRouter.of(context).go('/welcome');
      }
    } catch (e) {
      logger.e('Testnet toggle error: $e');
      // Revert the persisted flag so a cold restart doesn't strand the user
      // on a broken network.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('testnet', !enable);
      isTestnet = !enable;
      testnetNotifier.value = !enable;
      try {
        await initCoins();
      } catch (_) {}
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
  static const iconColor = ZipherColors.textSecondary;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _SettingsItem({
    required this.icon,
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
                  size: 18, color: ZipherColors.text10),
            ],
          ),
        ),
      ),
    );
  }
}
