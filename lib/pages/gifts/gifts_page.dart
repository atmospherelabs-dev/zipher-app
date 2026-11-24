import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../coin/coins.dart';
import '../../services/gift_engine.dart';
import '../../services/gift_links.dart';
import '../../services/wallet_service.dart';
import '../../zipher_theme.dart';
import '../scan.dart';

/// Gift ZEC: send a link anyone can claim, or claim one you received.
class GiftsPage extends StatefulWidget {
  const GiftsPage({super.key});
  @override
  State<GiftsPage> createState() => _GiftsPageState();
}

class _GiftsPageState extends State<GiftsPage> {
  List<SentGift>? _sent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = WalletService.instance.activeWalletId;
    if (id == null) return;
    final list = await SentGiftStore.instance.list(id, isTestnet);
    if (mounted) {
      setState(() => _sent =
          list.where((g) => g.status != SentGiftStatus.discarded).toList());
    }
  }

  Future<void> _claim() async {
    final link = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const _ClaimInputSheet());
    if (link == null || !mounted) return;
    await GoRouter.of(context).push('/gifts/claim', extra: link);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sent;
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Column(children: [
        ZipherWidgets.pageHeader(context, 'Gift ZEC'),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(ZipherColors.pagePadding, 8,
                  ZipherColors.pagePadding, 40),
              children: [
                const _Hero(),
                const SizedBox(height: ZipherSpacing.lg),
                ZipherWidgets.group([
                  ZipherWidgets.row(
                      icon: Icons.card_giftcard_rounded,
                      iconColor: ZipherColors.warm,
                      title: 'Send a gift',
                      subtitle: 'Share a link. They don’t need a wallet yet.',
                      onTap: () async {
                        await GoRouter.of(context).push('/gifts/new');
                        _load();
                      }),
                  ZipherWidgets.row(
                      icon: Icons.redeem_rounded,
                      iconColor: ZipherColors.cyan,
                      title: 'Claim a gift',
                      subtitle: 'Paste or scan a gift link',
                      onTap: _claim),
                ]),
                const SizedBox(height: ZipherSpacing.lg),
                if (sent != null && sent.isNotEmpty) ...[
                  ZipherWidgets.sectionLabel('Gifts you sent'),
                  const SizedBox(height: ZipherSpacing.sm),
                  ZipherWidgets.group([
                    for (final g in sent)
                      ZipherWidgets.row(
                          icon: Icons.card_giftcard_rounded,
                          iconColor: _color(g.status),
                          title: '${GiftMath.formatZec(g.amount)} ZEC',
                          subtitle:
                              '${g.status.label} · ${DateFormat('MMM d, HH:mm').format(g.createdAt.toLocal())}',
                          onTap: () async {
                            await GoRouter.of(context)
                                .push('/gifts/sent', extra: g);
                            _load();
                          }),
                  ]),
                ],
                const SizedBox(height: ZipherSpacing.lg),
                const Text(
                    'A gift is a small shielded wallet whose key is inside the link. '
                    'Whoever has the link can claim it, so share it only with the person it’s for. '
                    'Links work in Zipher, Zodl and Vizor.',
                    style: ZipherType.footnote),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Color _color(SentGiftStatus s) => switch (s) {
        SentGiftStatus.funded => ZipherColors.cyan,
        SentGiftStatus.claimed || SentGiftStatus.reclaimed => ZipherColors.green,
        SentGiftStatus.uncertain => ZipherColors.warm,
        _ => ZipherColors.text40,
      };
}

class _Hero extends StatelessWidget {
  const _Hero();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(ZipherSpacing.lg),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ZipherRadius.card),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              ZipherColors.warm.withValues(alpha: 0.16),
              ZipherColors.cyan.withValues(alpha: 0.08),
            ],
          ),
          border: Border.all(color: ZipherColors.borderLight, width: 0.5),
        ),
        child: const Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Give someone their first ZEC', style: ZipherType.title),
              SizedBox(height: 6),
              Text('Private by default. The gift is shielded, and the link never touches a server.',
                  style: ZipherType.subhead),
            ]),
          ),
          SizedBox(width: ZipherSpacing.md),
          Icon(Icons.card_giftcard_rounded, size: 44, color: ZipherColors.warm),
        ]),
      );
}

class _ClaimInputSheet extends StatefulWidget {
  const _ClaimInputSheet();
  @override
  State<_ClaimInputSheet> createState() => _ClaimInputSheetState();
}

class _ClaimInputSheetState extends State<_ClaimInputSheet> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final t = text.trim();
    if (!GiftEngine.instance.looksLikeLink(t)) {
      setState(() => _error = 'That doesn’t look like a gift link.');
      return;
    }
    Navigator.of(context).pop(t);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    // The link is a secret: don't leave it on the clipboard once read.
    if (text.isNotEmpty && GiftEngine.instance.looksLikeLink(text)) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
    _controller.text = text.trim();
    _submit(text);
  }

  void _scan() {
    GoRouter.of(context).push('/scan', extra: ScanQRContext((code) {
      if (!GiftEngine.instance.looksLikeLink(code)) return false;
      Navigator.of(context).pop(code.trim());
      return true;
    }));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: ZipherWidgets.sheetDecoration,
      padding: EdgeInsets.fromLTRB(ZipherColors.pagePadding, 0,
          ZipherColors.pagePadding, bottom + ZipherSpacing.lg),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ZipherWidgets.sheetHandle(),
          const SizedBox(height: ZipherSpacing.sm),
          const Text('Claim a gift', style: ZipherType.headline),
          const SizedBox(height: ZipherSpacing.md),
          TextField(
            controller: _controller,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: ZipherType.mono,
            maxLines: 3,
            minLines: 1,
            onSubmitted: _submit,
            decoration: InputDecoration(
                hintText: 'https://…#v=1&key=zgift1…', errorText: _error),
          ),
          const SizedBox(height: ZipherSpacing.md),
          Row(children: [
            Expanded(
                child: ZipherButton(
                    label: 'Paste',
                    icon: Icons.content_paste_rounded,
                    kind: ZipherButtonKind.secondary,
                    onPressed: _paste)),
            const SizedBox(width: ZipherSpacing.sm),
            Expanded(
                child: ZipherButton(
                    label: 'Scan',
                    icon: Icons.qr_code_scanner_rounded,
                    kind: ZipherButtonKind.secondary,
                    onPressed: _scan)),
          ]),
          const SizedBox(height: ZipherSpacing.sm),
          ZipherButton(
              label: 'Continue', onPressed: () => _submit(_controller.text)),
        ]),
      ),
    );
  }
}
