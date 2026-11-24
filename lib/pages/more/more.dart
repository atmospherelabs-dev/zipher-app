import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../services/hitl_watch_service.dart';
import '../../services/network_mode.dart';
import '../../services/wallet_registry.dart';
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
              Gap(topPad + 16),

              // Title
              const Text('More', style: ZipherType.largeTitle),
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
                  icon: Icons.card_giftcard_rounded,
                  label: 'Gift ZEC',
                  subtitle: 'Send or claim a gift link',
                  onTap: () => GoRouter.of(context).push('/gifts'),
                ),
                _AgentItem(onTap: () => _nav('/hitl/agent')),
                _SettingsItem(
                  icon: Icons.tune_rounded,
                  label: 'Preferences',
                  subtitle: 'Currency, memo, server, sync',
                  onTap: () => GoRouter.of(context).push('/settings'),
                ),
                _SettingsItem(
                  icon: Icons.info_outline_rounded,
                  label: 'About Zipher',
                  subtitle: 'Version, links & terms',
                  onTap: () => GoRouter.of(context).push('/more/about'),
                ),
              ]),
              const Gap(20),

              // ── Security & Tools ──
              _sectionLabel('Security & Tools'),
              const Gap(8),
              _card([
                _SettingsItem(
                  icon: Icons.key_rounded,
                  label: 'Recovery phrase',
                  subtitle: 'Back up or view your wallet’s words',
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
              ZipherWidgets.card(child: _TestnetToggle()),
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

  Widget _card(List<Widget> items) => ZipherWidgets.group(items);

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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            ZipherWidgets.iconTile(Icons.science_outlined,
                color: ZipherColors.orange),
            const Gap(12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Testnet Mode', style: ZipherType.rowTitle),
                  const Gap(2),
                  Text(
                    isTestnet
                        ? 'Using Zcash testnet (TAZ)'
                        : 'Switch to testnet for testing',
                    style: ZipherType.footnote.copyWith(
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

    final ws = WalletService.instance;
    final activeId = ws.activeWalletId;
    final profile =
        activeId == null ? null : await WalletRegistry.instance.getById(activeId);
    // A shared (FROST) or watch-only wallet has no seed to create a wallet on
    // the other network from. Switching used to create a fresh single-signer
    // wallet under the shared wallet's name.
    if (profile != null &&
        profile.isWatchOnly &&
        !await ws.walletExists(walletId: profile.id, testnet: enable)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('This shared or watch-only wallet has no '
                'counterpart on the other network. Switch to a wallet with a '
                'recovery phrase first.')));
      }
      return;
    }

    setState(() => _switching = true);

    try {
      // 1. Stop the old network's sync loop and close its wallet, so no
      // refresh runs against the closed engine.
      syncStatus2.paused = true;
      syncTimer?.cancel();
      syncTimer = null;
      try {
        await ws.stopSync();
      } catch (_) {}
      if (ws.isWalletOpen) {
        await ws.closeWallet();
      }
      aa = nullAccount;
      aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;

      // 2. Switch the network flag, settings and price together.
      await applyNetworkMode(enable, reinitCoins: initCoins);
      syncStatus2.resetForWalletSwitch();

      // 3. Open or create the wallet for the target network.
      // switchWallet handles all cases: existing DB, seed-but-no-DB
      // (restores from seed), and no-seed-no-DB (creates fresh wallet).
      if (activeId != null) {
        await ws.switchWallet(activeId);
        await setActiveAccount(activeCoin.coin, 1);
        // The account object carries its network: a new one is needed, or
        // every refresh is skipped and the old network's address stays.
        final account = ActiveAccount2(
          coin: activeCoin.coin,
          id: 1,
          name: profile?.name ?? 'Main',
          address: '',
          canPay: !(profile?.isWatchOnly ?? false),
          walletId: activeId,
        );
        aa = account;
        aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
        try {
          await account.update(null);
        } catch (_) {
          // A fresh wallet may not have a balance yet; sync fills it in.
        }
        final prefs = await SharedPreferences.getInstance();
        await account.save(prefs);
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
      try {
        await applyNetworkMode(!enable, reinitCoins: initCoins);
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
  Widget build(BuildContext context) => ZipherWidgets.row(
      icon: icon, title: label, subtitle: subtitle, onTap: onTap);
}

/// Connected agent: shows who is paired, or how to pair one.
class _AgentItem extends StatelessWidget {
  final VoidCallback onTap;
  const _AgentItem({required this.onTap});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: HitlWatchService.instance.paired,
      builder: (_, paired, __) => ZipherWidgets.row(
          icon: Icons.smart_toy_rounded,
          iconColor: paired ? ZipherColors.cyan : ZipherColors.text60,
          title: 'Agent',
          subtitle: paired
              ? 'Paired · ${HitlWatchService.instance.agentName ?? 'your agent'}'
              : 'Approve payments from an AI agent',
          trailing: paired
              ? ZipherWidgets.statusDot(ZipherColors.positive)
              : null,
          onTap: onTap));
}
