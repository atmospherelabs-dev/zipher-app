import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../services/hitl_watch_service.dart';
import '../../zipher_theme.dart';
import '../utils.dart';
import 'hitl_widgets.dart';

/// Confirms a pairing code before this phone starts approving an agent's
/// larger payments. The code must match what `zipher pair` shows, so a link
/// from anywhere else can't pair silently.
class HitlPairPage extends StatefulWidget {
  final HitlPairingArgs args;
  /// Tests start on the confirm-on-computer step.
  @visibleForTesting
  final String? debugPairedCode;
  const HitlPairPage({super.key, required this.args, this.debugPairedCode});

  @override
  State<HitlPairPage> createState() => _HitlPairPageState();
}

class _HitlPairPageState extends State<HitlPairPage> {
  bool _busy = false;
  bool _done = false;
  bool _askPush = false;
  /// Set once the phone answered: the operator confirms it in the terminal.
  late String? _pairedCode = widget.debugPairedCode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        automaticallyImplyLeading: false,
        leading: _done || _pairedCode != null ? null : hitlCloseButton(context),
        title: const Text('Pair agent',
            style: TextStyle(color: ZipherColors.text90, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _pairedCode != null && !_askPush && !_done
              ? _confirmOnComputer(_pairedCode!)
              : _askPush
              ? HitlPushChoice(
                  key: const ValueKey('push'),
                  agentName: widget.args.preview.agentName,
                  onDone: _finish,
                )
              : _done
              ? HitlDone(
                  key: const ValueKey('done'),
                  icon: Icons.check_rounded,
                  color: ZipherColors.green,
                  title: 'Paired',
                  subtitle: 'Larger payments from ${widget.args.preview.agentName} will ask you here first.',
                )
              : _confirm(),
        ),
      ),
    );
  }

  Widget _confirm() {
    final p = widget.args.preview;
    final code = p.checkCode;
    final replacing = HitlWatchService.instance.isPaired;

    final details = ListView(
      padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
      children: [
        const Gap(ZipherSpacing.lg),
        const Center(child: HitlBadge(icon: Icons.link_rounded)),
        const Gap(ZipherSpacing.md),
        Text(p.agentName,
            textAlign: TextAlign.center,
            style: const TextStyle(color: ZipherColors.text90, fontSize: 20, fontWeight: FontWeight.w700)),
        const Gap(6),
        const Text('wants to ask you before it makes larger payments.',
            textAlign: TextAlign.center, style: TextStyle(color: ZipherColors.text60, fontSize: 15, height: 1.4)),
        const Gap(ZipherSpacing.xl),
        HitlCard(
          padding: const EdgeInsets.symmetric(vertical: ZipherSpacing.lg, horizontal: ZipherSpacing.md),
          child: Column(children: [
            const Text('Pairing code',
                style: TextStyle(color: ZipherColors.text40, fontSize: 13, fontWeight: FontWeight.w500)),
            const Gap(ZipherSpacing.sm),
            Text('${code.substring(0, 3)} ${code.substring(3)}',
                style: const TextStyle(
                    color: ZipherColors.text90,
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: hitlMonoFallback,
                    letterSpacing: 2)),
            const Gap(ZipherSpacing.sm),
            const Text('Make sure this matches the code on your computer.',
                textAlign: TextAlign.center, style: TextStyle(color: ZipherColors.text60, fontSize: 14)),
          ]),
        ),
        const Gap(ZipherSpacing.lg),
        _point(Icons.lock_rounded, 'End-to-end encrypted. Only this phone can read requests.'),
        _point(Icons.verified_user_rounded, 'Your agent can’t send above its limit without your Face ID.'),
        if (replacing)
          _point(Icons.swap_horiz_rounded,
              'Replaces ${HitlWatchService.instance.agentName ?? 'your current agent'}. It will no longer be able to ask you.'),
        const Gap(ZipherSpacing.lg),
      ],
    );

    final actions = Padding(
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
                ZipherWidgets.gradientButton(label: 'Pair', onPressed: _pair),
                const Gap(ZipherSpacing.smMd),
                ZipherWidgets.ghostButton(label: 'Cancel', onPressed: () => hitlCloseSelf(context)),
              ],
            ),
    );

    return Column(
      key: const ValueKey('confirm'),
      children: [Expanded(child: details), actions],
    );
  }

  Widget _point(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: ZipherSpacing.smMd),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: ZipherColors.cyan.withValues(alpha: 0.8)),
          const Gap(ZipherSpacing.smMd),
          Expanded(
            child: Text(text, style: const TextStyle(color: ZipherColors.text60, fontSize: 14, height: 1.4)),
          ),
        ]),
      );

  Future<void> _pair() async {
    HapticFeedback.selectionClick();
    final ok = await requireSigningAuthorization(
      context,
      actionSummary: 'Pair ${widget.args.preview.agentName}',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    String? error;
    String? code;
    try {
      code = await HitlWatchService.instance.completePairing(widget.args.uri);
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    if (error != null) {
      HapticFeedback.heavyImpact();
      setState(() => _busy = false);
      final msg = error.contains('expired')
          ? 'This code expired. Run `zipher pair` again on your computer.'
          : error.contains('already used')
              ? 'This code was already used. Run `zipher pair` again.'
              : 'Couldn’t pair. Check your connection and try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = false;
      _pairedCode = code;
    });
  }

  /// The last step happens on the computer: the operator types "y" only if
  /// it shows this same code. If someone else scanned the pairing code first,
  /// the codes differ and the agent refuses that phone.
  Widget _confirmOnComputer(String code) {
    return Column(
      key: const ValueKey('confirm-computer'),
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
            children: [
              const Gap(ZipherSpacing.lg),
              const Center(child: HitlBadge(icon: Icons.laptop_mac_rounded)),
              const Gap(ZipherSpacing.md),
              const Text('Confirm on your computer',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ZipherColors.text90, fontSize: 20, fontWeight: FontWeight.w700)),
              const Gap(6),
              const Text('Your terminal is asking whether this phone shows the same code.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ZipherColors.text60, fontSize: 15, height: 1.4)),
              const Gap(ZipherSpacing.xl),
              HitlCard(
                padding: const EdgeInsets.symmetric(vertical: ZipherSpacing.lg, horizontal: ZipherSpacing.md),
                child: Column(children: [
                  Text('${code.substring(0, 3)} ${code.substring(3)}',
                      style: const TextStyle(
                          color: ZipherColors.text90,
                          fontSize: 36,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: hitlMonoFallback,
                          letterSpacing: 2)),
                  const Gap(ZipherSpacing.sm),
                  const Text('Type y only if your computer shows this code.',
                      textAlign: TextAlign.center, style: TextStyle(color: ZipherColors.text60, fontSize: 14)),
                ]),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              ZipherColors.pagePadding, ZipherSpacing.smMd, ZipherColors.pagePadding, ZipherSpacing.sm),
          child: ZipherWidgets.gradientButton(label: 'Done', onPressed: _afterConfirm),
        ),
      ],
    );
  }

  Future<void> _afterConfirm() async {
    HapticFeedback.selectionClick();
    if (HitlWatchService.instance.pushSupported && !HitlWatchService.instance.pushEnabled) {
      setState(() => _askPush = true);
    } else {
      await _finish();
    }
  }

  Future<void> _finish() async {
    if (!mounted) return;
    setState(() {
      _askPush = false;
      _done = true;
    });
    await Future.delayed(const Duration(milliseconds: 1600));
    if (mounted) hitlCloseSelf(context);
  }
}
