import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../zipher_theme.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../utils.dart';

class PaymentURIPage extends StatefulWidget {
  final int amount;
  PaymentURIPage({this.amount = 0});

  @override
  State<StatefulWidget> createState() => _PaymentURIState();
}

class _PaymentURIState extends State<PaymentURIPage> {
  final int availableMode = WarpApi.getAvailableAddrs(aa.coin, aa.id);

  String _truncate(String addr) {
    if (addr.length <= 24) return addr;
    return '${addr.substring(0, 12)}...${addr.substring(addr.length - 12)}';
  }

  /// Get shielded (unified) address
  String get _shieldedAddress {
    if (aa.id == 0) return '';
    return WarpApi.getAddress(aa.coin, aa.id, coinSettings.uaType);
  }

  /// Get transparent address
  String get _transparentAddress {
    if (aa.id == 0) return '';
    final hasTransparent = availableMode & 1 != 0;
    if (!hasTransparent) return '';
    return WarpApi.getAddress(aa.coin, aa.id, 1);
  }

  @override
  Widget build(BuildContext context) {
    final shielded = _shieldedAddress;
    final transparent = _transparentAddress;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded,
              color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: Text(
          'Receive',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: ZipherColors.text90,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(12),

              // Shielded address card (primary — purple accent)
              _AddressCard(
                label: 'Shielded Address',
                hint: 'Recommended for privacy',
                address: shielded,
                truncated: _truncate(shielded),
                icon: Icons.shield_outlined,
                accentColor: ZipherColors.purple,
                primary: true,
                onCopy: () => _copy(shielded),
                onQR: () => _showQR(shielded, 'Shielded Address'),
              ),

              const Gap(12),

              // Transparent address card (secondary — cyan accent)
              if (transparent.isNotEmpty)
                _AddressCard(
                  label: 'Transparent Address',
                  hint: 'For exchanges & compatibility',
                  address: transparent,
                  truncated: _truncate(transparent),
                  icon: Icons.visibility_outlined,
                  accentColor: ZipherColors.cyan,
                  primary: false,
                  onCopy: () => _copy(transparent),
                  onQR: () => _showQR(transparent, 'Transparent Address'),
                ),

              const Gap(32),

              // Request Payment button
              SizedBox(
                width: double.infinity,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _openRequestPayment(shielded),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: ZipherColors.cyan.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.qr_code_rounded,
                              size: 20,
                              color:
                                  ZipherColors.cyan.withValues(alpha: 0.9)),
                          const Gap(10),
                          Text(
                            'Request Payment',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color:
                                  ZipherColors.cyan.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const Gap(32),

              // Privacy note
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_user_outlined,
                        size: 14,
                        color: ZipherColors.text20),
                    const Gap(6),
                    Text(
                      'For privacy, always use shielded address',
                      style: TextStyle(
                        fontSize: 12,
                        color: ZipherColors.text20,
                      ),
                    ),
                  ],
                ),
              ),

              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  void _copy(String address) {
    Clipboard.setData(ClipboardData(text: address));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Address copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _showQR(String data, String title) {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZipherColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _QRSheet(data: data, title: title),
    );
  }

  void _openRequestPayment(String address) {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZipherColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _RequestPaymentSheet(address: address),
    );
  }
}

// ─── Address card ───────────────────────────────────────────

class _AddressCard extends StatelessWidget {
  final String label;
  final String hint;
  final String address;
  final String truncated;
  final IconData icon;
  final Color accentColor;
  final bool primary;
  final VoidCallback onCopy;
  final VoidCallback onQR;

  const _AddressCard({
    required this.label,
    required this.hint,
    required this.address,
    required this.truncated,
    required this.icon,
    required this.accentColor,
    required this.primary,
    required this.onCopy,
    required this.onQR,
  });

  @override
  Widget build(BuildContext context) {
    final textAlpha = primary ? 0.9 : 0.5;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: primary ? 0.06 : 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: primary ? 0.12 : 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Icon(icon,
                  size: 18,
                  color: accentColor.withValues(alpha: 0.7)),
              const Gap(8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: primary ? ZipherColors.text90 : ZipherColors.text60,
                  ),
                ),
              ),
              // Action buttons
              _SmallIconBtn(
                icon: Icons.copy_rounded,
                onTap: onCopy,
                alpha: textAlpha,
              ),
              const Gap(6),
              _SmallIconBtn(
                icon: Icons.qr_code_rounded,
                onTap: onQR,
                alpha: textAlpha,
              ),
            ],
          ),
          const Gap(10),
          // Address
          Text(
            truncated,
            style: TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: primary ? ZipherColors.text60 : ZipherColors.text40,
              letterSpacing: 0.5,
            ),
          ),
          const Gap(6),
          // Hint
          Text(
            hint,
            style: TextStyle(
              fontSize: 11,
              color: accentColor.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double alpha;

  const _SmallIconBtn({
    required this.icon,
    required this.onTap,
    required this.alpha,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 16, color: alpha > 0.7 ? ZipherColors.text60 : ZipherColors.text40),
      ),
    );
  }
}

// ─── QR Code bottom sheet ───────────────────────────────────

class _QRSheet extends StatelessWidget {
  final String data;
  final String title;

  const _QRSheet({required this.data, required this.title});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: ZipherColors.text20,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Gap(16),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: ZipherColors.text90,
              ),
            ),
            const Gap(16),
            // QR Code
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: QrImage(
                data: data,
                version: QrVersions.auto,
                size: 180,
                backgroundColor: Colors.white,
                padding: const EdgeInsets.all(12),
              ),
            ),
            const Gap(12),
            // Address text
            Text(
              data.length > 40
                  ? '${data.substring(0, 20)}...${data.substring(data.length - 20)}'
                  : data,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: ZipherColors.text40,
              ),
              textAlign: TextAlign.center,
            ),
            const Gap(16),
            // Copy + Share row
            Row(
              children: [
                Expanded(
                  child: _SheetButton(
                    label: 'Copy',
                    icon: Icons.copy_rounded,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: data));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                      Navigator.pop(context);
                    },
                  ),
                ),
                const Gap(12),
                Expanded(
                  child: _SheetButton(
                    label: 'Share',
                    icon: Icons.share_rounded,
                    onTap: () {
                      Share.share(data);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Request Payment bottom sheet ───────────────────────────

class _RequestPaymentSheet extends StatefulWidget {
  final String address;
  const _RequestPaymentSheet({required this.address});

  @override
  State<_RequestPaymentSheet> createState() => _RequestPaymentSheetState();
}

class _RequestPaymentSheetState extends State<_RequestPaymentSheet> {
  int _step = 0; // 0=amount, 1=memo, 2=result
  final _amountController = TextEditingController();
  final _memoController = TextEditingController();
  final _refController = TextEditingController();
  String _paymentURI = '';

  @override
  void dispose() {
    _amountController.dispose();
    _memoController.dispose();
    _refController.dispose();
    super.dispose();
  }

  String _buildMemo() {
    final ref = _refController.text.trim();
    final memo = _memoController.text.trim();
    if (ref.isNotEmpty) {
      return '[zipher:inv:$ref] $memo';
    }
    return memo;
  }

  void _nextStep() {
    if (_step == 0) {
      final text = _amountController.text.trim();
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter an amount')),
        );
        return;
      }
      setState(() => _step = 1);
    } else if (_step == 1) {
      final amountZat = stringToAmount(_amountController.text.trim());
      final memo = _buildMemo();
      _paymentURI = WarpApi.makePaymentURI(
          aa.coin, widget.address, amountZat, memo);
      setState(() => _step = 2);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: ZipherColors.text20,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Gap(16),
            Text(
              _step == 2 ? 'Payment Request' : 'Request Payment',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: ZipherColors.text90,
              ),
            ),
            const Gap(16),

            if (_step == 0) _buildAmountStep(),
            if (_step == 1) _buildMemoStep(),
            if (_step == 2) _buildResultStep(),
          ],
        ),
      ),
    );
  }

  Widget _buildAmountStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'How much ZEC?',
          style: TextStyle(
            fontSize: 13,
            color: ZipherColors.text40,
          ),
        ),
        const Gap(16),
        TextField(
          controller: _amountController,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            color: ZipherColors.text90,
          ),
          decoration: InputDecoration(
            hintText: '0.00',
            hintStyle: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: ZipherColors.text20,
            ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixText: 'ZEC',
            suffixStyle: TextStyle(
              fontSize: 16,
              color: ZipherColors.text40,
            ),
          ),
        ),
        const Gap(24),
        SizedBox(
          width: double.infinity,
          child: _SheetButton(
            label: 'Next',
            icon: Icons.arrow_forward_rounded,
            accent: true,
            onTap: _nextStep,
          ),
        ),
      ],
    );
  }

  Widget _buildMemoStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Payment details (optional)',
          style: TextStyle(
            fontSize: 13,
            color: ZipherColors.text40,
          ),
        ),
        const Gap(16),
        // Invoice reference field
        TextField(
          controller: _refController,
          style: TextStyle(
            fontSize: 14,
            color: ZipherColors.text90,
            fontFamily: 'monospace',
          ),
          decoration: InputDecoration(
            hintText: 'Invoice ref (e.g. INV-2026-001)',
            hintStyle: TextStyle(
              fontSize: 14,
              color: ZipherColors.text20,
            ),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Icon(
                Icons.receipt_outlined,
                size: 18,
                color: ZipherColors.purple.withValues(alpha: 0.5),
              ),
            ),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 0, minHeight: 0),
            filled: true,
            fillColor: ZipherColors.cardBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          ),
        ),
        const Gap(10),
        // Description / memo field
        TextField(
          controller: _memoController,
          autofocus: true,
          maxLines: 3,
          style: TextStyle(
            fontSize: 15,
            color: ZipherColors.text90,
          ),
          decoration: InputDecoration(
            hintText: 'Reason or description...',
            hintStyle: TextStyle(
              fontSize: 15,
              color: ZipherColors.text20,
            ),
            filled: true,
            fillColor: ZipherColors.cardBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const Gap(8),
        // Hint about invoice
        Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 12,
              color: ZipherColors.text20,
            ),
            const Gap(6),
            Expanded(
              child: Text(
                'Adding an invoice ref creates a trackable payment request',
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text20,
                ),
              ),
            ),
          ],
        ),
        const Gap(20),
        Row(
          children: [
            Expanded(
              child: _SheetButton(
                label: 'Back',
                icon: Icons.arrow_back_rounded,
                onTap: () => setState(() => _step = 0),
              ),
            ),
            const Gap(12),
            Expanded(
              child: _SheetButton(
                label: 'Generate',
                icon: Icons.qr_code_rounded,
                accent: true,
                onTap: _nextStep,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResultStep() {
    final ref = _refController.text.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Amount display
        Text(
          '${_amountController.text.trim()} ZEC',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: ZipherColors.text90,
          ),
        ),
        if (ref.isNotEmpty) ...[
          const Gap(6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ZipherColors.purple.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.receipt_outlined,
                  size: 13,
                  color: ZipherColors.purple.withValues(alpha: 0.7),
                ),
                const Gap(6),
                Text(
                  'Invoice #$ref',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: ZipherColors.purple.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_memoController.text.trim().isNotEmpty) ...[
          const Gap(4),
          Text(
            _memoController.text.trim(),
            style: TextStyle(
              fontSize: 13,
              color: ZipherColors.text40,
            ),
          ),
        ],
        const Gap(16),
        // QR code
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: QrImage(
            data: _paymentURI,
            version: QrVersions.auto,
            size: 180,
            backgroundColor: Colors.white,
            padding: const EdgeInsets.all(12),
          ),
        ),
        const Gap(16),
        // Copy + Share
        Row(
          children: [
            Expanded(
              child: _SheetButton(
                label: 'Copy',
                icon: Icons.copy_rounded,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _paymentURI));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Payment request copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ),
            const Gap(12),
            Expanded(
              child: _SheetButton(
                label: 'Share',
                icon: Icons.share_rounded,
                accent: true,
                onTap: () {
                  Share.share(_paymentURI,
                      subject: 'Zcash Payment Request');
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Shared sheet button ────────────────────────────────────

class _SheetButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool accent;

  const _SheetButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ? ZipherColors.cyan : Colors.white;
    final bgAlpha = accent ? 0.12 : 0.06;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: bgAlpha),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 18, color: color.withValues(alpha: accent ? 0.9 : 0.5)),
              const Gap(8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color.withValues(alpha: accent ? 0.9 : 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
