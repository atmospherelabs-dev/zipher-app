import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../services/frost_service.dart';
import '../../services/wallet_service.dart';
import '../../zipher_theme.dart';

class FrostApprovalArgs {
  final String sessionId;
  final String walletName;
  final String destination;
  final int zatoshis;
  final String feeZec;
  final String? memoPreview;

  const FrostApprovalArgs({
    required this.sessionId,
    required this.walletName,
    required this.destination,
    required this.zatoshis,
    required this.feeZec,
    this.memoPreview,
  });
}

class FrostApprovePage extends StatefulWidget {
  final FrostApprovalArgs args;
  const FrostApprovePage({super.key, required this.args});

  @override
  State<FrostApprovePage> createState() => _FrostApprovePageState();
}

class _FrostApprovePageState extends State<FrostApprovePage> {
  FrostCosignerApprovalState? _state;
  Object? _error;
  bool _loading = true;
  bool _approved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final walletKey = WalletService.instance.activeFrostWalletKey();
      final state = await FrostService.instance.receiveSigningRequest(
        walletId: walletKey,
      );
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _approve() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final walletKey = WalletService.instance.activeFrostWalletKey();
      await FrostService.instance.approveSigningRequest(walletId: walletKey);
      await FrostService.instance.cosignerFinishSigning(walletId: walletKey);
      if (!mounted) return;
      setState(() {
        _approved = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _state?.request;
    final zatoshis = (request?['zatoshis'] as int?) ?? widget.args.zatoshis;
    final destination =
        (request?['destination'] as String?) ?? widget.args.destination;
    final walletName =
        (request?['wallet_label'] as String?) ?? widget.args.walletName;
    final memoPreview =
        (request?['memo_preview'] as String?) ?? widget.args.memoPreview;
    final sessionId = _state?.sessionId ?? widget.args.sessionId;
    final zec = (zatoshis / 100000000).toStringAsFixed(8);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        leading: IconButton(
          icon: Icon(Icons.close_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: Text(
          'Approval request',
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Gap(18),
              Icon(Icons.verified_user_rounded,
                  size: 42, color: ZipherColors.cyan),
              const Gap(22),
              Text(
                'Review shared wallet spend',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ZipherColors.text90,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const Gap(8),
              Text(
                'Your share is required before this transaction can be broadcast.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ZipherColors.text60,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const Gap(28),
              _Card(
                child: Column(
                  children: [
                    _row('Wallet', walletName),
                    _row('Amount', '$zec ZEC'),
                    _row('Fee', widget.args.feeZec),
                    _row('Recipient', _short(destination), mono: true),
                    if (memoPreview?.isNotEmpty == true)
                      _row('Memo', memoPreview!),
                    _row('Session', sessionId, mono: true),
                  ],
                ),
              ),
              if (_error != null) ...[
                const Gap(14),
                Text('Error: $_error',
                    style: TextStyle(color: ZipherColors.red, fontSize: 13)),
              ],
              if (_approved) ...[
                const Gap(14),
                Text(
                  'Approved. Signature share sent to coordinator.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ZipherColors.green, fontSize: 13),
                ),
              ],
              const Spacer(),
              _Button(
                label: _loading
                    ? 'Loading...'
                    : _approved
                        ? 'Done'
                        : 'Approve',
                icon: Icons.check_rounded,
                color: ZipherColors.cyan,
                onTap: _loading
                    ? () {}
                    : _approved
                        ? () => GoRouter.of(context).go('/account')
                        : _approve,
              ),
              const Gap(12),
              _Button(
                label: 'Decline',
                icon: Icons.close_rounded,
                color: ZipherColors.red,
                onTap: () => GoRouter.of(context).pop(false),
                filled: false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _row(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
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
              textAlign: TextAlign.right,
              style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: mono ? 'JetBrainsMono' : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static String _short(String v) {
    if (v.length <= 22) return v;
    return '${v.substring(0, 10)}...${v.substring(v.length - 8)}';
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

class _Button extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool filled;

  const _Button({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          color: filled ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            const Gap(8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
