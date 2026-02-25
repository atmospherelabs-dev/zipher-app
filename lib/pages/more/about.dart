import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../services/secure_key_store.dart';
import '../../zipher_theme.dart';
import '../../src/version.dart';
import '../../appsettings.dart';
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
          'ABOUT',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded,
              color: ZipherColors.text60),
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
              'by CipherScan',
              style: TextStyle(
                fontSize: 13,
                color: ZipherColors.cyan.withValues(alpha: 0.5),
              ),
            ),
            const Gap(4),
            GestureDetector(
              onTap: () => _openUrl('https://github.com/hhanh00/zwallet/commit/$commitId'),
              child: Text(
                'v$packageVersion ($id)',
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text10,
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
                'Zipher is built on top of YWallet\'s open-source Zcash engine.',
                'Verify the code yourself on GitHub.',
              ],
            ),

            const Gap(24),

            // Links
            _linkButton(
              icon: Icons.language_rounded,
              label: 'cipherscan.app',
              onTap: () => _openUrl('https://cipherscan.app'),
            ),
            const Gap(8),
            _linkButton(
              icon: Icons.code_rounded,
              label: 'View on GitHub',
              onTap: () => _openUrl('https://github.com/hhanh00/zwallet'),
            ),

            const Gap(32),

            // Disclaimer
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND. '
                'THE AUTHORS ARE NOT LIABLE FOR ANY DAMAGES ARISING FROM THE USE OF THIS SOFTWARE.',
                style: TextStyle(
                  fontSize: 10,
                  color: ZipherColors.text10,
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: ZipherColors.text20),
            const Gap(8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: ZipherColors.text40,
              ),
            ),
            const Gap(6),
            Icon(Icons.open_in_new_rounded,
                size: 12, color: ZipherColors.text10),
          ],
        ),
      ),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: iconColor.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor.withValues(alpha: 0.5)),
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
  final List<bool> _accepted = [false, false, false];

  bool get _allAccepted => !_accepted.any((e) => !e);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(12),
              // Back button — minimal
              IconButton(
                onPressed: () => GoRouter.of(context).pop(),
                icon: Icon(Icons.arrow_back_rounded,
                    color: ZipherColors.text60, size: 22),
              ),
              const Gap(24),
              // Title
              Text(
                'Self-Custody',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: ZipherColors.text90,
                  letterSpacing: -0.5,
                ),
              ),
              const Gap(8),
              Text(
                widget.mode == 'create'
                    ? 'Before creating your wallet, please acknowledge:'
                    : 'Before restoring, please acknowledge:',
                style: TextStyle(
                  fontSize: 14,
                  color: ZipherColors.text40,
                  height: 1.4,
                ),
              ),
              const Gap(32),
              _DisclaimerTile(
                accepted: _accepted[0],
                text: s.disclaimer_1,
                onChanged: (v) => setState(() => _accepted[0] = v),
              ),
              const Gap(10),
              _DisclaimerTile(
                accepted: _accepted[1],
                text: s.disclaimer_2,
                onChanged: (v) => setState(() => _accepted[1] = v),
              ),
              const Gap(10),
              _DisclaimerTile(
                accepted: _accepted[2],
                text: s.disclaimer_3,
                onChanged: (v) => setState(() => _accepted[2] = v),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: _creating
                    ? Center(
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            color: ZipherColors.cyan,
                            strokeWidth: 2,
                          ),
                        ),
                      )
                    : AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: _allAccepted ? 1.0 : 0.3,
                        child: IgnorePointer(
                          ignoring: !_allAccepted,
                          child: ZipherWidgets.gradientButton(
                            label: widget.mode == 'create'
                                ? 'Create Wallet'
                                : 'Continue',
                            icon: widget.mode == 'create'
                                ? Icons.add_rounded
                                : Icons.arrow_forward_rounded,
                            onPressed: _accept,
                          ),
                        ),
                      ),
              ),
              const Gap(28),
            ],
          ),
        ),
      ),
    );
  }

  bool _creating = false;

  void _accept() async {
    final prefs = await SharedPreferences.getInstance();
    appSettings.disclaimer = true;
    await appSettings.save(prefs);

    if (widget.mode == 'create') {
      setState(() => _creating = true);
      try {
        final coin = activeCoin.coin;
        final name = isTestnet ? 'Testnet' : 'Main';
        final account = await WarpApi.newAccount(coin, name, '', 0);
        if (account >= 0) {
          // Move seed from DB to Keychain
          final backup = WarpApi.getBackup(coin, account);
          if (backup.seed != null) {
            await SecureKeyStore.storeSeed(
                coin, account, backup.seed!, backup.index);
            WarpApi.loadKeysFromSeed(coin, account, backup.seed!, backup.index);
            WarpApi.clearAccountSecrets(coin, account);
          }
          setActiveAccount(coin, account, canPayOverride: true);
          await aa.save(prefs);
          try {
            await WarpApi.skipToLastHeight(coin);
          } catch (e) {
            logger.e('skipToLastHeight error: $e');
          }
          if (mounted) GoRouter.of(context).go('/account');
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

class _DisclaimerTile extends StatelessWidget {
  final bool accepted;
  final String text;
  final ValueChanged<bool> onChanged;

  const _DisclaimerTile({
    required this.accepted,
    required this.text,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!accepted),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: accepted
              ? ZipherColors.green.withValues(alpha: 0.05)
              : ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accepted
                ? ZipherColors.green.withValues(alpha: 0.2)
                : ZipherColors.borderSubtle,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: accepted
                    ? ZipherColors.green
                    : ZipherColors.cardBgElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: accepted
                      ? ZipherColors.green
                      : ZipherColors.text10,
                ),
              ),
              child: accepted
                  ? const Icon(Icons.check_rounded,
                      size: 14, color: Colors.white)
                  : null,
            ),
            const Gap(14),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 14,
                  color: accepted
                      ? ZipherColors.text90
                      : ZipherColors.text40,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
