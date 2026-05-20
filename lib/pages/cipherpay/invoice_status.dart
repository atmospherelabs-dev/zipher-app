import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../services/cipherpay_client.dart';
import '../../zipher_theme.dart';
import 'invoice_pay.dart' show InvoiceStatusArgs;

/// Post-payment status page. Polls the invoice on a slow cadence (5s) until
/// CipherPay reports `confirmed`, the invoice expires, or the user backs out.
///
/// Privacy: this page only contacts CipherPay after the user has *broadcast*
/// a payment for the invoice. The buyer's IP is already linked to the tx by
/// virtue of having submitted it; revealing the invoice id to the same server
/// adds no additional metadata.
class InvoiceStatusPage extends StatefulWidget {
  final InvoiceStatusArgs args;

  const InvoiceStatusPage({super.key, required this.args});

  @override
  State<InvoiceStatusPage> createState() => _InvoiceStatusPageState();
}

class _InvoiceStatusPageState extends State<InvoiceStatusPage> {
  StreamSubscription<CipherPayInvoice>? _sub;
  CipherPayInvoice? _latest;
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _sub?.cancel();
    setState(() => _timedOut = false);
    _sub = CipherPayClient.pollInvoice(
      widget.args.invoiceId,
      interval: const Duration(seconds: 5),
      timeout: null,
    ).listen(
      (inv) {
        if (!mounted) return;
        setState(() => _latest = inv);
      },
      onDone: () {
        if (!mounted) return;
        // If we hit timeout without a terminal status, surface that.
        final terminal = _latest?.status == 'confirmed' ||
            _latest?.status == 'expired' ||
            _latest?.status == 'cancelled';
        if (!terminal) {
          setState(() => _timedOut = true);
        }
      },
    );
  }

  String get _phase {
    final s = _latest?.status;
    if (_timedOut && s != 'confirmed') return 'slow';
    if (s == 'confirmed') return 'confirmed';
    if (s == 'detected') return 'detected';
    if (s == 'expired') return 'expired';
    if (s == 'cancelled') return 'cancelled';
    return 'waiting';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: ZipherColors.bg,
        appBar: AppBar(
          backgroundColor: ZipherColors.bg,
          title: Text('Payment',
              style: TextStyle(
                  color: ZipherColors.text90,
                  fontSize: 17,
                  fontWeight: FontWeight.w600)),
          leading: IconButton(
            icon: Icon(Icons.close_rounded, color: ZipherColors.text60),
            onPressed: () => GoRouter.of(context).go('/account'),
          ),
        ),
        body: SafeArea(child: _build()),
      ),
    );
  }

  Widget _build() {
    final phase = _phase;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Gap(ZipherSpacing.md),
          _Header(args: widget.args),
          const Gap(ZipherSpacing.lg),
          Expanded(child: _PhaseDisplay(phase: phase, args: widget.args)),
          if (phase == 'slow') ...[
            _ActionButton(
              label: 'Check again',
              onTap: _startPolling,
            ),
            const Gap(ZipherSpacing.smMd),
          ],
          _DoneButton(
            primary: phase == 'confirmed',
            onTap: () => GoRouter.of(context).go('/account'),
          ),
          const Gap(ZipherSpacing.md),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final InvoiceStatusArgs args;
  const _Header({required this.args});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ZipherSpacing.lg,
        vertical: ZipherSpacing.md,
      ),
      decoration: BoxDecoration(
        color: ZipherColors.cardBgElevated,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            args.merchantName?.isNotEmpty == true
                ? args.merchantName!
                : args.productName?.isNotEmpty == true
                    ? args.productName!
                    : 'CipherPay invoice',
            style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 15,
                fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const Gap(ZipherSpacing.xs),
          if (args.productName?.isNotEmpty == true &&
              args.merchantName?.isNotEmpty == true) ...[
            const Gap(ZipherSpacing.xs),
            Text(
              args.productName!,
              style: TextStyle(
                color: ZipherColors.text40,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Gap(ZipherSpacing.xs),
          Row(
            children: [
              Text(
                '${_formatFiat(args.amount)} ${args.currency}',
                style: TextStyle(
                    color: ZipherColors.text90,
                    fontSize: 22,
                    fontWeight: FontWeight.w700),
              ),
              const Gap(ZipherSpacing.sm),
              Text(
                '${args.priceZec.toStringAsFixed(args.priceZec >= 1 ? 4 : 6)} ZEC',
                style: TextStyle(
                  color: ZipherColors.text40,
                  fontSize: 13,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatFiat(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }
}

class _PhaseDisplay extends StatelessWidget {
  final String phase;
  final InvoiceStatusArgs args;
  const _PhaseDisplay({required this.phase, required this.args});

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    final String title;
    final String subtitle;
    final bool spin;
    switch (phase) {
      case 'waiting':
        icon = Icons.send_rounded;
        color = ZipherColors.cyan;
        title = 'Broadcasting to the network';
        subtitle =
            'Your transaction was sent. CipherPay will pick it up in a few seconds.';
        spin = true;
        break;
      case 'detected':
        icon = Icons.check_circle_rounded;
        color = ZipherColors.green;
        title = 'Payment accepted';
        subtitle =
            'CipherPay sees your transaction. The merchant can accept the checkout while Zcash confirms it.';
        spin = true;
        break;
      case 'confirmed':
        icon = Icons.check_circle_rounded;
        color = ZipherColors.green;
        title = 'Payment confirmed';
        subtitle = 'You\'re all set. The merchant has been notified.';
        spin = false;
        break;
      case 'slow':
        icon = Icons.access_time_rounded;
        color = ZipherColors.warm;
        title = 'Taking longer than usual';
        subtitle =
            'Your transaction was sent. The Zcash network can take a few minutes — tap below to recheck.';
        spin = false;
        break;
      case 'expired':
        icon = Icons.error_outline_rounded;
        color = ZipherColors.orange;
        title = 'Invoice expired before confirmation';
        subtitle =
            'Your transaction is on-chain but CipherPay can no longer credit this invoice. Contact the merchant with your txid below.';
        spin = false;
        break;
      case 'cancelled':
        icon = Icons.cancel_outlined;
        color = ZipherColors.red;
        title = 'Invoice was cancelled';
        subtitle =
            'The merchant cancelled this invoice. Your funds are still in your wallet if the payment hasn\'t broadcast.';
        spin = false;
        break;
      default:
        icon = Icons.help_outline_rounded;
        color = ZipherColors.text60;
        title = 'Working…';
        subtitle = '';
        spin = true;
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 92,
          height: 92,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (spin)
                SizedBox(
                  width: 92,
                  height: 92,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      color.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 30),
              ),
            ],
          ),
        ),
        const Gap(ZipherSpacing.lg),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Gap(ZipherSpacing.sm),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ZipherColors.text60,
            fontSize: 13,
            height: 1.45,
          ),
        ),
        const Gap(ZipherSpacing.lg),
        _TxRow(txid: args.txid),
      ],
    );
  }
}

class _TxRow extends StatelessWidget {
  final String txid;
  const _TxRow({required this.txid});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Clipboard.setData(ClipboardData(text: txid));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Txid copied',
                style: TextStyle(color: ZipherColors.text90, fontSize: 13)),
            backgroundColor: ZipherColors.surface,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ZipherSpacing.md,
          vertical: ZipherSpacing.smMd,
        ),
        decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(Icons.tag_rounded, size: 14, color: ZipherColors.text40),
            const Gap(ZipherSpacing.sm),
            Expanded(
              child: Text(
                _short(txid),
                style: TextStyle(
                  color: ZipherColors.text60,
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.content_copy_rounded,
                size: 14, color: ZipherColors.text40),
          ],
        ),
      ),
    );
  }

  static String _short(String txid) {
    if (txid.length <= 24) return txid;
    return '${txid.substring(0, 12)}…${txid.substring(txid.length - 8)}';
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ActionButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(
              color: ZipherColors.text90,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            )),
      ),
    );
  }
}

class _DoneButton extends StatelessWidget {
  final bool primary;
  final VoidCallback onTap;
  const _DoneButton({required this.primary, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
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
        alignment: Alignment.center,
        child: Text(
          primary ? 'Done' : 'Back to wallet',
          style: TextStyle(
            color: primary ? ZipherColors.cyan : ZipherColors.text90,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
