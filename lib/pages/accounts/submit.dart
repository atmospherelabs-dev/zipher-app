import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../zipher_theme.dart';
import '../../generated/intl/messages.dart';
import '../main/home.dart' show lastShieldSubmit, shieldPending;
import '../utils.dart';
import '../widgets.dart';

class SubmitTxPage extends StatefulWidget {
  final String? txPlan;
  final String? txBin;
  SubmitTxPage({this.txPlan, this.txBin});
  @override
  State<StatefulWidget> createState() => _SubmitTxState();
}

class _SubmitTxState extends State<SubmitTxPage> {
  String? txId;
  String? error;

  @override
  void initState() {
    super.initState();
    Future(() async {
      try {
        String? txIdJs;
        if (widget.txPlan != null)
          txIdJs =
              await WarpApi.signAndBroadcast(aa.coin, aa.id, widget.txPlan!);
        if (widget.txBin != null)
          txIdJs = WarpApi.broadcast(aa.coin, widget.txBin!);
        txId = jsonDecode(txIdJs!);
        // Persist any pending outgoing memo keyed by this tx hash
        await commitOutgoingMemo(txId!);
        // Mark shield-in-progress if this was a shielding transaction
        if (shieldPending) {
          lastShieldSubmit = DateTime.now();
          shieldPending = false;
        }
      } on String catch (e) {
        error = e;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        leading: const SizedBox.shrink(),
        actions: [
          if (txId != null || error != null)
            IconButton(
              onPressed: _done,
              icon: Icon(Icons.close_rounded,
                  color: ZipherColors.text40),
            ),
        ],
      ),
      body: SafeArea(
        child: txId != null
            ? _buildSuccess()
            : error != null
                ? _buildError()
                : _buildSending(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // SENDING STATE
  // ═══════════════════════════════════════════════════════════

  Widget _buildSending() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingAnimationWidget.staggeredDotsWave(
            color: ZipherColors.cyan,
            size: 48,
          ),
          const Gap(32),
          Text(
            'Sending...',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: ZipherColors.text90,
            ),
          ),
          const Gap(8),
          Text(
            'Signing and broadcasting your transaction',
            style: TextStyle(
              fontSize: 13,
              color: ZipherColors.text20,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // SUCCESS STATE
  // ═══════════════════════════════════════════════════════════

  Widget _buildSuccess() {
    final truncatedId = txId!.length > 20
        ? '${txId!.substring(0, 10)}...${txId!.substring(txId!.length - 10)}'
        : txId!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const Spacer(flex: 2),

          // Success icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: ZipherColors.green.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_rounded,
              size: 36,
              color: ZipherColors.green.withValues(alpha: 0.8),
            ),
          ),
          const Gap(24),

          // Title
          const Text(
            'Transaction Sent',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const Gap(8),
          Text(
            'Your transaction has been broadcast to the network',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: ZipherColors.text40,
            ),
          ),
          const Gap(28),

          // TX ID card
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: txId!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Transaction ID copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.tag_rounded,
                      size: 16,
                      color: ZipherColors.text20),
                  const Gap(10),
                  Expanded(
                    child: Text(
                      truncatedId,
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: ZipherColors.text60,
                      ),
                    ),
                  ),
                  Icon(Icons.copy_rounded,
                      size: 14,
                      color: ZipherColors.text20),
                ],
              ),
            ),
          ),

          const Spacer(flex: 2),

          // Mempool link
          SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _openMempool,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.pending_outlined,
                          size: 16,
                          color:
                              ZipherColors.cyan.withValues(alpha: 0.7)),
                      const Gap(8),
                      Text(
                        'Track in Mempool',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color:
                              ZipherColors.cyan.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Gap(6),
          Text(
            'Transaction will appear on CipherScan once confirmed',
            style: TextStyle(
              fontSize: 11,
              color: ZipherColors.text20,
            ),
          ),
          const Gap(12),

          // Done button
          SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _done,
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
                      Icon(Icons.check_rounded,
                          size: 20,
                          color:
                              ZipherColors.cyan.withValues(alpha: 0.9)),
                      const Gap(8),
                      Text(
                        'Done',
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
          const Gap(16),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // ERROR STATE
  // ═══════════════════════════════════════════════════════════

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const Spacer(flex: 2),

          // Error icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: ZipherColors.red.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.close_rounded,
              size: 36,
              color: ZipherColors.red.withValues(alpha: 0.8),
            ),
          ),
          const Gap(24),

          // Title
          const Text(
            'Transaction Failed',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const Gap(8),
          Text(
            'Something went wrong while sending',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: ZipherColors.text40,
            ),
          ),
          const Gap(28),

          // Error details card
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: ZipherColors.red.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              error!,
              style: TextStyle(
                fontSize: 13,
                color: ZipherColors.red.withValues(alpha: 0.7),
              ),
            ),
          ),

          const Spacer(flex: 2),

          // Go back button
          SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _done,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBgElevated,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.arrow_back_rounded,
                          size: 18,
                          color:
                              ZipherColors.text60),
                      const Gap(8),
                      Text(
                        'Go Back',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color:
                              ZipherColors.text60,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Gap(16),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // ACTIONS
  // ═══════════════════════════════════════════════════════════

  void _openMempool() {
    launchUrl(
      Uri.parse('https://cipherscan.app/mempool'),
      mode: LaunchMode.externalApplication,
    );
  }

  void _done() {
    GoRouter.of(context).pop();
  }
}

class ExportUnsignedTxPage extends StatelessWidget {
  final String data;
  ExportUnsignedTxPage(this.data);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'EXPORT',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded,
              color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        actions: [
          IconButton(
            onPressed: () => _export(context),
            icon: Icon(Icons.save_alt_rounded,
                size: 20,
                color: ZipherColors.cyan.withValues(alpha: 0.7)),
          ),
        ],
      ),
      body: AnimatedQR.init(s.rawTransaction, s.scanQrCode, data),
    );
  }

  _export(BuildContext context) async {
    final s = S.of(context);
    await saveFile(data, 'tx.raw', s.rawTransaction);
  }
}
