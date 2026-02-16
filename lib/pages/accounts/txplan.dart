import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../appsettings.dart';
import '../../zipher_theme.dart';
import '../../store2.dart';
import '../utils.dart';
import '../../accounts.dart';
import '../../generated/intl/messages.dart';

class TxPlanPage extends StatefulWidget {
  final bool signOnly;
  final String plan;
  final String tab;
  TxPlanPage(this.plan, {required this.tab, this.signOnly = false});

  @override
  State<StatefulWidget> createState() => _TxPlanState();
}

class _TxPlanState extends State<TxPlanPage> with WithLoadingAnimation {
  late final s = S.of(context);

  @override
  Widget build(BuildContext context) {
    final report = WarpApi.transactionReport(aa.coin, widget.plan);
    final outputs = report.outputs ?? [];
    final totalAmount =
        outputs.fold<int>(0, (sum, o) => sum + o.amount);
    final fee = report.fee;
    final privacyLevel = report.privacyLevel;
    final invalidPrivacy = privacyLevel < appSettings.minPrivacyLevel;
    final canSend = aa.canPay && !invalidPrivacy;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'CONFIRM',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded,
              color: Colors.white.withValues(alpha: 0.5)),
          onPressed: () => GoRouter.of(context).pop(),
        ),
      ),
      body: wrapWithLoading(
        Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    const Gap(16),

                    // ── Hero: logo + arrow badge + amount ──
                    _buildHero(totalAmount),
                    const Gap(28),

                    // ── Recipients ──
                    ...outputs.map((o) => _buildRecipient(o)),

                    // ── Details card ──
                    _buildDetails(fee, privacyLevel),
                    const Gap(16),

                    // ── Privacy warning ──
                    if (invalidPrivacy)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: ZipherColors.orange.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                size: 18,
                                color: ZipherColors.orange
                                    .withValues(alpha: 0.7)),
                            const Gap(10),
                            Expanded(
                              child: Text(
                                s.privacyLevelTooLow,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: ZipherColors.orange
                                      .withValues(alpha: 0.7),
                                ),
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

            // ── Send button ──
            _buildSendButton(canSend),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // HERO
  // ═══════════════════════════════════════════════════════════

  Widget _buildHero(int totalAmount) {
    final fiatStr = _fiatAmount(totalAmount);

    return Column(
      children: [
        // Zcash logo with send arrow badge (matching TX detail style)
        SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Image.asset('assets/zcash_logo.png',
                      width: 42, height: 42, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: ZipherColors.cyan,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ZipherColors.bg,
                      width: 2.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.north_east_rounded,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Gap(18),

        // "You're Sending" label
        Text(
          'You\'re Sending',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
        const Gap(8),

        // Amount + ZEC on same line
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              amountToString2(totalAmount),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
            const Gap(6),
            Text(
              'ZEC',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),

        // USD value
        if (fiatStr != null) ...[
          const Gap(4),
          Text(
            fiatStr,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.25),
            ),
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // RECIPIENT
  // ═══════════════════════════════════════════════════════════

  Widget _buildRecipient(TxOutput output) {
    final addr = output.address ?? '';

    // Check if address matches a contact
    final contactName = _findContactName(addr);
    final truncated = addr.length > 16
        ? '${addr.substring(0, 8)}...${addr.substring(addr.length - 6)}'
        : addr;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: ZipherColors.cyan.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: contactName != null
                    ? Text(
                        contactName[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: ZipherColors.cyan.withValues(alpha: 0.7),
                        ),
                      )
                    : Icon(
                        Icons.person_outline_rounded,
                        size: 18,
                        color: ZipherColors.cyan.withValues(alpha: 0.5),
                      ),
              ),
            ),
            const Gap(12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'To',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                  const Gap(2),
                  if (contactName != null) ...[
                    Text(
                      contactName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.8),
                      ),
                    ),
                    const Gap(1),
                    Text(
                      truncated,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ] else
                    Text(
                      truncated,
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // DETAILS CARD
  // ═══════════════════════════════════════════════════════════

  Widget _buildDetails(int fee, int privacyLevel) {
    final privacyLabel = _privacyLabel(privacyLevel);
    final privacyColor = _privacyColor(privacyLevel);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          _detailRow('Network fee', amountToString2(fee, digits: 5) + ' ZEC'),
          const Gap(10),
          Divider(
            height: 1,
            color: Colors.white.withValues(alpha: 0.04),
          ),
          const Gap(10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Privacy',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
              Row(
                children: [
                  Icon(
                    privacyLevel >= 3
                        ? Icons.shield_rounded
                        : Icons.shield_outlined,
                    size: 14,
                    color: privacyColor.withValues(alpha: 0.7),
                  ),
                  const Gap(6),
                  Text(
                    privacyLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: privacyColor.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // SEND BUTTON
  // ═══════════════════════════════════════════════════════════

  Widget _buildSendButton(bool canSend) {
    final label = widget.signOnly ? 'Sign Transaction' : 'Send';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: SizedBox(
          width: double.infinity,
          child: Material(
            color: Colors.transparent,
            child: IgnorePointer(
              ignoring: !canSend,
              child: Opacity(
                opacity: canSend ? 1.0 : 0.4,
                child: InkWell(
                  onTap: () => _sendOrSign(context),
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
                        Icon(
                          widget.signOnly
                              ? Icons.draw_rounded
                              : Icons.send_rounded,
                          size: 20,
                          color: ZipherColors.cyan.withValues(alpha: 0.9),
                        ),
                        const Gap(10),
                        Text(
                          label,
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
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════

  String? _fiatAmount(int zat) {
    final price = marketPrice.price;
    if (price == null) return null;
    final fiat = zat / ZECUNIT * price;
    return '\$${fiat.toStringAsFixed(2)} USD';
  }

  String? _findContactName(String address) {
    for (final c in contacts.contacts) {
      if (c.address == address) return c.name;
    }
    return null;
  }

  String _privacyLabel(int level) {
    switch (level) {
      case 0:
        return 'Very Low';
      case 1:
        return 'Low';
      case 2:
        return 'Medium';
      case 3:
        return 'Fully Private';
      default:
        return 'Unknown';
    }
  }

  Color _privacyColor(int level) {
    switch (level) {
      case 0:
        return ZipherColors.red;
      case 1:
        return ZipherColors.orange;
      case 2:
        return ZipherColors.cyan;
      case 3:
        return ZipherColors.purple;
      default:
        return Colors.white;
    }
  }

  Future<void> _sendOrSign(BuildContext context) async {
    if (widget.signOnly) {
      await _sign(context);
    } else {
      _send(context);
    }
  }

  void _send(BuildContext context) {
    GoRouter.of(context).go('/${widget.tab}/submit_tx', extra: widget.plan);
  }

  Future<void> _sign(BuildContext context) async {
    try {
      await load(() async {
        final txBin = await WarpApi.signOnly(aa.coin, aa.id, widget.plan);
        GoRouter.of(context).go('/more/cold/signed', extra: txBin);
      });
    } on String catch (error) {
      await showMessageBox2(context, s.error, error);
    }
  }
}

// ═══════════════════════════════════════════════════════════
// HELPERS (kept for backward compatibility)
// ═══════════════════════════════════════════════════════════

String poolToString(S s, int pool) {
  switch (pool) {
    case 0:
      return s.transparent;
    case 1:
      return s.sapling;
  }
  return s.orchard;
}

Widget? privacyToString(BuildContext context, int privacyLevel,
    {required bool canSend,
    Future<void> Function(BuildContext context)? onSend}) {
  final m = S
      .of(context)
      .privacy(getPrivacyLevel(context, privacyLevel).toUpperCase());
  final colors = [
    ZipherColors.cyan,
    ZipherColors.purple,
    ZipherColors.purple,
    ZipherColors.green,
  ];
  return getColoredButton(context, m, colors[privacyLevel],
      canSend: canSend, onSend: onSend);
}

ElevatedButton getColoredButton(BuildContext context, String text, Color color,
    {required bool canSend,
    Future<void> Function(BuildContext context)? onSend}) {
  var foregroundColor =
      color.computeLuminance() > 0.5 ? Colors.black : Colors.white;

  final doSend = () => onSend?.call(context);
  return ElevatedButton(
      onLongPress: doSend,
      onPressed: canSend ? doSend : null,
      child: Text(text),
      style: ElevatedButton.styleFrom(
          backgroundColor: color, foregroundColor: foregroundColor));
}
