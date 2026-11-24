import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../services/hitl_watch_service.dart';
import '../../zipher_theme.dart';
import 'hitl_widgets.dart';

/// The paired agent at a glance: who it is, how it reaches you, and how to
/// stop it. Opened from the home indicator and from Settings.
class HitlAgentPage extends StatefulWidget {
  const HitlAgentPage({super.key});

  @override
  State<HitlAgentPage> createState() => _HitlAgentPageState();
}

class _HitlAgentPageState extends State<HitlAgentPage> {
  final svc = HitlWatchService.instance;
  bool _busy = false;

  String _since() {
    final at = svc.pairedAt;
    if (at == null) return 'Paired';
    final d = DateTime.fromMillisecondsSinceEpoch(at * 1000);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Paired since ${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  Future<void> _unpair() async {
    HapticFeedback.selectionClick();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZipherColors.cardBgElevated,
        title: const Text('Unpair this agent?'),
        content: Text(
            '${svc.agentName ?? 'The agent'} will no longer be able to ask for approvals. '
            'Sends above its limit will be refused until you pair again.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Unpair', style: TextStyle(color: ZipherColors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await svc.unpair();
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    hitlCloseSelf(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        automaticallyImplyLeading: false,
        leading: hitlCloseButton(context),
        title: const Text('Agent',
            style: TextStyle(color: ZipherColors.text90, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<bool>(
          valueListenable: svc.paired,
          builder: (context, paired, _) => paired ? _paired() : _notPaired(),
        ),
      ),
    );
  }

  Widget _notPaired() => ListView(
        padding: const EdgeInsets.all(ZipherColors.pagePadding),
        children: const [
          Gap(ZipherSpacing.xl),
          Center(child: HitlBadge(icon: Icons.smart_toy_outlined, color: ZipherColors.text40)),
          Gap(ZipherSpacing.lg),
          Text('No agent paired',
              textAlign: TextAlign.center,
              style: TextStyle(color: ZipherColors.text90, fontSize: 20, fontWeight: FontWeight.w700)),
          Gap(ZipherSpacing.sm),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: 'Run '),
              TextSpan(
                  text: 'zipher pair',
                  style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontFamilyFallback: hitlMonoFallback,
                      color: ZipherColors.text90)),
              TextSpan(
                  text: ' on your computer and scan the code with Zipher. '
                      'Your agent will then ask this phone before larger payments.'),
            ]),
            textAlign: TextAlign.center,
            style: TextStyle(color: ZipherColors.text60, fontSize: 15, height: 1.4),
          ),
        ],
      );

  Widget _paired() {
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
          children: [
            const Gap(ZipherSpacing.lg),
            const Center(child: HitlBadge(icon: Icons.smart_toy_rounded)),
            const Gap(ZipherSpacing.md),
            Text(svc.agentName ?? 'Your agent',
                textAlign: TextAlign.center,
                style: const TextStyle(color: ZipherColors.text90, fontSize: 20, fontWeight: FontWeight.w700)),
            const Gap(6),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: ZipherColors.green, shape: BoxShape.circle),
              ),
              const Gap(6),
              Text(_since(), style: const TextStyle(color: ZipherColors.text60, fontSize: 14)),
            ]),
            const Gap(ZipherSpacing.lg),
            HitlCard(
              padding: const EdgeInsets.all(ZipherSpacing.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                _Fact(icon: Icons.check_circle_outline_rounded, text: 'Can ask you to approve sends above its limit.'),
                _Fact(icon: Icons.block_rounded, text: 'Can’t see your balance, your history or this wallet.'),
                _Fact(icon: Icons.block_rounded, text: 'Can’t send from this phone or change its settings.'),
                _Fact(icon: Icons.lock_rounded, text: 'Requests are end-to-end encrypted; only this phone can read them.'),
              ]),
            ),
            const Gap(ZipherSpacing.md),
            HitlCard(
              padding: const EdgeInsets.symmetric(vertical: ZipherSpacing.xs),
              child: Column(children: [
                if (svc.pushSupported)
                  _Toggle(
                    icon: Icons.notifications_active_rounded,
                    title: 'Notifications',
                    subtitle: svc.pushEnabled ? hitlPushDisclosure : 'Off. Requests appear when you open Zipher.',
                    value: svc.pushEnabled,
                    onChanged: (v) async {
                      if (v) {
                        final r = await svc.enablePush();
                        if (mounted) await hitlShowPushResult(context, r);
                      } else {
                        await svc.disablePush();
                      }
                      if (mounted) setState(() {});
                    },
                  ),
                _Toggle(
                  icon: Icons.route_rounded,
                  title: 'Private routing (Tor)',
                  subtitle: svc.useTor
                      ? 'The relay never sees this phone’s IP address.'
                      : 'Off: the relay can see this phone’s IP address.',
                  value: svc.useTor,
                  onChanged: (v) async {
                    await svc.setUseTor(v);
                    if (mounted) setState(() {});
                  },
                ),
              ]),
            ),
            const Gap(ZipherSpacing.lg),
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
            : ZipherWidgets.secondaryButton(
                label: 'Unpair Agent', color: ZipherColors.red, width: double.infinity, onPressed: _unpair),
      ),
    ]);
  }
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Fact({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: ZipherColors.text40),
          const Gap(ZipherSpacing.smMd),
          Expanded(child: Text(text, style: const TextStyle(color: ZipherColors.text60, fontSize: 14, height: 1.4))),
        ]),
      );
}

class _Toggle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Toggle({required this.icon, required this.title, required this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: ZipherSpacing.md, vertical: ZipherSpacing.smMd),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: value ? ZipherColors.cyan : ZipherColors.text40),
          ),
          const Gap(ZipherSpacing.smMd),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: ZipherColors.text90, fontSize: 15, fontWeight: FontWeight.w600)),
              const Gap(4),
              Text(subtitle, style: const TextStyle(color: ZipherColors.text40, fontSize: 13, height: 1.4)),
            ]),
          ),
          Switch.adaptive(value: value, onChanged: onChanged, activeTrackColor: ZipherColors.cyan),
        ]),
      );
}
