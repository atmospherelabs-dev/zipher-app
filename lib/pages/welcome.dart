import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../zipher_theme.dart';

class WelcomePage extends StatefulWidget {
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;

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
                        colorTop:
                            ZipherColors.cyan.withValues(alpha: 0.12),
                        colorMid:
                            ZipherColors.purple.withValues(alpha: 0.08),
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
                          borderRadius: BorderRadius.circular(28),
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
                      borderRadius: BorderRadius.circular(28),
                      child:
                          Image.asset('assets/zipher_logo.png', height: 88),
                    ),
                  ),

                  const Gap(28),

                  // Brand name
                  ZipherWidgets.brandText(fontSize: 38),

                  const Gap(8),

                  // Tagline
                  Text(
                    'Private Zcash Wallet',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      color: ZipherColors.text40,
                      letterSpacing: 0.5,
                    ),
                  ),

                  const Spacer(flex: 5),

                  // Create Wallet button
                  SizedBox(
                    width: double.infinity,
                    child: ZipherWidgets.gradientButton(
                      label: 'Create Wallet',
                      icon: Icons.add_rounded,
                      onPressed: () =>
                          GoRouter.of(context).push('/disclaimer', extra: 'create'),
                    ),
                  ),

                  const Gap(12),

                  // Restore Wallet — ghost button
                  SizedBox(
                    width: double.infinity,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () =>
                            GoRouter.of(context).push('/disclaimer', extra: 'restore'),
                        borderRadius: BorderRadius.circular(ZipherRadius.md),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: ZipherColors.cardBg,
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            border: Border.all(
                              color: ZipherColors.borderSubtle,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.download_rounded,
                                size: 18,
                                color: ZipherColors.text60,
                              ),
                              const Gap(8),
                              Text(
                                'Restore Wallet',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: ZipherColors.text60,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  const Gap(16),
                ],
              ),
            ),
          ),
        ],
      ),
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
