import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../services/wallet_registry.dart';
import '../zipher_theme.dart';

class WelcomePage extends StatefulWidget {
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;
  bool _hasExistingWallets = false;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      duration: const Duration(milliseconds: 3000),
      vsync: this,
    )..repeat(reverse: true);
    _glowAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
    _checkExistingWallets();
  }

  Future<void> _checkExistingWallets() async {
    final wallets = await WalletRegistry.instance.getAll();
    if (mounted) {
      setState(() => _hasExistingWallets = wallets.isNotEmpty);
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Stack(
        children: [
          // Ambient beam background (same as home page)
          Positioned.fill(
            child: Align(
              alignment: Alignment.topCenter,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 70,
                  sigmaY: 40,
                  tileMode: TileMode.decal,
                ),
                child: ClipRect(
                  child: SizedBox(
                    width: double.infinity,
                    height: 700,
                    child: CustomPaint(
                      painter: _WelcomeBeamPainter(
                        colorTop: ZipherColors.cyan.withValues(alpha: 0.12),
                        colorMid: ZipherColors.purple.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Content
          SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(28, 0, 28, bottomPad > 0 ? 0 : 20),
              child: Column(
                children: [
                  const Spacer(flex: 2),

                  // Logo with animated glow
                  AnimatedBuilder(
                    animation: _glowAnimation,
                    builder: (context, child) {
                      return Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(ZipherRadius.xxl),
                          boxShadow: [
                            BoxShadow(
                              color: ZipherColors.cyan.withValues(
                                  alpha: 0.15 * _glowAnimation.value),
                              blurRadius: 40,
                              spreadRadius: 8,
                            ),
                          ],
                        ),
                        child: child,
                      );
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(ZipherRadius.xxl),
                      child: Image.asset('assets/zipher_logo.png', height: 88),
                    ),
                  ),

                  const Gap(28),

                  // Brand name
                  ZipherWidgets.brandText(fontSize: 38),

                  const Gap(8),

                  // Tagline
                  Text(
                    'Zcash for humans and agents',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      color: ZipherColors.text40,
                      letterSpacing: 0.5,
                    ),
                  ),

                  const Spacer(flex: 5),

                  // Create Account button
                  ZipherButton(
                    label: 'Create account',
                    icon: Icons.add_rounded,
                    onPressed: () => GoRouter.of(context)
                        .push('/disclaimer', extra: 'create'),
                  ),

                  const Gap(12),

                  // Import Account
                  ZipherButton(
                    label: 'Import account',
                    icon: Icons.download_rounded,
                    kind: ZipherButtonKind.secondary,
                    onPressed: () => GoRouter.of(context)
                        .push('/disclaimer', extra: 'restore'),
                  ),

                  const Gap(12),

                  Row(
                    children: [
                      Expanded(
                        child: _compactAction(
                          icon: Icons.group_rounded,
                          label: 'Shared wallet',
                          onTap: () =>
                              GoRouter.of(context).push('/wallet/frost'),
                        ),
                      ),
                      const Gap(10),
                      Expanded(
                        child: _compactAction(
                          icon: Icons.link_rounded,
                          label: 'Join setup',
                          onTap: () =>
                              GoRouter.of(context).push('/wallet/join'),
                        ),
                      ),
                    ],
                  ),

                  if (_hasExistingWallets) ...[
                    const Gap(8),
                    ZipherButton(
                      label: 'Back to my wallets',
                      kind: ZipherButtonKind.plain,
                      color: ZipherColors.text60,
                      onPressed: () => GoRouter.of(context).go('/'),
                    ),
                  ],

                  const Gap(16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ZipherButton(
      label: label,
      icon: icon,
      kind: ZipherButtonKind.secondary,
      onPressed: onTap,
    );
  }
}

// ─── Beam painter (matching home page style) ─────────────────

class _WelcomeBeamPainter extends CustomPainter {
  final Color colorTop;
  final Color colorMid;

  _WelcomeBeamPainter({required this.colorTop, required this.colorMid});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final inset = w / 5;
    final path = Path()
      ..moveTo(inset, 0)
      ..lineTo(w - inset, 0)
      ..lineTo(w * 0.58, h)
      ..lineTo(w * 0.42, h)
      ..close();

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          colorTop,
          colorMid,
          Colors.transparent,
        ],
        stops: const [0.0, 0.4, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h));

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WelcomeBeamPainter old) =>
      old.colorTop != colorTop || old.colorMid != colorMid;
}
