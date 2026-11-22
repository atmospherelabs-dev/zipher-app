import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../zipher_theme.dart';

/// Exact ZEC string from zatoshis (integer math, no rounding).
String formatZat(BigInt zat) {
  final unit = BigInt.from(100000000);
  final whole = zat ~/ unit;
  final frac = (zat % unit).toString().padLeft(8, '0').replaceFirst(RegExp(r'0+$'), '');
  return frac.isEmpty ? '$whole' : '$whole.$frac';
}

/// Address in groups of four so it can be compared at a glance.
String groupAddress(String address) {
  final b = StringBuffer();
  for (var i = 0; i < address.length; i += 4) {
    if (i > 0) b.write(' ');
    b.write(address.substring(i, (i + 4).clamp(0, address.length)));
  }
  return b.toString();
}

/// Round tinted badge used at the top of the approval screens.
class HitlBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const HitlBadge({super.key, required this.icon, this.color = ZipherColors.cyan});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Icon(icon, color: color, size: 30),
    );
  }
}

/// Elevated card matching the invoice screens.
class HitlCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const HitlCard({super.key, required this.child, this.padding = const EdgeInsets.all(ZipherSpacing.lg)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: ZipherColors.cardBgElevated,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: child,
    );
  }
}

/// Label above a value inside a card.
class HitlDetail extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;
  const HitlDetail({super.key, required this.label, required this.value, this.mono = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(color: ZipherColors.text40, fontSize: 13, fontWeight: FontWeight.w500)),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
        const Gap(6),
        SelectableText(
          value,
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: mono ? 14 : 15,
            height: 1.45,
            fontFamily: mono ? 'JetBrainsMono' : 'Inter',
          ),
        ),
      ],
    );
  }
}

/// Full-screen confirmation shown after a decision, then dismissed.
class HitlDone extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  const HitlDone({super.key, required this.icon, required this.color, required this.title, required this.subtitle});

  @override
  State<HitlDone> createState() => _HitlDoneState();
}

class _HitlDoneState extends State<HitlDone> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(scale: scale, child: HitlBadge(icon: widget.icon, color: widget.color)),
          const Gap(ZipherSpacing.lg),
          FadeTransition(
            opacity: _c,
            child: Column(children: [
              Text(widget.title,
                  style: const TextStyle(color: ZipherColors.text90, fontSize: 22, fontWeight: FontWeight.w700)),
              const Gap(ZipherSpacing.sm),
              Text(widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: ZipherColors.text60, fontSize: 15, height: 1.4)),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Close button used in the app bar of the approval sheets.
Widget hitlCloseButton(BuildContext context) => IconButton(
      icon: const Icon(Icons.close_rounded, color: ZipherColors.text60),
      onPressed: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).maybePop();
      },
    );
