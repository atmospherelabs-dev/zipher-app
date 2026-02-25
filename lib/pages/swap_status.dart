import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../services/near_intents.dart';
import '../zipher_theme.dart';
import 'utils.dart';

class SwapStatusPage extends StatefulWidget {
  final String depositAddress;
  final String? fromCurrency;
  final String? fromAmount;
  final String? toCurrency;
  final String? toAmount;

  const SwapStatusPage({
    required this.depositAddress,
    this.fromCurrency,
    this.fromAmount,
    this.toCurrency,
    this.toAmount,
  });

  @override
  State<SwapStatusPage> createState() => _SwapStatusPageState();
}

class _SwapStatusPageState extends State<SwapStatusPage> {
  final _nearApi = NearIntentsService();
  NearSwapStatus? _status;
  String? _error;
  Timer? _pollTimer;
  bool _loading = true;
  StoredSwap? _storedSwap;

  String? get _from => _storedSwap?.fromCurrency ?? widget.fromCurrency;
  String? get _fromAmt => _storedSwap?.fromAmount ?? widget.fromAmount;
  String? get _to => _storedSwap?.toCurrency ?? widget.toCurrency;
  String? get _toAmt => _storedSwap?.toAmount ?? widget.toAmount;

  @override
  void initState() {
    super.initState();
    logger.i('[SwapStatus] initState');
    _loadStoredSwap();
    _checkStatus();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStoredSwap() async {
    try {
      final map = await SwapStore.loadByDepositAddress();
      final swap = map[widget.depositAddress];
      if (swap != null && mounted) setState(() => _storedSwap = swap);
    } catch (_) {}
  }

  Future<void> _checkStatus() async {
    try {
      final status = await _nearApi.getStatus(widget.depositAddress);
      if (mounted) {
        setState(() { _status = status; _loading = false; _error = null; });
        if (status.isTerminal) _pollTimer?.cancel();
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: _loading && _status == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    Gap(topPad + 14),

                    // ── Header ──
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(
                              color: ZipherColors.cardBgElevated,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.arrow_back_rounded, size: 18,
                                color: ZipherColors.text60),
                          ),
                        ),
                        const Gap(14),
                        Text('Swap Status', style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600,
                          color: ZipherColors.text90,
                        )),
                      ],
                    ),
                    const Gap(40),

                    // ── Status icon ──
                    _statusIcon(),
                    const Gap(20),

                    // ── Status label ──
                    Text(
                      _humanLabel(_status?.status ?? 'Loading...'),
                      style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700,
                        color: ZipherColors.text90,
                      ),
                    ),
                    const Gap(8),

                    // ── Description ──
                    Text(
                      _description(),
                      textAlign: TextAlign.center,
                        style: TextStyle(
                        fontSize: 13, height: 1.5,
                        color: ZipherColors.text40,
                      ),
                    ),
                    const Gap(24),

                    // ── Swap summary card ──
                    if (_from != null && _to != null)
                      _swapSummaryCard(),

                    const Gap(12),

                    // ── TX hashes (only when available) ──
                    if (_status?.txHashIn != null)
                      _infoCard('Deposit TX', _status!.txHashIn!),
                    if (_status?.txHashIn != null && _status?.txHashOut != null)
                      const Gap(10),
                    if (_status?.txHashOut != null)
                      _infoCard('Destination TX', _status!.txHashOut!),

                    if (_error != null) ...[
                      const Gap(16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: ZipherColors.red.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: ZipherColors.red.withValues(alpha: 0.10)),
                        ),
                        child: Text(_error!, style: TextStyle(
                          fontSize: 12,
                          color: ZipherColors.red.withValues(alpha: 0.7),
                        )),
                      ),
                    ],

                    const Gap(24),

                    // ── Safe to leave hint ──
                    if (!(_status?.isTerminal ?? false)) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: ZipherColors.text10,
                            ),
                          ),
                          const Gap(8),
                            Text('Checking every 5s...', style: TextStyle(
                            fontSize: 11,
                            color: ZipherColors.text10,
                          )),
                        ],
                      ),
                      const Gap(16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: ZipherColors.cyan.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.08)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.info_outline_rounded, size: 14,
                                color: ZipherColors.cyan.withValues(alpha: 0.5)),
                            const Gap(8),
                            Flexible(
                              child: Text(
                                'You can safely leave this screen. Your swap will continue in the background.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ZipherColors.cyan.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const Gap(32),
                  ],
                ),
              ),
            ),
    );
  }

  // ─── Swap summary card ────────────────────────────────────

  Widget _swapSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Row(
        children: [
          // From side
          CurrencyIcon(symbol: _from!, size: 32),
          const Gap(10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sent', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w500,
                  color: ZipherColors.text20,
                )),
                const Gap(2),
                Text(
                  _fromAmt != null ? '$_fromAmt $_from' : _from!,
                  style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: ZipherColors.text90,
                  ),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward_rounded, size: 18,
                color: ZipherColors.text10),
          ),
          // To side
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Receiving', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w500,
                  color: ZipherColors.text20,
                )),
                const Gap(2),
                Text(
                  _toAmt != null ? '$_toAmt $_to' : _to!,
                  style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: ZipherColors.cyan.withValues(alpha: 0.8),
                  ),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Gap(10),
          CurrencyIcon(symbol: _to!, size: 32),
        ],
      ),
    );
  }

  // ─── Status icon ───────────────────────────────────────────

  Widget _statusIcon() {
    final s = _status;
    IconData icon;
    Color color;

    if (s == null || s.isPending) {
      icon = Icons.hourglass_top_rounded;
      color = ZipherColors.orange;
    } else if (s.isProcessing) {
      icon = Icons.sync_rounded;
      color = ZipherColors.cyan;
    } else if (s.isSuccess) {
      icon = Icons.check_circle_rounded;
      color = ZipherColors.green;
    } else if (s.isRefunded) {
      icon = Icons.replay_rounded;
      color = ZipherColors.purple;
    } else {
      icon = Icons.error_rounded;
      color = ZipherColors.red;
    }

    return Container(
      width: 72, height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.08),
      ),
      child: Icon(icon, size: 36, color: color.withValues(alpha: 0.6)),
    );
  }

  // ─── Info card ─────────────────────────────────────────────

  Widget _infoCard(String label, String value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w500,
            color: ZipherColors.text20,
          )),
          const Gap(8),
          Row(
            children: [
              Expanded(
                child: Text(value, style: TextStyle(
                  fontSize: 12, fontFamily: 'monospace',
                  color: ZipherColors.text60,
                ), maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              const Gap(8),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Copied'),
                      duration: const Duration(seconds: 1),
                      backgroundColor: ZipherColors.surface,
                    ),
                  );
                },
                child: Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.copy_rounded, size: 13,
                      color: ZipherColors.text20),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Helpers ───────────────────────────────────────────────

  String _humanLabel(String status) {
    final s = _status;
    if (s == null || s.isPending) return 'Deposit Sent';
    if (s.isProcessing) return 'Processing Swap';
    if (s.isSuccess) return 'Swap Complete';
    if (s.isRefunded) return 'Refunded';
    return 'Swap Failed';
  }

  String _description() {
    final s = _status;
    if (s == null || s.isPending) {
      return 'Your deposit has been sent and is waiting for on-chain confirmation.';
    }
    if (s.isProcessing) return 'Your swap is being processed. This may take a few minutes.';
    if (s.isSuccess) return 'Swap completed successfully!';
    if (s.isRefunded) return 'The swap could not be completed. Funds have been refunded.';
    return 'The swap has failed. Please contact support if funds were sent.';
  }
}
