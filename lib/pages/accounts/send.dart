import 'dart:convert';

import 'package:zipher/main.dart' hide ZECUNIT;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../scan.dart';
import '../utils.dart';
import '../widgets.dart';

class SendContext {
  final String address;
  final int pools;
  final Amount amount;
  final MemoData? memo;
  SendContext(this.address, this.pools, this.amount, this.memo);
  static SendContext? fromPaymentURI(String puri) {
    final p = WarpApi.decodePaymentURI(aa.coin, puri);
    if (p == null) throw S.of(navigatorKey.currentContext!).invalidPaymentURI;
    return SendContext(
        p.address!, 7, Amount(p.amount, false), MemoData(false, '', p.memo!));
  }

  @override
  String toString() {
    return 'SendContext($address, $pools, ${amount.value}, ${memo?.memo})';
  }

  static SendContext? instance;
}

class QuickSendPage extends StatefulWidget {
  final SendContext? sendContext;
  final bool custom;
  final bool single;
  QuickSendPage({this.sendContext, this.custom = false, this.single = true});

  @override
  State<StatefulWidget> createState() => _QuickSendState();
}

class _QuickSendState extends State<QuickSendPage> with WithLoadingAnimation {
  late final s = S.of(context);
  late final t = Theme.of(context);
  final formKey = GlobalKey<FormBuilderState>();
  late PoolBalanceT balances =
      WarpApi.getPoolBalances(aa.coin, aa.id, appSettings.anchorOffset, false)
          .unpack();

  // Controllers
  final _addressController = TextEditingController();
  final _amountController = TextEditingController();
  final _memoController = TextEditingController();

  String _address = '';
  int _pools = 7;
  int _amountZat = 0;
  bool _deductFee = false;
  String _memoText = '';
  late bool _includeReplyTo = appSettings.includeReplyTo != 0;
  bool isShielded = true; // Default shielded (Zashi-style)
  int addressPools = 0;
  bool isTex = false;
  int rp = 0;
  late bool custom;
  bool _balanceVisible = true;

  @override
  void initState() {
    super.initState();
    custom = widget.custom ^ appSettings.customSend;
    _didUpdateSendContext(widget.sendContext);
    _memoText = appSettings.memo;
    if (_memoText.isNotEmpty) _memoController.text = _memoText;
  }

  @override
  void didUpdateWidget(QuickSendPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    balances =
        WarpApi.getPoolBalances(aa.coin, aa.id, appSettings.anchorOffset, false)
            .unpack();
    _didUpdateSendContext(widget.sendContext);
  }

  @override
  void dispose() {
    _addressController.dispose();
    _amountController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  int get _spendable => getSpendable(_pools, balances);
  int get _totalBal => balances.transparent + balances.sapling + balances.orchard;
  int get _memoBytes => utf8.encode(_memoText).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'SEND',
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
            onPressed: () =>
                setState(() => _balanceVisible = !_balanceVisible),
            icon: Icon(
              _balanceVisible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: ZipherColors.text40,
            ),
          ),
        ],
      ),
      body: wrapWithLoading(
        Column(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => FocusScope.of(context).unfocus(),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: FormBuilder(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Balance
                        _buildBalanceHero(),
                        const Gap(28),

                        // Send to
                        _buildSendTo(),
                        const Gap(20),

                        // Amount
                        _buildAmount(),
                        const Gap(20),

                        // Message — visible when shielded, hint when transparent
                        _buildMessage(),

                        const Gap(32),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Review button
            _buildReview(),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // BALANCE HERO
  // ═══════════════════════════════════════════════════════════

  Widget _buildBalanceHero() {
    return Center(
      child: Column(
        children: [
          const Gap(4),
          _balanceVisible
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: ZipherColors.cardBgElevated,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Image.asset('assets/zcash_logo.png',
                            width: 22, height: 22,
                            fit: BoxFit.contain),
                      ),
                    ),
                    const Gap(8),
                    Text(
                      amountToString2(_totalBal),
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -1,
                      ),
                    ),
                  ],
                )
              : Text(
                  '••••••',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    color: ZipherColors.text60,
                    letterSpacing: 4,
                  ),
                  textAlign: TextAlign.center,
                ),
          const Gap(6),
          Text(
            'Spendable:  ${amountToString2(_spendable)} ZEC',
            style: TextStyle(
              fontSize: 13,
              color: ZipherColors.text40,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // SEND TO
  // ═══════════════════════════════════════════════════════════

  Widget _buildSendTo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Send to',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: ZipherColors.text40,
          ),
        ),
        const Gap(8),
        FormBuilderField<String>(
          name: 'address',
          initialValue: _address,
          validator: composeOr([addressValidator, paymentURIValidator]),
          onChanged: (v) => _onAddress(v),
          builder: (field) {
            return Container(
              height: 52,
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: ContactAutocomplete(
                controller: _addressController,
                onSelected: (address, name) {
                  _addressController.text = address;
                  field.didChange(address);
                },
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addressController,
                        style: TextStyle(
                          fontSize: 14,
                          color: ZipherColors.text90,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Zcash address or payment URI',
                          hintStyle: TextStyle(
                            fontSize: 14,
                            color: ZipherColors.text20,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                        onChanged: (v) => field.didChange(v),
                      ),
                    ),
                    _iconBtn(Icons.people_outline_rounded, () async {
                      final c = await GoRouter.of(context)
                          .push<Contact>('/account/quick_send/contacts');
                      if (c != null) _setAddress(c.address!, field);
                    }),
                    _iconBtn(Icons.qr_code_rounded, () async {
                      final text = await scanQRCode(context,
                          validator:
                              composeOr([addressValidator, paymentURIValidator]));
                      _setAddress(text, field);
                    }),
                    const Gap(4),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _setAddress(String v, FormFieldState<String> field) {
    _addressController.text = v;
    field.didChange(v);
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 20,
            color: ZipherColors.text40),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // AMOUNT
  // ═══════════════════════════════════════════════════════════

  Widget _buildAmount() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Amount',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: ZipherColors.text40,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () {
                setState(() {
                  _amountZat = _spendable;
                  _deductFee = true;
                  _amountController.text = amountToString2(_spendable);
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'MAX',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.cyan.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ],
        ),
        const Gap(8),
        Container(
          height: 56,
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: TextField(
            controller: _amountController,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: ZipherColors.text90,
            ),
            decoration: InputDecoration(
              hintText: '0.00',
              hintStyle: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: ZipherColors.text20,
              ),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 14, right: 8),
                child: Image.asset('assets/zcash_small.png',
                    width: 18, height: 18,
                    color: ZipherColors.text40,
                    colorBlendMode: BlendMode.srcIn),
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 0, minHeight: 0),
              suffixText: 'ZEC',
              suffixStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: ZipherColors.text20,
              ),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            ),
            onChanged: (v) {
              try {
                _amountZat = v.isEmpty ? 0 : stringToAmount(v);
              } on FormatException {}
              setState(() {});
            },
          ),
        ),
        if (_amountZat > 0 && marketPrice.price != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              '\$${(_amountZat / ZECUNIT * marketPrice.price!).toStringAsFixed(2)} USD',
              style: TextStyle(
                fontSize: 12,
                color: ZipherColors.text20,
              ),
            ),
          ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // MESSAGE
  // ═══════════════════════════════════════════════════════════

  Widget _buildMessage() {
    // If address is entered and it's transparent-only, show a hint instead
    final hasAddress = _addressController.text.trim().isNotEmpty;
    final isTransparentOnly = hasAddress && !isShielded;

    if (isTransparentOnly) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 14,
                color: ZipherColors.text20),
            const Gap(10),
            Expanded(
              child: Text(
                'Transparent address — memos not available',
                style: TextStyle(
                  fontSize: 13,
                  color: ZipherColors.text20,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Message',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: ZipherColors.text40,
          ),
        ),
        const Gap(8),
        Container(
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              TextField(
                controller: _memoController,
                maxLines: 4,
                maxLength: _includeReplyTo
                    ? MAX_MESSAGE_CHARS_WITH_REPLY
                    : MAX_MESSAGE_CHARS_NO_REPLY,
                style: TextStyle(
                  fontSize: 14,
                  color: ZipherColors.text90,
                ),
                decoration: InputDecoration(
                  hintText: 'Write encrypted message here...',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text20,
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  counterText: '',
                ),
                onChanged: (v) => setState(() => _memoText = v),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 14, bottom: 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${_memoText.length}/${_includeReplyTo ? MAX_MESSAGE_CHARS_WITH_REPLY : MAX_MESSAGE_CHARS_NO_REPLY}',
                    style: TextStyle(
                      fontSize: 11,
                      color: _memoText.length > (_includeReplyTo ? MAX_MESSAGE_CHARS_WITH_REPLY : MAX_MESSAGE_CHARS_NO_REPLY) - 1
                          ? ZipherColors.red.withValues(alpha: 0.7)
                          : ZipherColors.text20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Gap(10),
        // Reply-to toggle
        GestureDetector(
          onTap: () =>
              setState(() => _includeReplyTo = !_includeReplyTo),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _includeReplyTo
                      ? Icons.reply_rounded
                      : Icons.reply_rounded,
                  size: 14,
                  color: _includeReplyTo
                      ? ZipherColors.purple.withValues(alpha: 0.5)
                      : ZipherColors.text20,
                ),
                const Gap(8),
                Expanded(
                  child: Text(
                    _includeReplyTo
                        ? 'Reply address included'
                        : 'Reply address hidden',
style: TextStyle(
                          fontSize: 12,
                          color: _includeReplyTo
                          ? ZipherColors.purple.withValues(alpha: 0.5)
                          : ZipherColors.text20,
                        ),
                  ),
                ),
                Container(
                  width: 32,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _includeReplyTo
                        ? ZipherColors.purple.withValues(alpha: 0.25)
                        : ZipherColors.borderSubtle,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 150),
                    alignment: _includeReplyTo
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: _includeReplyTo
                            ? ZipherColors.purple
                            : ZipherColors.text40,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Warning when reply-to is OFF and address is a known contact
        if (!_includeReplyTo && _address.isNotEmpty)
          Builder(
            builder: (context) {
              final contacts = WarpApi.getContacts(aa.coin);
              final isKnown = contacts.any(
                  (c) => c.address != null && c.address == _address);
              if (!isKnown) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 12,
                      color: Colors.orangeAccent.withValues(alpha: 0.6),
                    ),
                    const Gap(6),
                    Expanded(
                      child: Text(
                        'Recipient won\'t know this is from you',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.orangeAccent.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // REVIEW BUTTON
  // ═══════════════════════════════════════════════════════════

  Widget _buildReview() {
    final label = widget.single ? 'Review' : 'Add Recipient';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: SizedBox(
          width: double.infinity,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _review,
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
                    Icon(Icons.send_rounded,
                        size: 20,
                        color: ZipherColors.cyan.withValues(alpha: 0.9)),
                    const Gap(10),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ZipherColors.cyan.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // BUSINESS LOGIC
  // ═══════════════════════════════════════════════════════════

  void _onAddress(String? v) {
    if (v == null) return;
    final puri = WarpApi.decodePaymentURI(aa.coin, v);
    if (puri != null) {
      final sc = SendContext(puri.address!, _pools, Amount(puri.amount, false),
          MemoData(false, '', puri.memo!));
      _didUpdateSendContext(sc);
    } else {
      _address = v;
      _didUpdateAddress(v);
    }
    setState(() {});
  }

  void _didUpdateSendContext(SendContext? sendContext) {
    if (sendContext == null) return;
    _address = sendContext.address;
    _pools = sendContext.pools;
    _amountZat = sendContext.amount.value;
    _deductFee = sendContext.amount.deductFee;
    final memo = sendContext.memo;
    if (memo != null) {
      _memoText = memo.memo;
      _memoController.text = _memoText;
    }
    _addressController.text = _address;
    _amountController.text =
        _amountZat > 0 ? amountToString2(_amountZat) : '';
    _didUpdateAddress(_address);
  }

  void _didUpdateAddress(String? address) {
    if (address == null) return;
    isTex = false;
    var address2 = address;
    try {
      address2 = WarpApi.parseTexAddress(aa.coin, address2);
      isTex = true;
      _pools = 1;
    } on String {}
    final receivers = address.isNotEmpty
        ? WarpApi.receiversOfAddress(aa.coin, address2)
        : 0;
    isShielded = receivers & 6 != 0;
    addressPools = receivers & coinSettings.receipientPools;
    rp = addressPools;
  }

  void _review() async {
    // Validate address
    final addr = _addressController.text.trim();
    if (addr.isEmpty) {
      _showError('Enter a recipient address');
      return;
    }
    // Validate amount
    if (_amountZat <= 0) {
      _showError('Enter a valid amount (min 0.0001 ZEC)');
      return;
    }
    if (_amountZat < MIN_MEMO_AMOUNT) {
      _showError('Minimum amount is 0.0001 ZEC');
      return;
    }
    if (_amountZat > _spendable) {
      _showError(s.notEnoughBalance);
      return;
    }
    // Validate memo
    if (_memoBytes > 511) {
      _showError(s.memoTooLong);
      return;
    }

    final memoData = MemoData(_includeReplyTo, '', _memoText);
    final sc = SendContext(addr, _pools, Amount(_amountZat, _deductFee), memoData);
    SendContext.instance = sc;

    final builder = RecipientObjectBuilder(
      address: addr,
      pools: rp,
      amount: _amountZat,
      feeIncluded: _deductFee,
      replyTo: memoData.reply,
      subject: memoData.subject,
      memo: memoData.memo,
    );
    final recipient = Recipient(builder.toBytes());

    if (widget.single) {
      try {
        final plan = await load(() => WarpApi.prepareTx(
              aa.coin,
              aa.id,
              [recipient],
              _pools,
              coinSettings.replyUa,
              appSettings.anchorOffset,
              coinSettings.feeT,
            ));
        // Store memo + recipient so SubmitTxPage can persist after broadcast
        if (_memoText.isNotEmpty) {
          pendingOutgoingMemo = _memoText;
          pendingOutgoingRecipient = addr;
          pendingOutgoingAnonymous = !_includeReplyTo;
        }
        GoRouter.of(context).push('/account/txplan?tab=account', extra: plan);
      } on String catch (e) {
        showMessageBox2(context, s.error, e);
      }
    } else {
      GoRouter.of(context).pop(recipient);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline_rounded,
                size: 16,
                color: ZipherColors.red.withValues(alpha: 0.8)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                msg,
style: TextStyle(
                          fontSize: 13,
                          color: ZipherColors.text90,
                        ),
              ),
            ),
          ],
        ),
        backgroundColor: ZipherColors.surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: ZipherColors.red.withValues(alpha: 0.15),
          ),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
