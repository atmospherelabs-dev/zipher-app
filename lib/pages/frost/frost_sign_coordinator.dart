import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../services/frost_service.dart';
import '../../services/wallet_service.dart';
import '../../zipher_theme.dart';

class FrostSignCoordinatorArgs {
  final String destination;
  final int zatoshis;
  final String? memoPreview;

  const FrostSignCoordinatorArgs({
    required this.destination,
    required this.zatoshis,
    this.memoPreview,
  });
}

class FrostSignCoordinatorPage extends StatefulWidget {
  final FrostSignCoordinatorArgs args;
  const FrostSignCoordinatorPage({super.key, required this.args});

  @override
  State<FrostSignCoordinatorPage> createState() =>
      _FrostSignCoordinatorPageState();
}

class _FrostSignCoordinatorPageState extends State<FrostSignCoordinatorPage> {
  String _status = 'Preparing approval session...';
  String? _sessionId;
  String? _txid;
  Object? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final walletKey = WalletService.instance.activeFrostWalletKey();
      final bundle = await WalletService.instance.prepareFrostSendForApproval();
      final session = await FrostService.instance.startSigningSession(
        walletId: walletKey,
        bundle: bundle,
        destination: widget.args.destination,
        zatoshis: widget.args.zatoshis,
        memoPreview: widget.args.memoPreview,
      );
      if (!mounted) return;
      setState(() {
        _sessionId = session.sessionId;
        _status = 'Waiting for co-signer approval';
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

  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _status = 'Collecting signature shares...';
      _error = null;
    });
    try {
      final signed = await FrostService.instance.coordinatorFinishSigning();
      final txid = await WalletService.instance.storeFrostSignedPczt(signed);
      if (!mounted) return;
      setState(() {
        _txid = txid;
        _status = 'Transaction broadcast';
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
    final zec = (widget.args.zatoshis / 100000000).toStringAsFixed(8);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        leading: IconButton(
          icon: Icon(Icons.close_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).go('/account'),
        ),
        title: Text('Shared wallet send',
            style: TextStyle(color: ZipherColors.text90, fontSize: 17)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Gap(30),
              Icon(Icons.group_rounded, color: ZipherColors.cyan, size: 42),
              const Gap(22),
              Text(_status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: ZipherColors.text90,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
              const Gap(8),
              Text('$zec ZEC requires a co-signer approval.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ZipherColors.text60, fontSize: 14)),
              const Gap(24),
              if (_sessionId != null) _Info('Session', _sessionId!),
              _Info('Recipient', _short(widget.args.destination)),
              if (_txid != null) _Info('Txid', _txid!),
              if (_error != null) ...[
                const Gap(16),
                Text('Error: $_error',
                    style: TextStyle(color: ZipherColors.red, fontSize: 13)),
              ],
              const Spacer(),
              _Button(
                label: _txid != null
                    ? 'Done'
                    : _busy
                        ? 'Working...'
                        : 'Finish after co-signer approves',
                onTap: _busy
                    ? null
                    : _txid != null
                        ? () => GoRouter.of(context).go('/account')
                        : _finish,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _short(String s) => s.length <= 24
      ? s
      : '${s.substring(0, 10)}...${s.substring(s.length - 8)}';
}

class _Info extends StatelessWidget {
  final String label;
  final String value;
  const _Info(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
          const Gap(12),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: ZipherColors.text90,
                    fontSize: 12,
                    fontFamily: 'JetBrainsMono')),
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _Button({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onTap == null
              ? ZipherColors.cardBgElevated
              : ZipherColors.cyan.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(
              color: onTap == null
                  ? ZipherColors.borderSubtle
                  : ZipherColors.cyan.withValues(alpha: 0.28)),
        ),
        child: Text(label,
            style: TextStyle(
                color: onTap == null ? ZipherColors.text20 : ZipherColors.cyan,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}
