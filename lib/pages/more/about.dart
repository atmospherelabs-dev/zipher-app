import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../accounts.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_registry.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';

import '../../zipher_theme.dart';
import '../../src/version.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../utils.dart';

class AboutPage extends StatelessWidget {
  final String contentTemplate;
  AboutPage(this.contentTemplate);

  @override
  Widget build(BuildContext context) {
    final id = commitId.substring(0, 8);

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'About',
          style: ZipherType.headline,
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              size: 20, color: ZipherColors.text90),
          onPressed: () => GoRouter.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            // Logo + branding
            const Gap(16),
            Image.asset(
              'assets/zipher_logo.png',
              width: 56,
              height: 56,
              opacity: const AlwaysStoppedAnimation(0.8),
            ),
            const Gap(12),
            Text(
              'Zipher',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: ZipherColors.text90,
              ),
            ),
            const Gap(4),
            Text(
              'by Atmosphere Labs',
              style: TextStyle(
                fontSize: 13,
                color: ZipherColors.cyan.withValues(alpha: 0.7),
              ),
            ),
            const Gap(4),
            GestureDetector(
              onTap: () => _openUrl('https://github.com/atmospherelabs-dev/zipher-app/commit/$commitId'),
              child: Text(
                'v$packageVersion ($id)',
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text40,
                ),
              ),
            ),

            const Gap(36),

            // ── Privacy ──
            _InfoCard(
              icon: Icons.shield_rounded,
              iconColor: ZipherColors.purple,
              title: 'Your Privacy',
              items: [
                'Zipher does not collect any data. It has no servers of its own.',
                'Connects to public lightwalletd nodes for blockchain data and CoinGecko for prices.',
                'Your IP may be visible to your ISP. Use a VPN or Tor for extra privacy.',
              ],
            ),

            const Gap(12),

            // ── Self-Custody ──
            _InfoCard(
              icon: Icons.key_rounded,
              iconColor: ZipherColors.orange,
              title: 'Self-Custody',
              items: [
                'You own your keys. Nobody else can access your funds.',
                'Back up your seed phrase. If you lose it, your funds are gone forever.',
                'Zipher cannot recover your keys or reverse transactions.',
              ],
            ),

            const Gap(12),

            // ── Open Source ──
            _InfoCard(
              icon: Icons.code_rounded,
              iconColor: ZipherColors.cyan,
              title: 'Open Source',
              items: [
                'Built on open-source Zcash technology (MIT licensed).',
                'Verify the code yourself on GitHub.',
              ],
            ),

            const Gap(24),

            // Links
            _linkButton(
              icon: Icons.language_rounded,
              label: 'atmospherelabs.dev',
              onTap: () => _openUrl('https://atmospherelabs.dev'),
            ),
            const Gap(8),
            _linkButton(
              icon: Icons.code_rounded,
              label: 'View on GitHub',
              onTap: () => _openUrl('https://github.com/atmospherelabs-dev/zipher-app'),
            ),

            const Gap(32),

            // Disclaimer
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(ZipherRadius.card),
              ),
              child: Text(
                'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND. '
                'THE AUTHORS ARE NOT LIABLE FOR ANY DAMAGES ARISING FROM THE USE OF THIS SOFTWARE.',
                style: TextStyle(
                  fontSize: 10,
                  color: ZipherColors.text40,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const Gap(40),
          ],
        ),
      ),
    );
  }

  void _openUrl(String url) {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Widget _linkButton(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return ZipherButton(
      label: label,
      icon: icon,
      kind: ZipherButtonKind.secondary,
      onPressed: onTap,
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final List<String> items;

  const _InfoCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ZipherSpacing.md),
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: iconColor.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            Row(
            children: [
              Icon(icon, size: 16, color: iconColor.withValues(alpha: 0.85)),
              const Gap(8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ZipherColors.text60,
                ),
              ),
            ],
          ),
          const Gap(10),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ZipherColors.text10,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const Gap(10),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        fontSize: 12,
                        color: ZipherColors.text40,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// DISCLAIMER PAGE (kept from original)
// ═══════════════════════════════════════════════════════════

class DisclaimerPage extends StatefulWidget {
  final String mode; // 'create' or 'restore'
  const DisclaimerPage({this.mode = 'restore'});
  @override
  State<StatefulWidget> createState() => _DisclaimerState();
}

class _DisclaimerState extends State<DisclaimerPage> {
  /// Three facts a newcomer needs, one line each; one tap to accept.
  static const _facts = [
    (Icons.key_rounded, 'Your recovery phrase is the only way back in.'),
    (Icons.visibility_off_rounded,
        'We never see it, and can’t restore it for you.'),
    (Icons.shield_rounded, 'Payments are private by default.'),
  ];

  void _showTerms() {
    final s = S.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: ZipherColors.surface,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              ZipherSpacing.lg, 0, ZipherSpacing.lg, ZipherSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Terms', style: ZipherType.title),
              const Gap(ZipherSpacing.md),
              for (final line in [
                s.disclaimer_1,
                s.disclaimer_2,
                s.disclaimer_3,
                'Zipher is open-source software provided as is, without warranty of any kind. Its authors are not liable for damages arising from its use.',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: ZipherSpacing.sm),
                  child: Text(line, style: ZipherType.subhead),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.mode == 'create';
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZipherSpacing.sm, ZipherSpacing.sm, ZipherSpacing.sm, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => GoRouter.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: ZipherColors.text90, size: 20),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                    horizontal: ZipherColors.pagePadding),
                children: [
                  const Gap(ZipherSpacing.md),
                  Text(
                      creating
                          ? 'Your wallet, your keys'
                          : 'Welcome back',
                      style: ZipherType.largeTitle),
                  const Gap(ZipherSpacing.sm),
                  Text(
                      creating
                          ? 'Three things to know before you start.'
                          : 'Three things to know before you restore.',
                      style: ZipherType.subhead),
                  const Gap(ZipherSpacing.lg),
                  ZipherWidgets.group([
                    for (final (icon, text) in _facts)
                      Padding(
                        padding: const EdgeInsets.all(ZipherSpacing.md),
                        child: Row(children: [
                          ZipherWidgets.iconTile(icon,
                              color: ZipherColors.cyan),
                          const Gap(ZipherSpacing.smMd),
                          Expanded(
                              child: Text(text, style: ZipherType.rowTitle)),
                        ]),
                      ),
                  ]),
                ],
              ),
            ),
            ZipherWidgets.bottomActions([
              ZipherButton(
                label: 'I understand',
                loading: _creating,
                onPressed: _accept,
              ),
              ZipherButton(
                label: 'Terms',
                kind: ZipherButtonKind.plain,
                size: ZipherButtonSize.small,
                color: ZipherColors.text60,
                onPressed: _showTerms,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  bool _creating = false;

  void _accept() async {
    if (_creating) return;
    final prefs = await SharedPreferences.getInstance();
    appSettings.disclaimer = true;
    await appSettings.save(prefs);

    if (widget.mode == 'create') {
      setState(() => _creating = true);
      try {
        final ws = WalletService.instance;
        logger.d('creating wallet');

        if (ws.isWalletOpen) {
          syncStatus2.paused = true;
          await ws.closeWallet();
        }

        await ws.createNewWallet('Main Wallet');

        final balance = await ws.getBalanceOrZero();
        final addrs = await ws.getAddresses();
        final profile = await WalletRegistry.instance
            .getById(ws.activeWalletId!);

        aa = ActiveAccount2.fromWallet(
          coin: activeCoin.coin,
          address: addrs.isNotEmpty ? addrs.first.address : '',
          balance: balance,
          walletName: profile?.name ?? 'Main Wallet',
          walletId: ws.activeWalletId ?? '',
        );
        await aa.save(prefs);

        aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
        syncStatus2.resetForWalletSwitch();
        if (mounted) {
          GoRouter.of(context).go('/account');
          Future.delayed(const Duration(milliseconds: 500), () => startAutoSync());
        }
      } catch (e) {
        logger.e('Create wallet error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating wallet: $e')),
          );
        }
      } finally {
        if (mounted) setState(() => _creating = false);
      }
    } else {
      if (mounted) GoRouter.of(context).push('/restore');
    }
  }
}
