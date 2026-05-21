import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../services/frost_service.dart';
import '../../services/wallet_service.dart';
import '../../zipher_theme.dart';
import '../scan.dart';

class FrostJoinPage extends StatefulWidget {
  const FrostJoinPage({super.key});

  @override
  State<FrostJoinPage> createState() => _FrostJoinPageState();
}

class _FrostJoinPageState extends State<FrostJoinPage> {
  final _inviteController = TextEditingController();
  final _labelController = TextEditingController(text: 'My device');
  FrostInvite? _invite;
  FrostJoinResponse? _joinResponse;
  String? _secretHandle;
  String? _joinedAddress;
  Object? _error;
  bool _busy = false;

  @override
  void dispose() {
    _inviteController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  void _parse(String raw) {
    try {
      final invite = FrostInvite.decode(raw);
      setState(() {
        _invite = invite;
        _error = null;
        _joinResponse = null;
        _secretHandle = null;
        _joinedAddress = null;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _invite = null;
      });
    }
  }

  Future<void> _scan() async {
    final code = await scanQRCode(context);
    if (code.isNotEmpty) {
      _inviteController.text = code;
      _parse(code);
    }
  }

  Future<void> _join() async {
    final invite = _invite;
    if (invite == null || _busy) return;
    setState(() => _busy = true);
    try {
      final pending = await FrostService.instance.beginRelayJoin(
        invite: invite,
        participantLabel: _labelController.text.trim().isEmpty
            ? 'My device'
            : _labelController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _secretHandle = pending.participant2.secretPackage;
        _joinResponse = pending.response;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  Future<void> _complete() async {
    if (_busy || _joinResponse == null) return;
    setState(() => _busy = true);
    try {
      final result = await FrostService.instance.joinerCompleteFromRelay(
        walletName: _invite?.label ?? 'Shared wallet',
        chainType: WalletService.instance.isTestnetChain,
        importUfvk: (ufvk, birthday) => WalletService.instance
            .importFrostUfvkWallet(
                _invite?.label ?? 'Shared wallet', ufvk, birthday),
      );
      if (!mounted) return;
      setState(() {
        _joinedAddress = result.address;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: Text(
          'Join shared wallet',
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
          children: [
            Icon(Icons.link_rounded, size: 22, color: ZipherColors.cyan),
            const Gap(18),
            Text(
              'Join setup',
              style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
              ),
            ),
            const Gap(8),
            Text(
              'Scan a FROST invite QR or paste an invite from mobile, desktop, CLI, or an exported file.',
              style: TextStyle(
                color: ZipherColors.text60,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const Gap(28),
            _Field(
              label: 'Invite',
              controller: _inviteController,
              hint: 'zipher:frost:v1:...',
              maxLines: 3,
              onChanged: (v) {
                if (v.trim().startsWith('zipher:frost:')) _parse(v);
              },
            ),
            const Gap(10),
            Row(
              children: [
                Expanded(
                  child: _Button(
                    label: 'Scan QR',
                    icon: Icons.qr_code_scanner_rounded,
                    onTap: _scan,
                    primary: false,
                  ),
                ),
                const Gap(10),
                Expanded(
                  child: _Button(
                    label: 'Parse invite',
                    icon: Icons.check_rounded,
                    onTap: () => _parse(_inviteController.text),
                    primary: true,
                  ),
                ),
              ],
            ),
            const Gap(20),
            _Field(
              label: 'Your label',
              controller: _labelController,
              hint: 'Alice iPhone',
            ),
            const Gap(20),
            if (_error != null)
              _Card(
                child: Text(
                  'Could not parse invite: $_error',
                  style: TextStyle(color: ZipherColors.red, fontSize: 13),
                ),
              ),
            if (invite != null) ...[
              _InviteSummary(invite: invite),
              const Gap(16),
              _Button(
                label: _busy ? 'Joining...' : 'Join session',
                icon: Icons.group_add_rounded,
                onTap: _busy ? null : _join,
                primary: true,
              ),
            ],
            if (_joinResponse != null) ...[
              const Gap(18),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Round 1 ready',
                      style: TextStyle(
                        color: ZipherColors.green,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Gap(6),
                    Text(
                      'Your public DKG package is ready for the coordinator. Secret state stays in this app process.',
                      style:
                          TextStyle(color: ZipherColors.text60, fontSize: 13),
                    ),
                    const Gap(10),
                    SelectableText(
                      _joinResponse!.encode(),
                      style: TextStyle(
                        color: ZipherColors.text40,
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    if (_secretHandle != null) ...[
                      const Gap(8),
                      Text(
                        'Secret handle: $_secretHandle',
                        style:
                            TextStyle(color: ZipherColors.text20, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              const Gap(12),
              _Button(
                label:
                    _busy ? 'Waiting...' : 'Complete after coordinator accepts',
                icon: Icons.sync_rounded,
                onTap: _busy ? null : _complete,
                primary: true,
              ),
            ],
            if (_joinedAddress != null) ...[
              const Gap(18),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Joined shared wallet',
                        style: TextStyle(
                            color: ZipherColors.green,
                            fontWeight: FontWeight.w700)),
                    const Gap(8),
                    SelectableText(
                      _joinedAddress!,
                      style: TextStyle(
                        color: ZipherColors.text60,
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    const Gap(12),
                    _Button(
                      label: 'Open wallet',
                      icon: Icons.arrow_forward_rounded,
                      onTap: () => GoRouter.of(context).go('/account'),
                      primary: true,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InviteSummary extends StatelessWidget {
  final FrostInvite invite;
  const _InviteSummary({required this.invite});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Wallet', invite.label),
          _row('Threshold', '${invite.threshold} of ${invite.participants}'),
          _row('Relay', invite.relay),
          _row('Expires', invite.expiresAt.toLocal().toString()),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: TextStyle(color: ZipherColors.text40, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
        const Gap(8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          onChanged: onChanged,
          style: TextStyle(color: ZipherColors.text90, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: ZipherColors.text20),
            filled: true,
            fillColor: ZipherColors.cardBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              borderSide: BorderSide(color: ZipherColors.borderSubtle),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              borderSide: BorderSide(color: ZipherColors.borderSubtle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              borderSide:
                  BorderSide(color: ZipherColors.cyan.withValues(alpha: 0.35)),
            ),
          ),
        ),
      ],
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;

  const _Button({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: primary
              ? ZipherColors.cyan.withValues(alpha: 0.14)
              : ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(
            color: primary
                ? ZipherColors.cyan.withValues(alpha: 0.28)
                : ZipherColors.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 17,
                color: primary ? ZipherColors.cyan : ZipherColors.text60),
            const Gap(8),
            Text(
              label,
              style: TextStyle(
                color: primary ? ZipherColors.cyan : ZipherColors.text90,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: child,
    );
  }
}
