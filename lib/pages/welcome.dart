import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/warp_api.dart';

import '../accounts.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../zipher_theme.dart';
import 'utils.dart';

class WelcomePage extends StatefulWidget {
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.5),
            radius: 1.5,
            colors: [
              Color(0xFF0D1640),
              ZipherColors.bg,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Gap(40),
                  // Logo
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset('assets/zipher_logo.png', height: 96),
                  ),
                  const Gap(24),
                  // Brand
                  ZipherWidgets.brandText(fontSize: 36),
                  const Gap(8),
                  Text(
                    'Private Zcash Wallet',
                    style: TextStyle(
                      fontSize: 16,
                      color: ZipherColors.textSecondary,
                    ),
                  ),
                  const Gap(48),
                  // Feature cards
                  _FeatureCard(
                    icon: Icons.shield_outlined,
                    color: ZipherColors.purple,
                    title: 'Fully Private',
                    subtitle:
                        'Shielded transactions with zero-knowledge proofs',
                  ),
                  const Gap(12),
                  _FeatureCard(
                    icon: Icons.key_outlined,
                    color: ZipherColors.green,
                    title: 'Self-Custodial',
                    subtitle: 'Your keys, your coins. No intermediaries',
                  ),
                  const Gap(12),
                  _FeatureCard(
                    icon: Icons.speed_outlined,
                    color: ZipherColors.cyan,
                    title: 'Warp Sync',
                    subtitle: 'Ultra-fast synchronization technology',
                  ),
                  const Gap(48),
                  // Create Wallet — directly creates a Zcash account
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
                        : ZipherWidgets.gradientButton(
                            label: 'Create Wallet',
                            icon: Icons.add_circle_outline,
                            onPressed: () => _createWallet(context),
                          ),
                  ),
                  const Gap(16),
                  // Restore Wallet — goes through disclaimer first
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          _creating ? null : () => _restoreWallet(context),
                      icon: const Icon(Icons.download_outlined, size: 20),
                      label: const Text('Restore Wallet'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ZipherColors.cyan,
                        side: const BorderSide(color: ZipherColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(ZipherRadius.md),
                        ),
                      ),
                    ),
                  ),
                  const Gap(40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Directly create a new Zcash wallet and go to home.
  Future<void> _createWallet(BuildContext context) async {
    setState(() => _creating = true);
    try {
      const coin = 0; // Zcash
      final account = await WarpApi.newAccount(coin, 'Main', '', 0);
      if (account >= 0) {
        setActiveAccount(coin, account);
        final prefs = await SharedPreferences.getInstance();
        await aa.save(prefs);
        await WarpApi.skipToLastHeight(coin);
        // Mark disclaimer as accepted (implicit for new wallets)
        appSettings.disclaimer = true;
        await appSettings.save(prefs);
        if (mounted) GoRouter.of(context).go('/account');
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Navigate to the disclaimer → restore flow.
  void _restoreWallet(BuildContext context) {
    GoRouter.of(context).push('/disclaimer');
  }
}

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const _FeatureCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.surface,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const Gap(16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.textPrimary,
                  ),
                ),
                const Gap(2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: ZipherColors.textMuted,
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
