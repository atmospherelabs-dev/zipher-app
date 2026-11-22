import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../services/hitl_watch_service.dart';
import '../../src/rust/api/engine_api.dart' as rust_engine;
import '../../zipher_theme.dart';
import '../utils.dart';
import 'hitl_widgets.dart';

enum _Stage { review, sending, approved, declined }

/// Review of a send a paired agent wants to make. Everything shown is covered
/// by the signature, so the agent cannot change it after approval.
class HitlApprovePage extends StatefulWidget {
  final rust_engine.HitlRequest request;
  const HitlApprovePage({super.key, required this.request});

  @override
  State<HitlApprovePage> createState() => _HitlApprovePageState();
}

class _HitlApprovePageState extends State<HitlApprovePage> {
  _Stage _stage = _Stage.review;
  Timer? _tick;

  rust_engine.HitlRequest get _req => widget.request;

  int get _remaining {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (_req.expiresAt.toInt() - now).clamp(0, 600);
  }

  int get _window => (_req.expiresAt - _req.createdAt).toInt().clamp(1, 600);

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _stage == _Stage.review) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        automaticallyImplyLeading: false,
        leading: _stage == _Stage.review ? hitlCloseButton(context) : null,
        title: const Text('Approve payment',
            style: TextStyle(color: ZipherColors.text90, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: switch (_stage) {
            _Stage.approved => const HitlDone(
                key: ValueKey('ok'),
                icon: Icons.check_rounded,
                color: ZipherColors.green,
                title: 'Approved',
                subtitle: 'Your agent will send it now.',
              ),
            _Stage.declined => const HitlDone(
                key: ValueKey('no'),
                icon: Icons.close_rounded,
                color: ZipherColors.text60,
                title: 'Declined',
                subtitle: 'Nothing was sent.',
              ),
            _ => _review(),
          },
        ),
      ),
    );
  }

  Widget _review() {
    final expired = _remaining == 0;
    final agent = HitlWatchService.instance.agentName ?? 'Your agent';
    final busy = _stage == _Stage.sending;
    final mins = _remaining ~/ 60;
    final secs = (_remaining % 60).toString().padLeft(2, '0');

    return ListView(
      key: const ValueKey('review'),
      padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
      children: [
        const Gap(ZipherSpacing.md),
        const Center(child: HitlBadge(icon: Icons.smart_toy_rounded)),
        const Gap(ZipherSpacing.md),
        Text(agent,
            textAlign: TextAlign.center,
            style: const TextStyle(color: ZipherColors.text90, fontSize: 18, fontWeight: FontWeight.w600)),
        const Gap(4),
        const Text('is asking to send',
            textAlign: TextAlign.center, style: TextStyle(color: ZipherColors.text60, fontSize: 15)),
        const Gap(ZipherSpacing.lg),
        HitlCard(
          child: Column(children: [
            Text('${formatZat(_req.amount)} ZEC',
                style: const TextStyle(
                    color: ZipherColors.text90, fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
            const Gap(6),
            Text('+ ${formatZat(_req.fee)} ZEC network fee',
                style: const TextStyle(color: ZipherColors.text60, fontSize: 14, fontFamily: 'JetBrainsMono')),
          ]),
        ),
        const Gap(ZipherSpacing.smMd),
        HitlCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            HitlDetail(
              label: 'To',
              value: groupAddress(_req.address),
              mono: true,
              trailing: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _req.address));
                  HapticFeedback.selectionClick();
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Address copied')));
                },
                child: const Icon(Icons.copy_rounded, size: 16, color: ZipherColors.text40),
              ),
            ),
            if (_req.memo != null && _req.memo!.isNotEmpty) ...[
              const Gap(ZipherSpacing.md),
              HitlDetail(label: 'Message', value: _req.memo!),
            ],
            if (_req.contextId != null && _req.contextId!.isNotEmpty) ...[
              const Gap(ZipherSpacing.md),
              HitlDetail(label: 'Reference', value: _req.contextId!),
            ],
          ]),
        ),
        const Gap(ZipherSpacing.md),
        Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ZipherRadius.full),
              child: LinearProgressIndicator(
                value: _remaining / _window,
                minHeight: 3,
                backgroundColor: ZipherColors.border,
                color: _remaining < 60 ? ZipherColors.warm : ZipherColors.cyan,
              ),
            ),
          ),
          const Gap(ZipherSpacing.smMd),
          Text(expired ? 'Expired' : '$mins:$secs',
              style: const TextStyle(color: ZipherColors.text40, fontSize: 13, fontFamily: 'JetBrainsMono')),
        ]),
        const Gap(ZipherSpacing.lg),
        if (expired) ...[
          const Text('This request expired. Ask your agent to try again if you still want to send it.',
              textAlign: TextAlign.center, style: TextStyle(color: ZipherColors.text60, fontSize: 14, height: 1.4)),
          const Gap(ZipherSpacing.md),
          ZipherWidgets.ghostButton(label: 'Close', onPressed: () => Navigator.of(context).maybePop()),
        ] else if (busy)
          const Padding(
            padding: EdgeInsets.all(ZipherSpacing.md),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          )
        else ...[
          ZipherWidgets.gradientButton(
            label: 'Approve',
            onPressed: () => _decide(true),
          ),
          const Gap(ZipherSpacing.smMd),
          ZipherWidgets.ghostButton(label: 'Decline', onPressed: () => _decide(false)),
          const Gap(ZipherSpacing.md),
          const Text('Payments can’t be reversed once sent.',
              textAlign: TextAlign.center, style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
        ],
        const Gap(ZipherSpacing.lg),
      ],
    );
  }

  Future<void> _decide(bool approved) async {
    HapticFeedback.selectionClick();
    if (approved) {
      final ok = await requireSigningAuthorization(
        context,
        actionSummary: 'Approve sending ${formatZat(_req.amount)} ZEC',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _stage = _Stage.sending);
    try {
      await HitlWatchService.instance.submitDecision(_req, approved: approved);
    } catch (_) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() => _stage = _Stage.review);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Couldn’t reach your agent. Check your connection and try again.')));
      return;
    }
    if (!mounted) return;
    approved ? HapticFeedback.mediumImpact() : HapticFeedback.lightImpact();
    setState(() => _stage = approved ? _Stage.approved : _Stage.declined);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) Navigator.of(context).maybePop();
  }
}
