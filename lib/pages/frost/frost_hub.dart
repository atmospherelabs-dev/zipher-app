import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../zipher_theme.dart';

class FrostHubPage extends StatelessWidget {
  const FrostHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: Text(
          'Shared Wallet',
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          children: [
            Icon(Icons.group_rounded, size: 34, color: ZipherColors.cyan),
            const Gap(22),
            Text(
              'FROST shared wallets',
              style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
              ),
            ),
            const Gap(8),
            Text(
              'Create or join an Orchard wallet where spending requires multiple approvals. FROST signatures look like normal Zcash spends on-chain.',
              style: TextStyle(
                color: ZipherColors.text60,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const Gap(28),
            _ActionCard(
              icon: Icons.add_circle_outline_rounded,
              title: 'Create shared wallet',
              subtitle:
                  'Start a 2-of-3 setup, invite a co-signer, and create a recovery share.',
              onTap: () => GoRouter.of(context).push('/wallet/create/frost'),
            ),
            const Gap(12),
            _ActionCard(
              icon: Icons.link_rounded,
              title: 'Join shared wallet',
              subtitle:
                  'Scan or paste an invite from another Zipher user, desktop, or CLI.',
              onTap: () => GoRouter.of(context).push('/wallet/join'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(ZipherRadius.lg),
            border: Border.all(color: ZipherColors.borderSubtle),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(ZipherRadius.md),
                ),
                child: Icon(icon, color: ZipherColors.cyan, size: 22),
              ),
              const Gap(14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: ZipherColors.text90,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Gap(4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: ZipherColors.text40,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(8),
              Icon(Icons.chevron_right_rounded, color: ZipherColors.text20),
            ],
          ),
        ),
      ),
    );
  }
}
