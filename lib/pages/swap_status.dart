import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../services/near_intents.dart';
import '../zipher_theme.dart';

class SwapStatusPage extends StatefulWidget {
  final String depositAddress;
  const SwapStatusPage({required this.depositAddress});

  @override
  State<SwapStatusPage> createState() => _SwapStatusPageState();
}

class _SwapStatusPageState extends State<SwapStatusPage> {
  final _nearApi = NearIntentsService();
  NearSwapStatus? _status;
  String? _error;
  Timer? _pollTimer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _checkStatus();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
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
                              color: Colors.white.withValues(alpha: 0.06),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.arrow_back_rounded, size: 18,
                                color: Colors.white.withValues(alpha: 0.5)),
                          ),
                        ),
                        const Gap(14),
                        Text('Swap Status', style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.9),
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
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                    const Gap(8),

                    // ── Description ──
                    Text(
                      _description(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13, height: 1.5,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                    const Gap(32),

                    // ── Info cards ──
                    _infoCard('Deposit Address', widget.depositAddress),
                    if (_status?.txHashIn != null) ...[
                      const Gap(10),
                      _infoCard('Deposit TX', _status!.txHashIn!),
                    ],
                    if (_status?.txHashOut != null) ...[
                      const Gap(10),
                      _infoCard('Destination TX', _status!.txHashOut!),
                    ],

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

                    const Gap(32),

                    // ── Polling indicator ──
                    if (!(_status?.isTerminal ?? false))
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ),
                          const Gap(8),
                          Text('Checking every 5s...', style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.15),
                          )),
                        ],
                      ),

                    const Gap(32),
                  ],
                ),
              ),
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
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.25),
          )),
          const Gap(8),
          Row(
            children: [
              Expanded(
                child: Text(value, style: TextStyle(
                  fontSize: 12, fontFamily: 'monospace',
                  color: Colors.white.withValues(alpha: 0.6),
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
                    color: Colors.white.withValues(alpha: 0.04),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.copy_rounded, size: 13,
                      color: Colors.white.withValues(alpha: 0.25)),
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
    switch (status) {
      case 'PENDING':
      case 'PENDING_DEPOSIT': return 'Awaiting Deposit';
      case 'PROCESSING':
      case 'CONFIRMING': return 'Processing';
      case 'SUCCESS':
      case 'COMPLETED': return 'Completed';
      case 'REFUNDED': return 'Refunded';
      case 'FAILED':
      case 'EXPIRED': return 'Failed';
      default: return status;
    }
  }

  String _description() {
    final s = _status;
    if (s == null || s.isPending) return 'Waiting for your deposit to be confirmed on-chain.';
    if (s.isProcessing) return 'Your swap is being processed. This may take a few minutes.';
    if (s.isSuccess) return 'Swap completed successfully!';
    if (s.isRefunded) return 'The swap could not be completed. Funds have been refunded.';
    return 'The swap has failed. Please contact support if funds were sent.';
  }
}
