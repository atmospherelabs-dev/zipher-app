import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../scan.dart';
import '../utils.dart';

// ═══════════════════════════════════════════════════════════
// ZIP-321 MULTI-OUTPUT URI PARSER
// ═══════════════════════════════════════════════════════════

class Zip321Payment {
  String address;
  int amountZat;
  String memo;

  Zip321Payment({
    required this.address,
    this.amountZat = 0,
    this.memo = '',
  });
}

List<Zip321Payment>? parseZip321Uri(String uri) {
  final scheme = activeCoin.ticker.toLowerCase();
  final lower = uri.toLowerCase();
  if (!lower.startsWith('$scheme:') && !lower.startsWith('zcash:')) return null;

  final colonIdx = uri.indexOf(':');
  final afterScheme = uri.substring(colonIdx + 1);

  final qIdx = afterScheme.indexOf('?');
  if (qIdx == -1) {
    return [Zip321Payment(address: afterScheme)];
  }

  String? baseAddress = afterScheme.substring(0, qIdx);
  final queryString = afterScheme.substring(qIdx + 1);

  if (baseAddress.isEmpty) baseAddress = null;

  final params = Uri.splitQueryString(queryString);
  final payments = <int, Zip321Payment>{};

  for (final entry in params.entries) {
    final key = entry.key;
    final value = entry.value;

    int index = 0;
    String baseName = key;

    final dotIdx = key.lastIndexOf('.');
    if (dotIdx != -1) {
      final suffix = key.substring(dotIdx + 1);
      final parsed = int.tryParse(suffix);
      if (parsed != null) {
        index = parsed;
        baseName = key.substring(0, dotIdx);
      }
    }

    payments.putIfAbsent(index, () => Zip321Payment(address: ''));

    switch (baseName) {
      case 'address':
        payments[index]!.address = value;
        break;
      case 'amount':
        final parsed = double.tryParse(value);
        if (parsed != null) {
          payments[index]!.amountZat = (parsed * ZECUNIT).round();
        }
        break;
      case 'memo':
        try {
          payments[index]!.memo =
              utf8.decode(base64Url.decode(base64Url.normalize(value)));
        } catch (_) {
          payments[index]!.memo = value;
        }
        break;
    }
  }

  if (baseAddress != null && payments.containsKey(0)) {
    if (payments[0]!.address.isEmpty) {
      payments[0]!.address = baseAddress;
    }
  }

  final sorted = payments.keys.toList()..sort();
  final result = sorted.map((k) => payments[k]!).toList();
  return result.isEmpty ? null : result;
}

bool isMultiOutputUri(String uri) {
  final payments = parseZip321Uri(uri);
  return payments != null && payments.length > 1;
}

// ═══════════════════════════════════════════════════════════
// RECIPIENT DATA MODEL
// ═══════════════════════════════════════════════════════════

class SplitRecipient {
  final TextEditingController addressController;
  final TextEditingController amountController;
  final TextEditingController memoController;
  int amountZat;
  bool locked;

  SplitRecipient({
    String address = '',
    int amount = 0,
    String memo = '',
    this.locked = false,
  })  : addressController = TextEditingController(text: address),
        amountController = TextEditingController(
            text: amount > 0 ? amountToString2(amount) : ''),
        memoController = TextEditingController(text: memo),
        amountZat = amount;

  void dispose() {
    addressController.dispose();
    amountController.dispose();
    memoController.dispose();
  }
}

// ═══════════════════════════════════════════════════════════
// SPLIT BILL PAGE
// ═══════════════════════════════════════════════════════════

class SplitBillPage extends StatefulWidget {
  final List<Zip321Payment>? prefilled;

  const SplitBillPage({this.prefilled});

  @override
  State<SplitBillPage> createState() => _SplitBillState();
}

class _SplitBillState extends State<SplitBillPage> with WithLoadingAnimation {
  late final s = S.of(context);
  late PoolBalanceT balances =
      WarpApi.getPoolBalances(aa.coin, aa.id, appSettings.anchorOffset, false)
          .unpack();

  final _totalController = TextEditingController();
  int _totalZat = 0;
  bool _equalSplit = true;
  bool _balanceVisible = true;
  bool _inputInUsd = false;
  final List<SplitRecipient> _recipients = [];

  int get _spendable => getSpendable(7, balances);
  int get _totalBal =>
      balances.transparent + balances.sapling + balances.orchard;
  double? get _price => marketPrice.price;

  @override
  void initState() {
    super.initState();
    if (widget.prefilled != null && widget.prefilled!.isNotEmpty) {
      _equalSplit = false;
      int total = 0;
      for (final p in widget.prefilled!) {
        _recipients.add(SplitRecipient(
          address: p.address,
          amount: p.amountZat,
          memo: p.memo,
          locked: true,
        ));
        total += p.amountZat;
      }
      _totalZat = total;
      _totalController.text = amountToString2(total);
    } else {
      _recipients.add(SplitRecipient());
      _recipients.add(SplitRecipient());
    }
  }

  @override
  void dispose() {
    _totalController.dispose();
    for (final r in _recipients) {
      r.dispose();
    }
    super.dispose();
  }

  void _recalcEqualSplit() {
    if (!_equalSplit || _totalZat <= 0 || _recipients.isEmpty) return;
    final perPerson = _totalZat ~/ _recipients.length;
    final remainder = _totalZat - (perPerson * _recipients.length);
    for (int i = 0; i < _recipients.length; i++) {
      final amt = i == 0 ? perPerson + remainder : perPerson;
      _recipients[i].amountZat = amt;
      _recipients[i].amountController.text = amountToString2(amt);
    }
  }

  void _addRecipient() {
    setState(() {
      _recipients.add(SplitRecipient());
      _recalcEqualSplit();
    });
  }

  void _removeRecipient(int index) {
    if (_recipients.length <= 2) return;
    setState(() {
      _recipients[index].dispose();
      _recipients.removeAt(index);
      _recalcEqualSplit();
    });
  }

  // ═══════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final isPrefilled = widget.prefilled != null;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          isPrefilled ? 'MULTI-PAY' : 'SPLIT BILL',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon:
              Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildBalanceHero(),
                      const Gap(28),

                      if (!isPrefilled) ...[
                        _buildTotalAmount(),
                        const Gap(20),
                        _buildSplitMode(),
                        const Gap(24),
                      ],

                      _buildRecipientsSection(isPrefilled),

                      const Gap(20),
                      _buildSummary(),
                      const Gap(32),
                    ],
                  ),
                ),
              ),
            ),
            _buildReviewButton(),
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
                            width: 22,
                            height: 22,
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
  // TOTAL AMOUNT
  // ═══════════════════════════════════════════════════════════

  Widget _buildTotalAmount() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Total Bill',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: ZipherColors.text40,
              ),
            ),
            const Spacer(),
            if (_price != null)
              GestureDetector(
                onTap: () {
                  setState(() {
                    _inputInUsd = !_inputInUsd;
                    _totalController.clear();
                    _totalZat = 0;
                    _recalcEqualSplit();
                  });
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: ZipherColors.cyan.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.swap_horiz_rounded,
                          size: 12,
                          color:
                              ZipherColors.cyan.withValues(alpha: 0.6)),
                      const Gap(4),
                      Text(
                        _inputInUsd ? 'ZEC' : 'USD',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color:
                              ZipherColors.cyan.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
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
            controller: _totalController,
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
              prefixIcon: _inputInUsd
                  ? Padding(
                      padding: const EdgeInsets.only(left: 16, right: 8),
                      child: Text(
                        '\$',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: ZipherColors.text40,
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(left: 14, right: 8),
                      child: Image.asset('assets/zcash_small.png',
                          width: 18,
                          height: 18,
                          color: ZipherColors.text40,
                          colorBlendMode: BlendMode.srcIn),
                    ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 0, minHeight: 0),
              suffixText: _inputInUsd ? 'USD' : 'ZEC',
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
                if (v.isEmpty) {
                  _totalZat = 0;
                } else if (_inputInUsd && _price != null && _price! > 0) {
                  final usd = double.parse(v);
                  _totalZat = (usd / _price! * ZECUNIT).round();
                } else {
                  _totalZat = stringToAmount(v);
                }
              } on FormatException {}
              setState(() {
                _recalcEqualSplit();
              });
            },
          ),
        ),
        // Conversion hint
        if (_totalZat > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _inputInUsd
                  ? '≈ ${amountToString2(_totalZat)} ZEC'
                  : _price != null
                      ? '≈ \$${(_totalZat / ZECUNIT * _price!).toStringAsFixed(2)} USD'
                      : '',
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
  // SPLIT MODE
  // ═══════════════════════════════════════════════════════════

  Widget _buildSplitMode() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _splitTab('Equal Split', Icons.group_rounded, true),
          _splitTab('Custom', Icons.tune_rounded, false),
        ],
      ),
    );
  }

  Widget _splitTab(String label, IconData icon, bool isEqual) {
    final active = _equalSplit == isEqual;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _equalSplit = isEqual;
            if (_equalSplit) _recalcEqualSplit();
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active
                ? ZipherColors.cyan.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: active ? ZipherColors.cyan : ZipherColors.text20),
              const Gap(6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? ZipherColors.cyan : ZipherColors.text40,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // RECIPIENTS
  // ═══════════════════════════════════════════════════════════

  Widget _buildRecipientsSection(bool isPrefilled) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recipients',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: ZipherColors.text40,
          ),
        ),
        const Gap(10),

        for (int i = 0; i < _recipients.length; i++) ...[
          _buildRecipientCard(i),
          if (i < _recipients.length - 1) const Gap(10),
        ],

        if (!isPrefilled) ...[
          const Gap(10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _addRecipient,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: ZipherColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: ZipherColors.cyan.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.person_add_rounded,
                        size: 18,
                        color: ZipherColors.cyan.withValues(alpha: 0.7)),
                    const Gap(8),
                    Text(
                      'Add Person',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: ZipherColors.cyan.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRecipientCard(int index) {
    final r = _recipients[index];
    final canRemove = _recipients.length > 2 && !r.locked;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: ZipherColors.cyan,
                    ),
                  ),
                ),
              ),
              const Gap(10),
              Expanded(
                child: Text(
                  r.addressController.text.isNotEmpty
                      ? _truncateAddr(r.addressController.text)
                      : 'Person ${index + 1}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: r.addressController.text.isNotEmpty
                        ? ZipherColors.text90
                        : ZipherColors.text20,
                  ),
                ),
              ),
              if (r.amountZat > 0) ...[
                Text(
                  '${amountToString2(r.amountZat)} ZEC',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.cyan.withValues(alpha: 0.7),
                  ),
                ),
                if (_price != null) ...[
                  const Gap(4),
                  Text(
                    '(\$${(r.amountZat / ZECUNIT * _price!).toStringAsFixed(2)})',
                    style: TextStyle(
                      fontSize: 10,
                      color: ZipherColors.text20,
                    ),
                  ),
                ],
              ],
              if (canRemove) ...[
                const Gap(8),
                GestureDetector(
                  onTap: () => _removeRecipient(index),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: ZipherColors.red.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close_rounded,
                        size: 14,
                        color: ZipherColors.red.withValues(alpha: 0.6)),
                  ),
                ),
              ],
            ],
          ),
          const Gap(10),

          // Address input
          if (!r.locked)
            Container(
              height: 52,
              decoration: BoxDecoration(
                color: ZipherColors.cardBgElevated,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: r.addressController,
                      style: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text90,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Zcash address',
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
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  _iconBtn(Icons.people_outline_rounded, () async {
                    final c = await GoRouter.of(context)
                        .push<Contact>('/account/quick_send/contacts');
                    if (c != null) {
                      setState(() => r.addressController.text = c.address!);
                    }
                  }),
                  _iconBtn(Icons.qr_code_rounded, () async {
                    final text = await scanQRCode(context,
                        validator: composeOr(
                            [addressValidator, paymentURIValidator]));
                    setState(() => r.addressController.text = text);
                  }),
                  const Gap(4),
                ],
              ),
            )
          else
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: ZipherColors.cardBgElevated,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                _truncateAddr(r.addressController.text),
                style: TextStyle(
                  fontSize: 14,
                  color: ZipherColors.text60,
                ),
              ),
            ),

          // Custom amount (visible when not equal split and not locked)
          if (!_equalSplit && !r.locked) ...[
            const Gap(8),
            Container(
              height: 52,
              decoration: BoxDecoration(
                color: ZipherColors.cardBgElevated,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TextField(
                controller: r.amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: ZipherColors.text90,
                ),
                decoration: InputDecoration(
                  hintText: '0.00',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text20,
                  ),
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 14, right: 8),
                    child: Image.asset('assets/zcash_small.png',
                        width: 16,
                        height: 16,
                        color: ZipherColors.text40,
                        colorBlendMode: BlendMode.srcIn),
                  ),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 0, minHeight: 0),
                  suffixText: 'ZEC',
                  suffixStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: ZipherColors.text20,
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                ),
                onChanged: (v) {
                  try {
                    r.amountZat = v.isEmpty ? 0 : stringToAmount(v);
                  } on FormatException {}
                  setState(() {});
                },
              ),
            ),
          ],

          // Memo
          if (!r.locked) ...[
            const Gap(8),
            GestureDetector(
              onTap: () => _showMemoSheet(r),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded,
                        size: 14, color: ZipherColors.text20),
                    const Gap(6),
                    Expanded(
                      child: Text(
                        r.memoController.text.isEmpty
                            ? 'Add encrypted memo'
                            : r.memoController.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: r.memoController.text.isEmpty
                              ? ZipherColors.text20
                              : ZipherColors.text40,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (r.locked && r.memoController.text.isNotEmpty) ...[
            const Gap(8),
            Row(
              children: [
                Icon(Icons.lock_rounded,
                    size: 12, color: ZipherColors.text20),
                const Gap(6),
                Expanded(
                  child: Text(
                    r.memoController.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: ZipherColors.text40,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 20, color: ZipherColors.text40),
      ),
    );
  }

  void _showMemoSheet(SplitRecipient r) {
    final controller = TextEditingController(text: r.memoController.text);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: ZipherColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ZipherWidgets.sheetHandle(),
            const Gap(12),
            Text(
              'Encrypted Memo',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: ZipherColors.text90,
              ),
            ),
            const Gap(4),
            Text(
              'Only you and the recipient can read this',
              style: TextStyle(fontSize: 12, color: ZipherColors.text20),
            ),
            const Gap(14),
            Container(
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TextField(
                controller: controller,
                maxLines: 4,
                maxLength: 512,
                autofocus: true,
                style:
                    TextStyle(fontSize: 14, color: ZipherColors.text90),
                decoration: InputDecoration(
                  hintText: 'Write a message...',
                  hintStyle:
                      TextStyle(fontSize: 14, color: ZipherColors.text20),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.all(16),
                  counterStyle:
                      TextStyle(fontSize: 11, color: ZipherColors.text20),
                ),
              ),
            ),
            const Gap(14),
            SizedBox(
              width: double.infinity,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    r.memoController.text = controller.text;
                    Navigator.of(ctx).pop();
                    setState(() {});
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: ZipherColors.cyan.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: Text(
                        'Save Memo',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color:
                              ZipherColors.cyan.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════

  Widget _buildSummary() {
    final totalSplit =
        _recipients.fold<int>(0, (sum, r) => sum + r.amountZat);
    final hasAllAddresses =
        _recipients.every((r) => r.addressController.text.trim().isNotEmpty);
    final amountMatch = _equalSplit || totalSplit == _totalZat;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          _summaryRow('Recipients', '${_recipients.length}'),
          const Gap(8),
          Divider(height: 1, color: ZipherColors.borderSubtle),
          const Gap(8),
          _summaryRow(
            'Per person',
            _equalSplit && _recipients.isNotEmpty && _totalZat > 0
                ? '${amountToString2(_totalZat ~/ _recipients.length)} ZEC'
                : '—',
          ),
          if (_equalSplit &&
              _recipients.isNotEmpty &&
              _totalZat > 0 &&
              _price != null) ...[
            const Gap(4),
            _summaryRow(
              '',
              '≈ \$${(_totalZat ~/ _recipients.length / ZECUNIT * _price!).toStringAsFixed(2)} USD each',
              valueColor: ZipherColors.text20,
            ),
          ],
          const Gap(8),
          Divider(height: 1, color: ZipherColors.borderSubtle),
          const Gap(8),
          _summaryRow(
            'Total',
            _equalSplit
                ? '${amountToString2(_totalZat)} ZEC'
                : '${amountToString2(totalSplit)} ZEC',
            labelBold: true,
            valueBold: true,
          ),
          if (_price != null && (_equalSplit ? _totalZat : totalSplit) > 0) ...[
            const Gap(4),
            _summaryRow(
              '',
              '≈ \$${((_equalSplit ? _totalZat : totalSplit) / ZECUNIT * _price!).toStringAsFixed(2)} USD',
              valueColor: ZipherColors.text20,
            ),
          ],

          if (!amountMatch && !_equalSplit && _totalZat > 0) ...[
            const Gap(10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: ZipherColors.orange.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: ZipherColors.orange.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 14,
                      color:
                          ZipherColors.orange.withValues(alpha: 0.7)),
                  const Gap(8),
                  Expanded(
                    child: Text(
                      'Custom amounts don\'t match total bill',
                      style: TextStyle(
                        fontSize: 12,
                        color: ZipherColors.orange
                            .withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (!hasAllAddresses) ...[
            const Gap(10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: ZipherColors.cardBgElevated,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14, color: ZipherColors.text20),
                  const Gap(8),
                  Text(
                    'Add addresses for all recipients',
                    style: TextStyle(
                      fontSize: 12,
                      color: ZipherColors.text20,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value, {
    bool labelBold = false,
    bool valueBold = false,
    Color? valueColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (label.isNotEmpty)
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: labelBold ? FontWeight.w600 : FontWeight.w400,
              color: ZipherColors.text40,
            ),
          ),
        if (label.isEmpty) const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: valueBold ? FontWeight.w600 : FontWeight.w500,
            color: valueColor ?? ZipherColors.text90,
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // REVIEW BUTTON
  // ═══════════════════════════════════════════════════════════

  Widget _buildReviewButton() {
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
                        color:
                            ZipherColors.cyan.withValues(alpha: 0.9)),
                    const Gap(10),
                    Text(
                      'Review & Send',
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
    );
  }

  // ═══════════════════════════════════════════════════════════
  // BUSINESS LOGIC
  // ═══════════════════════════════════════════════════════════

  void _review() async {
    for (int i = 0; i < _recipients.length; i++) {
      final r = _recipients[i];
      final addr = r.addressController.text.trim();
      if (addr.isEmpty) {
        _showError('Person ${i + 1}: Enter an address');
        return;
      }
      if (r.amountZat <= 0) {
        _showError('Person ${i + 1}: Enter an amount');
        return;
      }
      if (r.amountZat < MIN_MEMO_AMOUNT) {
        _showError('Person ${i + 1}: Minimum is 0.0001 ZEC');
        return;
      }
    }

    final totalSending =
        _recipients.fold<int>(0, (sum, r) => sum + r.amountZat);
    if (totalSending > _spendable) {
      _showError(s.notEnoughBalance);
      return;
    }

    final recipientList = <Recipient>[];
    for (final r in _recipients) {
      final addr = r.addressController.text.trim();
      final memo = r.memoController.text;

      final builder = RecipientObjectBuilder(
        address: addr,
        pools: 7,
        amount: r.amountZat,
        feeIncluded: false,
        replyTo: false,
        subject: '',
        memo: memo,
      );
      recipientList.add(Recipient(builder.toBytes()));
    }

    try {
      final plan = await load(() => WarpApi.prepareTx(
            aa.coin,
            aa.id,
            recipientList,
            7,
            coinSettings.replyUa,
            appSettings.anchorOffset,
            coinSettings.feeT,
          ));
      GoRouter.of(context)
          .push('/account/txplan?tab=account', extra: plan);
    } on String catch (e) {
      showMessageBox2(context, s.error, e);
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

  String _truncateAddr(String addr) {
    if (addr.length <= 20) return addr;
    return '${addr.substring(0, 10)}...${addr.substring(addr.length - 10)}';
  }
}
