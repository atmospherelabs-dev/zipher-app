import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../services/hitl_watch_service.dart';
import '../../zipher_theme.dart';

/// Monospace for addresses and codes. JetBrains Mono is not bundled, so fall
/// back to the system mono fonts (Menlo on iOS) rather than a proportional face.
const hitlMonoFallback = <String>['Menlo', 'Roboto Mono', 'monospace'];

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
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.card),
        border: Border.all(color: ZipherColors.borderSubtle, width: 0.5),
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
            fontFamilyFallback: mono ? hitlMonoFallback : null,
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZipherSpacing.xl),
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
      ),
    );
  }
}

/// Close this screen only. A plain pop would close whatever is on top, such as
/// an approval request that arrived while this screen was finishing.
void hitlCloseSelf(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isActive) return;
  final nav = Navigator.of(context);
  if (route.isCurrent) {
    nav.pop();
  } else {
    nav.removeRoute(route);
  }
}

/// Close button used in the app bar of the approval sheets.
Widget hitlCloseButton(BuildContext context) => IconButton(
      icon: const Icon(Icons.close_rounded, color: ZipherColors.text60),
      onPressed: () {
        HapticFeedback.selectionClick();
        hitlCloseSelf(context);
      },
    );

/// The privacy trade-off of push, said plainly. Shared by the pairing flow
/// and Settings so the wording never drifts.
const hitlPushDisclosure =
    'Alerts come through Apple. To wake this phone, the relay keeps its push '
    'token, and Apple sees when an alert arrives. Neither can see the payment: '
    'the alert only says your agent is waiting.';

/// Offered once after pairing (iOS): notifications are off until chosen.
class HitlPushChoice extends StatefulWidget {
  final String agentName;
  final Future<void> Function() onDone;
  const HitlPushChoice({super.key, required this.agentName, required this.onDone});

  @override
  State<HitlPushChoice> createState() => _HitlPushChoiceState();
}

class _HitlPushChoiceState extends State<HitlPushChoice> {
  bool _busy = false;

  Future<void> _turnOn() async {
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    var result = PushResult.failed;
    try {
      result = await HitlWatchService.instance.enablePush();
    } catch (_) {}
    if (!mounted) return;
    await hitlShowPushResult(context, result);
    await widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
          children: [
            const Gap(ZipherSpacing.xl),
            const Center(child: HitlBadge(icon: Icons.notifications_active_rounded)),
            const Gap(ZipherSpacing.lg),
            Text('Get notified when ${widget.agentName} needs you?',
                textAlign: TextAlign.center,
                style: const TextStyle(color: ZipherColors.text90, fontSize: 20, fontWeight: FontWeight.w700, height: 1.3)),
            const Gap(ZipherSpacing.md),
            const Text('Without notifications, requests appear when you open Zipher.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ZipherColors.text60, fontSize: 15, height: 1.4)),
            const Gap(ZipherSpacing.lg),
            HitlCard(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.visibility_rounded, size: 18, color: ZipherColors.warm.withValues(alpha: 0.9)),
                const Gap(ZipherSpacing.smMd),
                const Expanded(
                  child: Text(hitlPushDisclosure,
                      style: TextStyle(color: ZipherColors.text60, fontSize: 14, height: 1.45)),
                ),
              ]),
            ),
            const Gap(ZipherSpacing.sm),
            const Text('You can change this anytime in Settings.',
                textAlign: TextAlign.center, style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
            ZipherColors.pagePadding, ZipherSpacing.smMd, ZipherColors.pagePadding, ZipherSpacing.sm),
        child: _busy
            ? const Padding(
                padding: EdgeInsets.all(ZipherSpacing.md),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ZipherWidgets.gradientButton(label: 'Turn On Notifications', onPressed: _turnOn),
                  const Gap(ZipherSpacing.smMd),
                  ZipherWidgets.ghostButton(label: 'Not Now', onPressed: () => widget.onDone()),
                ],
              ),
      ),
    ]);
  }
}

/// Tell the user what happened. A past refusal can only be undone in iOS
/// Settings, so offer to open it in a system-style alert.
Future<void> hitlShowPushResult(BuildContext context, PushResult result) async {
  final messenger = ScaffoldMessenger.of(context);
  switch (result) {
    case PushResult.on:
      messenger.showSnackBar(const SnackBar(content: Text('Notifications on')));
    case PushResult.denied:
      final open = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Notifications Are Off'),
          content: const Text('To get alerts when your agent needs you, allow notifications for Zipher in Settings.'),
          actions: [
            CupertinoDialogAction(child: const Text('Not Now'), onPressed: () => Navigator.of(ctx).pop(false)),
            CupertinoDialogAction(
                isDefaultAction: true, child: const Text('Open Settings'), onPressed: () => Navigator.of(ctx).pop(true)),
          ],
        ),
      );
      if (open == true) await HitlWatchService.instance.openNotificationSettings();
    case PushResult.failed:
      messenger.showSnackBar(const SnackBar(
          content: Text('Couldn’t turn on notifications. Try again from Settings.')));
  }
}
