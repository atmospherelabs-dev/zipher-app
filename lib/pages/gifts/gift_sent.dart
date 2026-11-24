import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/app_log.dart';
import '../../services/gift_engine.dart';
import '../../services/gift_links.dart';
import '../../services/wallet_service.dart';
import '../../zipher_theme.dart';
import '../accounts/pay_uri.dart' show shareQr;

/// A gift you sent: share its link, see whether it was claimed, or take it
/// back if it wasn't.
class GiftSentPage extends StatefulWidget {
  const GiftSentPage({super.key, required this.gift});
  final SentGift gift;
  @override
  State<GiftSentPage> createState() => _GiftSentPageState();
}

class _GiftSentPageState extends State<GiftSentPage> {
  late SentGift _gift = widget.gift;
  bool _showQr = false;
  bool _checking = false;
  String? _note;
  final _shareKey = GlobalKey();

  Future<void> _share() async {
    final box = _shareKey.currentContext?.findRenderObject() as RenderBox?;
    final text = _gift.message == null
        ? 'A gift of ${GiftMath.formatZec(_gift.amount)} ZEC for you. Open this link to claim it:\n${_gift.link}'
        : '${_gift.message}\n\nClaim your ${GiftMath.formatZec(_gift.amount)} ZEC: ${_gift.link}';
    await shareQr(
        data: _gift.link,
        filename: 'zec-gift',
        subject: 'A ZEC gift for you',
        text: text,
        originBox: box);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _gift.link));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Link copied. Anyone who has it can claim the gift.')));
  }

  /// Checks the gift wallet on chain: an empty funded gift was claimed.
  Future<void> _check() async {
    setState(() {
      _checking = true;
      _note = null;
    });
    String? handle;
    try {
      handle = await GiftEngine.instance.open(_gift.link);
      final balance = await GiftEngine.instance.check(handle);
      final walletId = WalletService.instance.activeWalletId;
      switch (balance.state) {
        case GiftClaimState.empty when balance.claimed:
          if (walletId != null &&
              (_gift.status == SentGiftStatus.funded ||
                  _gift.status == SentGiftStatus.uncertain)) {
            final next = _gift.apply(SentGiftEvent.foundEmpty);
            await SentGiftStore.instance.save(walletId, next);
            _gift = next;
          }
          _note = 'Claimed. The gift wallet is empty.';
        case GiftClaimState.empty:
          _note = 'Nothing there yet. If you just sent it, it appears once mined.';
        case GiftClaimState.pending:
          _note = 'Funded and confirming. It can be claimed in a few minutes.';
        default:
          _note =
              'Not claimed yet: ${GiftMath.formatZec(balance.spendable)} ZEC is waiting.';
      }
    } catch (e) {
      AppLog.instance.event('gift', 'check_failed', error: e);
      _note = 'Couldn’t check right now. Try again.';
    } finally {
      if (handle != null) await GiftEngine.instance.close(handle);
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _gift;
    final live = g.status.shareable;
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Column(children: [
        ZipherWidgets.pageHeader(context, 'Gift'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                ZipherColors.pagePadding, 8, ZipherColors.pagePadding, 24),
            children: [
              Center(
                child: Column(children: [
                  const Icon(Icons.card_giftcard_rounded,
                      size: 48, color: ZipherColors.warm),
                  const SizedBox(height: ZipherSpacing.smMd),
                  Text('${GiftMath.formatZec(g.amount)} ZEC',
                      style: ZipherType.hero.copyWith(fontSize: 38)),
                  const SizedBox(height: 4),
                  Text(g.status.label, style: ZipherType.subhead),
                  if (g.message != null) ...[
                    const SizedBox(height: ZipherSpacing.md),
                    Text('“${g.message}”',
                        textAlign: TextAlign.center, style: ZipherType.body),
                  ],
                ]),
              ),
              const SizedBox(height: ZipherSpacing.lg),
              if (g.status == SentGiftStatus.uncertain)
                ZipherWidgets.errorBanner(
                    'The wallet stopped while funding this gift. Check your history before sharing; never fund it again.'),
              if (live) ...[
                if (_showQr)
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(ZipherRadius.lg)),
                      padding: const EdgeInsets.all(12),
                      child: QrImage(
                          data: g.link,
                          version: QrVersions.auto,
                          size: 220,
                          backgroundColor: Colors.white),
                    ),
                  ),
                if (_showQr) const SizedBox(height: ZipherSpacing.md),
                ZipherWidgets.surfaceCard(
                  padding: const EdgeInsets.all(ZipherSpacing.md),
                  borderColor: ZipherColors.warm.withValues(alpha: 0.35),
                  child: const Row(children: [
                    Icon(Icons.key_rounded, size: 18, color: ZipherColors.warm),
                    SizedBox(width: ZipherSpacing.sm),
                    Expanded(
                      child: Text(
                          'This link is the gift. Anyone who has it can claim the ZEC, so send it privately.',
                          style: ZipherType.subhead),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: ZipherSpacing.lg),
              ZipherWidgets.group([
                if (live)
                  ZipherWidgets.row(
                      icon: _showQr ? Icons.visibility_off_rounded : Icons.qr_code_rounded,
                      title: _showQr ? 'Hide QR code' : 'Show QR code',
                      subtitle: 'For handing over in person',
                      chevron: false,
                      onTap: () => setState(() => _showQr = !_showQr)),
                if (live)
                  ZipherWidgets.row(
                      icon: Icons.copy_rounded,
                      title: 'Copy link',
                      chevron: false,
                      onTap: _copy),
                if (g.status.mayBeFunded)
                  ZipherWidgets.row(
                      icon: Icons.sync_rounded,
                      title: 'Check if claimed',
                      subtitle: _note,
                      trailing: _checking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                      chevron: false,
                      onTap: _checking ? null : _check),
                if (live)
                  ZipherWidgets.row(
                      icon: Icons.undo_rounded,
                      title: 'Take it back',
                      subtitle: 'Claim it into your own wallet',
                      onTap: () => GoRouter.of(context)
                          .push('/gifts/claim', extra: g.link)),
              ]),
            ],
          ),
        ),
        if (live)
          ZipherWidgets.bottomActions([
            KeyedSubtree(
              key: _shareKey,
              child: ZipherButton(
                  label: 'Share gift', icon: Icons.ios_share_rounded, onPressed: _share),
            ),
          ]),
      ]),
    );
  }
}
