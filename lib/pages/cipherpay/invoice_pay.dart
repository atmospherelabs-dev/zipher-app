import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../coin/coins.dart';
import '../../services/cipherpay_client.dart';
import '../../services/wallet_service.dart';
import '../../zipher_theme.dart';
import '../utils.dart';

/// Beautiful, focused screen for paying a CipherPay invoice.
///
/// Lifecycle:
///   1. Construct with `invoiceRef` (UUID or `CP-XXXXXXXX` memo code).
///   2. Page fetches the invoice once on init.
///   3. User reviews merchant / amount / expiry. Pay button gates through
///      biometric, then propose+confirm via the new engine.
///   4. On success, push `InvoiceStatusPage` with the txid + invoice id.
class InvoicePayPage extends StatefulWidget {
  final String invoiceRef;

  /// Already-fetched invoice (optional). Lets the caller skip a duplicate
  /// network round-trip when the invoice was opened from a polled context.
  final CipherPayInvoice? prefetched;

  const InvoicePayPage({
    super.key,
    required this.invoiceRef,
    this.prefetched,
  });

  @override
  State<InvoicePayPage> createState() => _InvoicePayPageState();
}

class _InvoicePayPageState extends State<InvoicePayPage> {
  CipherPayInvoice? _invoice;
  Object? _error;
  bool _paying = false;
  Timer? _expiryTicker;
  StreamSubscription<CipherPayInvoice>? _statusSub;

  @override
  void initState() {
    super.initState();
    _invoice = widget.prefetched;
    if (_invoice == null) {
      _load();
    } else {
      _startExpiryTicker();
      _maybeStartStatusPolling();
    }
  }

  @override
  void dispose() {
    _expiryTicker?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final invoice = await CipherPayClient.getInvoice(widget.invoiceRef);
      if (!mounted) return;
      setState(() {
        _invoice = invoice;
        _error = null;
      });
      _startExpiryTicker();
      _maybeStartStatusPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _invoice = null;
      });
    }
  }

  void _startExpiryTicker() {
    _expiryTicker?.cancel();
    _expiryTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _maybeStartStatusPolling() {
    final invoice = _invoice;
    if (invoice == null) return;
    if (invoice.status == 'confirmed' ||
        invoice.status == 'expired' ||
        invoice.status == 'cancelled') {
      return;
    }
    _statusSub?.cancel();
    _statusSub = CipherPayClient.pollInvoice(
      invoice.id.isNotEmpty ? invoice.id : widget.invoiceRef,
      interval: const Duration(seconds: 5),
      timeout: null,
    ).listen(
      (inv) {
        if (!mounted) return;
        setState(() => _invoice = inv);
        if (inv.status == 'confirmed' ||
            inv.status == 'expired' ||
            inv.status == 'cancelled') {
          _statusSub?.cancel();
        }
      },
    );
  }

  void _openReceipt() {
    final invoice = _invoice;
    if (invoice == null) return;
    final txid = invoice.detectedTxid;
    if (txid == null || txid.isEmpty) return;
    GoRouter.of(context).push(
      '/invoice/status',
      extra: InvoiceStatusArgs(
        invoiceId: invoice.id,
        memoCode: invoice.memoCode,
        txid: txid,
        productName: invoice.productName,
        merchantName: invoice.merchantName,
        amount: invoice.amount,
        currency: invoice.currency,
        priceEur: invoice.priceEur,
        priceZec: invoice.priceZec,
      ),
    );
  }

  Duration? get _untilExpiry {
    final invoice = _invoice;
    if (invoice == null) return null;
    final ts = DateTime.tryParse(invoice.expiresAt);
    if (ts == null) return null;
    return ts.difference(DateTime.now().toUtc());
  }

  bool get _expired {
    final invoice = _invoice;
    if (invoice == null) return false;
    if (invoice.status == 'expired' || invoice.status == 'cancelled') {
      return true;
    }
    final delta = _untilExpiry;
    return delta != null && delta.isNegative;
  }

  bool get _alreadyPaid {
    final s = _invoice?.status;
    return s == 'detected' || s == 'confirmed';
  }

  Future<void> _pay() async {
    final invoice = _invoice;
    if (invoice == null || _paying) return;
    if (_expired || _alreadyPaid) return;

    final wallet = WalletService.instance;
    final reviewedWallet = wallet.activeWalletId;
    final reviewedNetwork = isTestnet;
    setState(() => _paying = true);
    final authed = await requireSigningAuthorization(
      context,
      actionSummary: invoice.productName?.isNotEmpty == true
          ? 'Pay invoice for ${invoice.productName}'
          : 'Pay CipherPay invoice',
    );
    if (!mounted) return;
    if (!authed ||
        reviewedWallet == null ||
        wallet.activeWalletId != reviewedWallet ||
        isTestnet != reviewedNetwork ||
        _expired) {
      setState(() => _paying = false);
      return;
    }

    try {
      final amountZat =
          invoice.priceZatoshis ?? (invoice.priceZec * 100000000).round();
      await WalletService.instance.proposeSend(
        invoice.paymentAddress,
        amountZat,
        memo: invoice.memoCode,
        isMax: false,
      );
      final txid = await wallet.confirmSend(
          expectedRevision: wallet.proposalRevision,
          expectedWalletId: reviewedWallet,
          expectedTestnet: reviewedNetwork);
      if (!mounted) return;
      GoRouter.of(context).pushReplacement(
        '/invoice/status',
        extra: InvoiceStatusArgs(
          invoiceId: invoice.id,
          memoCode: invoice.memoCode,
          txid: txid,
          productName: invoice.productName,
          merchantName: invoice.merchantName,
          amount: invoice.amount,
          currency: invoice.currency,
          priceEur: invoice.priceEur,
          priceZec: invoice.priceZec,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _paying = false);
      _snack('Payment failed: $e', isError: true);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    final color = isError ? ZipherColors.red : ZipherColors.green;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: TextStyle(color: ZipherColors.text90, fontSize: 13)),
        backgroundColor: ZipherColors.surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          side: BorderSide(color: color.withValues(alpha: 0.2)),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        title: Text('Pay invoice',
            style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.close_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _ErrorState(
        message: _friendlyError(_error!),
        onRetry: () {
          setState(() => _error = null);
          _load();
        },
      );
    }
    final invoice = _invoice;
    if (invoice == null) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.white,
        ),
      );
    }
    return _InvoiceBody(
      invoice: invoice,
      expired: _expired,
      alreadyPaid: _alreadyPaid,
      untilExpiry: _untilExpiry,
      paying: _paying,
      onPay: _pay,
      onViewReceipt: _openReceipt,
    );
  }

  static String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('404')) return 'Invoice not found.';
    if (msg.contains('410') || msg.contains('expired')) {
      return 'This invoice has expired.';
    }
    if (msg.contains('failed') || msg.contains('Failed')) {
      return 'Could not reach CipherPay. Check your connection and try again.';
    }
    return 'Something went wrong: $msg';
  }
}

class _InvoiceBody extends StatelessWidget {
  final CipherPayInvoice invoice;
  final bool expired;
  final bool alreadyPaid;
  final Duration? untilExpiry;
  final bool paying;
  final VoidCallback onPay;
  final VoidCallback onViewReceipt;

  const _InvoiceBody({
    required this.invoice,
    required this.expired,
    required this.alreadyPaid,
    required this.untilExpiry,
    required this.paying,
    required this.onPay,
    required this.onViewReceipt,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Gap(ZipherSpacing.md),
          _Header(invoice: invoice),
          const Gap(ZipherSpacing.lg),
          _AmountCard(invoice: invoice),
          const Gap(ZipherSpacing.smMd),
          _MetaCard(
            invoice: invoice,
            expired: expired,
            untilExpiry: untilExpiry,
            alreadyPaid: alreadyPaid,
          ),
          const Spacer(),
          if (alreadyPaid)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusBanner(
                  icon: Icons.check_circle_rounded,
                  color: ZipherColors.green,
                  title: invoice.status == 'confirmed'
                      ? 'Payment confirmed'
                      : 'Payment accepted',
                  subtitle: invoice.status == 'confirmed'
                      ? 'This invoice is fully settled. You don\'t need to pay again.'
                      : 'CipherPay sees your payment. The merchant has been notified — on-chain confirmation may take a few minutes.',
                ),
                if (invoice.detectedTxid?.isNotEmpty == true) ...[
                  const Gap(ZipherSpacing.smMd),
                  _ReceiptButton(onTap: onViewReceipt),
                ],
              ],
            )
          else if (expired)
            _StatusBanner(
              icon: Icons.access_time_filled_rounded,
              color: ZipherColors.orange,
              title: 'This invoice has expired',
              subtitle:
                  'Ask the merchant for a fresh link. Paying anyway would not credit you.',
            )
          else
            _PayButton(
              priceZec: invoice.priceZec,
              busy: paying,
              onTap: onPay,
            ),
          const Gap(ZipherSpacing.smMd),
          _FooterNote(),
          const Gap(ZipherSpacing.md),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final CipherPayInvoice invoice;
  const _Header({required this.invoice});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: Image.asset(
            'assets/cipherpay_logo_mark.png',
            width: 30,
            height: 38,
            fit: BoxFit.contain,
          ),
        ),
        const Gap(ZipherSpacing.smMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                invoice.merchantName?.isNotEmpty == true
                    ? invoice.merchantName!
                    : invoice.productName?.isNotEmpty == true
                        ? invoice.productName!
                        : 'CipherPay invoice',
                style: TextStyle(
                  color: ZipherColors.text90,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const Gap(2),
              Text(
                invoice.productName?.isNotEmpty == true &&
                        invoice.merchantName?.isNotEmpty == true
                    ? invoice.productName!
                    : 'Verified by CipherPay',
                style: TextStyle(
                  color: ZipherColors.text40,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AmountCard extends StatelessWidget {
  final CipherPayInvoice invoice;
  const _AmountCard({required this.invoice});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ZipherSpacing.lg,
        vertical: ZipherSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: ZipherColors.cardBgElevated,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        children: [
          Text(
            '${_formatFiat(invoice.amount)} ${invoice.currency}',
            style: TextStyle(
              color: ZipherColors.text90,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const Gap(ZipherSpacing.xs),
          Text(
            '${_formatZec(invoice.priceZec)} ZEC',
            style: TextStyle(
              color: ZipherColors.text60,
              fontSize: 15,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ],
      ),
    );
  }

  static String _formatZec(double v) {
    if (v == 0) return '0.00';
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(8);
  }

  static String _formatFiat(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }
}

class _MetaCard extends StatelessWidget {
  final CipherPayInvoice invoice;
  final bool expired;
  final Duration? untilExpiry;
  final bool alreadyPaid;
  const _MetaCard({
    required this.invoice,
    required this.expired,
    required this.untilExpiry,
    required this.alreadyPaid,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ZipherSpacing.smMd),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        children: [
          _row(
            context,
            label: 'Memo code',
            value: invoice.memoCode,
            mono: true,
            copyable: true,
          ),
          const Gap(ZipherSpacing.smMd),
          _row(
            context,
            label: 'Recipient',
            value: _shortAddr(invoice.paymentAddress),
            mono: true,
            copyable: true,
            copyText: invoice.paymentAddress,
          ),
          const Gap(ZipherSpacing.smMd),
          _row(
            context,
            label: 'Status',
            value: _statusLabel(invoice.status, expired),
            valueColor: _statusColor(invoice.status, expired),
          ),
          if (!alreadyPaid && !expired && untilExpiry != null) ...[
            const Gap(ZipherSpacing.smMd),
            _row(
              context,
              label: 'Expires in',
              value: _formatDuration(untilExpiry!),
              valueColor: untilExpiry!.inMinutes < 5
                  ? ZipherColors.orange
                  : ZipherColors.text90,
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required String label,
    required String value,
    bool mono = false,
    bool copyable = false,
    String? copyText,
    Color? valueColor,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(
            label,
            style: TextStyle(
              color: ZipherColors.text40,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          flex: 5,
          child: GestureDetector(
            onTap: copyable
                ? () {
                    HapticFeedback.selectionClick();
                    Clipboard.setData(
                      ClipboardData(text: copyText ?? value),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Copied',
                            style: TextStyle(
                                color: ZipherColors.text90, fontSize: 13)),
                        backgroundColor: ZipherColors.surface,
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                : null,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: valueColor ?? ZipherColors.text90,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFamily: mono ? 'JetBrainsMono' : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  static String _shortAddr(String a) {
    if (a.length <= 16) return a;
    return '${a.substring(0, 8)}…${a.substring(a.length - 6)}';
  }

  static String _statusLabel(String status, bool expired) {
    if (expired) return 'Expired';
    switch (status) {
      case 'pending':
        return 'Awaiting payment';
      case 'detected':
        return 'Payment accepted';
      case 'confirmed':
        return 'Confirmed';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status;
    }
  }

  static Color _statusColor(String status, bool expired) {
    if (expired) return ZipherColors.orange;
    switch (status) {
      case 'confirmed':
        return ZipherColors.green;
      case 'detected':
        return ZipherColors.cyan;
      case 'cancelled':
        return ZipherColors.red;
      default:
        return ZipherColors.text90;
    }
  }

  static String _formatDuration(Duration d) {
    if (d.isNegative) return 'expired';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }
}

class _PayButton extends StatelessWidget {
  final double priceZec;
  final bool busy;
  final VoidCallback onTap;
  const _PayButton(
      {required this.priceZec, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: ZipherColors.cyan.withValues(alpha: 0.14),
          border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          boxShadow: [
            BoxShadow(
              color: ZipherColors.cyan.withValues(alpha: 0.18),
              blurRadius: 24,
              spreadRadius: -6,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: busy
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(ZipherColors.cyan),
                ),
              )
            : Text(
                'Pay ${priceZec.toStringAsFixed(priceZec >= 1 ? 4 : 6)} ZEC',
                style: TextStyle(
                  color: ZipherColors.cyan,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }
}

class _ReceiptButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ReceiptButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: ZipherColors.green.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.green.withValues(alpha: 0.25)),
        ),
        alignment: Alignment.center,
        child: Text(
          'View payment receipt',
          style: TextStyle(
            color: ZipherColors.green,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  const _StatusBanner({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ZipherSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const Gap(ZipherSpacing.smMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                      color: ZipherColors.text90,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    )),
                const Gap(2),
                Text(subtitle,
                    style: TextStyle(
                      color: ZipherColors.text60,
                      fontSize: 12,
                      height: 1.4,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Text(
      'Payment is shielded. CipherPay sees the on-chain transaction but not your wallet.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: ZipherColors.text40,
        fontSize: 11,
        height: 1.4,
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZipherColors.pagePadding),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 32, color: ZipherColors.text40),
            const Gap(ZipherSpacing.md),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ZipherColors.text60,
                  fontSize: 14,
                  height: 1.45,
                )),
            const Gap(ZipherSpacing.lg),
            TextButton(
              onPressed: onRetry,
              child: Text('Retry', style: TextStyle(color: ZipherColors.cyan)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Payload passed from [`InvoicePayPage`] to [`InvoiceStatusPage`].
class InvoiceStatusArgs {
  final String invoiceId;
  final String memoCode;
  final String txid;
  final String? productName;
  final String? merchantName;
  final double amount;
  final String currency;
  final double priceEur;
  final double priceZec;

  const InvoiceStatusArgs({
    required this.invoiceId,
    required this.memoCode,
    required this.txid,
    required this.productName,
    required this.merchantName,
    required this.amount,
    required this.currency,
    required this.priceEur,
    required this.priceZec,
  });
}
