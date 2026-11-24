import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../appsettings.dart';
import '../../coin/coins.dart';
import '../../services/app_log.dart';
import '../../services/gift_engine.dart';
import '../../services/gift_links.dart';
import '../../services/wallet_service.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../action/widgets/wallet_review_card.dart';
import '../utils.dart';

/// Pick an amount and message, then fund the gift through the wallet's
/// normal review card and device authentication.
class GiftCreatePage extends StatefulWidget {
  const GiftCreatePage({super.key});
  @override
  State<GiftCreatePage> createState() => _GiftCreatePageState();
}

class _GiftCreatePageState extends State<GiftCreatePage> {
  static const _chips = [5000000, 10000000, 25000000, 50000000, 100000000];
  final _amount = TextEditingController(text: '0.1');
  final _message = TextEditingController();
  final _epoch = ValueNotifier<int>(0);
  final _phase = ValueNotifier(ReviewPhase.open);
  int? _spendable;
  String? _error;
  bool _busy = false;
  SentGift? _draft;
  ReviewData? _review;
  int? _revision;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() => _error = null));
    WalletService.instance.getBalanceOrZero().then((b) {
      if (!mounted) return;
      setState(() => _spendable =
          (b.orchard + b.ironwood + b.sapling).toInt());
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _amount.dispose();
    _message.dispose();
    _epoch.dispose();
    _phase.dispose();
    super.dispose();
  }

  int? get _face => GiftMath.parseZec(_amount.text);

  double? get _usdPrice =>
      !isTestnet && appSettings.currency.toUpperCase() == 'USD'
          ? marketPrice.price
          : null;

  Future<void> _prepare() async {
    final face = _face;
    final why = GiftMath.reject(face, spendable: _spendable) ??
        GiftMath.rejectMessage(_message.text);
    if (why != null) {
      setState(() => _error = why);
      return;
    }
    final walletId = WalletService.instance.activeWalletId;
    if (walletId == null) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      // Reuse an unfunded draft of the same amount and message (nothing was
      // sent for it); otherwise mint a new key.
      var draft = _draft;
      if (draft == null ||
          draft.amount != face ||
          (draft.message ?? '') != _message.text.trim()) {
        final minted = await GiftEngine.instance.mint(face!, message: _message.text);
        draft = SentGift(
          id: minted.fundingAddress,
          link: minted.link,
          fundingAddress: minted.fundingAddress,
          amount: face,
          birthday: minted.birthday,
          createdAt: DateTime.now().toUtc(),
          status: SentGiftStatus.draft,
          testnet: isTestnet,
          message: _message.text.trim().isEmpty ? null : _message.text.trim(),
        );
        assert(minted.fundingAmount.toInt() == draft.fundingAmount);
        // Saved before anything is signed so the key can never be lost.
        await SentGiftStore.instance.save(walletId, draft);
      }
      final proposal = await WalletService.instance
          .proposeSend(draft.fundingAddress, draft.fundingAmount);
      if (!proposal.isExact || proposal.sendAmount != draft.fundingAmount) {
        throw StateError('inexact');
      }
      if (!mounted) return;
      _epoch.value++;
      _phase.value = ReviewPhase.open;
      setState(() {
        _draft = draft;
        _revision = WalletService.instance.proposalRevision;
        _review = ReviewData(
          zatoshis: proposal.sendAmount,
          fee: proposal.fee,
          recipient: draft!.fundingAddress,
          recipientNote: 'New gift',
          memo: draft.message,
          zecUsd: _usdPrice,
          warning:
              'Includes ${GiftMath.formatZec(GiftMath.claimFeeReserve)} ZEC so claiming is free for them. '
              'Anyone with the link can claim this gift.',
        );
      });
    } catch (e) {
      AppLog.instance.event('gift', 'prepare_failed', error: e);
      if (mounted) {
        setState(() => _error = e is StateError && '$e'.contains('inexact')
            ? 'Your wallet can’t send that exact amount right now. Try a smaller gift.'
            : 'Couldn’t prepare the gift. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final draft = _draft;
    final review = _review;
    final walletId = WalletService.instance.activeWalletId;
    if (draft == null || review == null || walletId == null) return;
    final wallet = WalletService.instance;
    final epoch = _epoch.value;
    if (wallet.proposalRevision != _revision) {
      _phase.value = ReviewPhase.failed;
      setState(() => _error = 'Another transaction replaced this review. Nothing was sent.');
      return;
    }
    final authorized = await requireSigningAuthorization(context,
        actionSummary:
            'Gift ${GiftMath.formatZec(draft.amount)} ZEC (${GiftMath.formatZec(review.zatoshis)} + ${GiftMath.formatZec(review.fee)} fee)');
    if (!mounted) return;
    if (!authorized || epoch != _epoch.value || wallet.activeWalletId != walletId) {
      _epoch.value++;
      _phase.value = ReviewPhase.cancelled;
      setState(() {
        _review = null;
        _error = 'Not approved, so nothing was sent.';
      });
      return;
    }
    _phase.value = ReviewPhase.sending;
    var gift = draft.apply(SentGiftEvent.approve, networkFee: review.fee);
    await SentGiftStore.instance.save(walletId, gift);
    try {
      final outcome = await wallet.confirmSendDetailed(
          expectedRevision: _revision!,
          expectedWalletId: walletId,
          expectedTestnet: isTestnet);
      gift = gift.apply(SentGiftEvent.broadcast, txid: outcome.txid);
      _phase.value = outcome.accepted ? ReviewPhase.sent : ReviewPhase.approved;
      AppLog.instance.event('gift', 'funded', detail: 'broadcast=${outcome.broadcast.name}');
    } on SendUncertainException catch (e) {
      AppLog.instance.event('gift', 'fund_uncertain', error: e);
      gift = gift.apply(SentGiftEvent.sendUncertain);
      _phase.value = ReviewPhase.approved;
    } catch (e) {
      AppLog.instance.event('gift', 'fund_not_sent', error: e);
      gift = gift.apply(SentGiftEvent.notSent);
      await SentGiftStore.instance.save(walletId, gift);
      _epoch.value++;
      _phase.value = ReviewPhase.failed;
      if (mounted) {
        setState(() {
          _draft = gift;
          _review = null;
          _error = 'The gift wasn’t funded. Nothing was sent.';
        });
      }
      return;
    }
    await SentGiftStore.instance.save(walletId, gift);
    boostSyncPolling();
    if (!mounted) return;
    GoRouter.of(context).pushReplacement('/gifts/sent', extra: gift);
  }

  @override
  Widget build(BuildContext context) {
    final face = _face;
    final review = _review;
    final usd = _usdPrice;
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Column(children: [
        ZipherWidgets.pageHeader(context, 'Send a gift'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                ZipherColors.pagePadding, 8, ZipherColors.pagePadding, 24),
            children: [
              if (review == null) ...[
                const Text('Amount', style: ZipherType.section),
                const SizedBox(height: ZipherSpacing.sm),
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style: ZipherType.amount,
                  decoration: InputDecoration(
                    suffixText: 'ZEC',
                    errorText: _error,
                    helperText: face != null && usd != null
                        ? '≈ \$${(face / 1e8 * usd).toStringAsFixed(2)}'
                        : _spendable == null
                            ? null
                            : 'Spendable: ${GiftMath.formatZec(_spendable!)} ZEC',
                  ),
                ),
                const SizedBox(height: ZipherSpacing.smMd),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final c in _chips)
                    ChoiceChip(
                      label: Text('${GiftMath.formatZec(c)} ZEC'),
                      selected: face == c,
                      onSelected: (_) => _amount.text = GiftMath.formatZec(c),
                    ),
                ]),
                const SizedBox(height: ZipherSpacing.lg),
                const Text('Message (optional)', style: ZipherType.section),
                const SizedBox(height: ZipherSpacing.sm),
                TextField(
                  controller: _message,
                  maxLength: GiftMath.maxMessageChars,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                      hintText: 'Welcome to Zcash!'),
                ),
                const SizedBox(height: ZipherSpacing.sm),
                if (face != null && GiftMath.reject(face) == null)
                  ZipherWidgets.card(
                    padding: const EdgeInsets.all(ZipherSpacing.md),
                    child: Column(children: [
                      _line('They receive', '${GiftMath.formatZec(face)} ZEC'),
                      _line('Claim fee, prepaid',
                          '${GiftMath.formatZec(GiftMath.claimFeeReserve)} ZEC'),
                      _line('Network fee', 'Shown at review'),
                    ]),
                  ),
                const SizedBox(height: ZipherSpacing.md),
                const Text(
                    'The message travels inside the link, not on chain. '
                    'The gift stays shielded from your wallet to theirs.',
                    style: ZipherType.footnote),
              ] else ...[
                Text('Review your gift', style: ZipherType.title),
                const SizedBox(height: ZipherSpacing.md),
                WalletReviewCard(
                  key: ValueKey(_epoch.value),
                  epoch: _epoch,
                  expectedEpoch: _epoch.value,
                  data: review,
                  phase: _phase,
                  confirmLabel: 'Fund gift',
                  onCancel: () {
                    _epoch.value++;
                    setState(() => _review = null);
                  },
                  onConfirm: _confirm,
                ),
                if (_error != null) ...[
                  const SizedBox(height: ZipherSpacing.md),
                  ZipherWidgets.errorBanner(_error!),
                ],
              ],
            ],
          ),
        ),
        if (review == null)
          ZipherWidgets.bottomActions([
            ZipherButton(
                label: 'Review gift',
                loading: _busy,
                onPressed: _busy ? null : _prepare),
          ]),
      ]),
    );
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(label, style: ZipherType.subhead),
          const Spacer(),
          Text(value, style: ZipherType.rowValue.copyWith(fontSize: 15)),
        ]),
      );
}
