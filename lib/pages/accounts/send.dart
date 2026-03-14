import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../generated/intl/messages.dart';
import '../../services/wallet_service.dart';
import '../../src/rust/api/wallet.dart' as rust_wallet;
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../scan.dart';
import '../utils.dart';

class SendContext {
  final String address;
  final int pools;
  final Amount amount;
  final MemoData? memo;
  SendContext(this.address, this.pools, this.amount, this.memo);

  static SendContext? fromPaymentURI(String puri) {
    // ZIP-321 parsing is simplified — just extract address from URI
    if (puri.startsWith('zcash:')) {
      final parts = puri.substring(6).split('?');
      final addr = parts.first;
      int amount = 0;
      String memo = '';
      if (parts.length > 1) {
        final params = Uri.splitQueryString(parts[1]);
        if (params.containsKey('amount')) {
          amount = stringToAmount(params['amount']!);
        }
        if (params.containsKey('memo')) {
          memo = params['memo']!;
        }
      }
      return SendContext(addr, 7, Amount(amount, false), MemoData(false, '', memo));
    }
    return null;
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

  final _addressController = TextEditingController();
  final _amountController = TextEditingController();
  final _memoController = TextEditingController();

  String _address = '';
  int _amountZat = 0;
  bool _deductFee = false;
  String _memoText = '';
  late bool _includeReplyTo = appSettings.includeReplyTo != 0;
  bool _balanceVisible = true;
  bool _sending = false;

  int get _spendable => aa.poolBalances.confirmed;

  @override
  void initState() {
    super.initState();
    _didUpdateSendContext(widget.sendContext);
    _memoText = appSettings.memo;
    if (_memoText.isNotEmpty) _memoController.text = _memoText;
  }

  @override
  void dispose() {
    _addressController.dispose();
    _amountController.dispose();
    _memoController.dispose();
    super.dispose();
  }

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
          icon: Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
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
                        _buildBalanceHero(),
                        const Gap(28),
                        _buildSendTo(),
                        const Gap(20),
                        _buildAmount(),
                        const Gap(20),
                        _buildMessage(),
                        const Gap(32),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _buildSendButton(),
          ],
        ),
      ),
    );
  }

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
                            width: 22, height: 22, fit: BoxFit.contain),
                      ),
                    ),
                    const Gap(8),
                    Text(
                      amountToString2(_spendable),
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
            style: TextStyle(fontSize: 13, color: ZipherColors.text40),
          ),
        ],
      ),
    );
  }

  Widget _buildSendTo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Send to',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: ZipherColors.text40)),
        const Gap(8),
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(ZipherRadius.lg),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addressController,
                  style:
                      TextStyle(fontSize: 14, color: ZipherColors.text90),
                  decoration: InputDecoration(
                    hintText: 'Zcash address',
                    hintStyle:
                        TextStyle(fontSize: 14, color: ZipherColors.text20),
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                  onChanged: (v) => setState(() => _address = v.trim()),
                ),
              ),
              GestureDetector(
                onTap: () async {
                  final text = await scanQRCode(context,
                      validator: composeOr(
                          [addressValidator, paymentURIValidator]));
                  _addressController.text = text;
                  setState(() => _address = text.trim());
                },
                child: Padding(
                  padding: const EdgeInsets.all(ZipherSpacing.sm),
                  child: Icon(Icons.qr_code_rounded,
                      size: 20, color: ZipherColors.text40),
                ),
              ),
              const Gap(4),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAmount() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Amount',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: ZipherColors.text40)),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(ZipherRadius.sm),
                ),
                child: Text('MAX',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color:
                            ZipherColors.cyan.withValues(alpha: 0.7))),
              ),
            ),
          ],
        ),
        const Gap(8),
        Container(
          height: 56,
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(ZipherRadius.lg),
          ),
          child: TextField(
            controller: _amountController,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: ZipherColors.text90),
            decoration: InputDecoration(
              hintText: '0.00',
              hintStyle: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: ZipherColors.text20),
              suffixText: 'ZEC',
              suffixStyle: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text20),
              filled: false,
              border: InputBorder.none,
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
              style: TextStyle(fontSize: 12, color: ZipherColors.text20),
            ),
          ),
      ],
    );
  }

  Widget _buildMessage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Message',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: ZipherColors.text40)),
        const Gap(8),
        Container(
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(ZipherRadius.lg),
          ),
          child: TextField(
            controller: _memoController,
            maxLines: 4,
            maxLength: 512,
            style: TextStyle(fontSize: 14, color: ZipherColors.text90),
            decoration: InputDecoration(
              hintText: 'Write encrypted message here...',
              hintStyle:
                  TextStyle(fontSize: 14, color: ZipherColors.text40),
              filled: false,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              counterText: '',
            ),
            onChanged: (v) => setState(() => _memoText = v),
          ),
        ),
      ],
    );
  }

  Widget _buildSendButton() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: SizedBox(
          width: double.infinity,
          child: _sending
              ? Center(
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(
                        color: ZipherColors.cyan, strokeWidth: 2),
                  ),
                )
              : ZipherWidgets.gradientButton(
                  label: 'Send',
                  icon: Icons.send_rounded,
                  onPressed: _send,
                ),
        ),
      ),
    );
  }

  void _didUpdateSendContext(SendContext? sendContext) {
    if (sendContext == null) return;
    _address = sendContext.address;
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
  }

  void _send() async {
    final addr = _addressController.text.trim();
    if (addr.isEmpty) {
      _showError('Enter a recipient address');
      return;
    }

    final validation = await WalletService.instance.validateAddress(addr);
    if (!validation.isValid) {
      _showError('Invalid Zcash address');
      return;
    }

    if (_amountZat <= 0) {
      _showError('Enter a valid amount');
      return;
    }
    if (_amountZat > _spendable) {
      _showError(s.notEnoughBalance);
      return;
    }

    setState(() => _sending = true);
    try {
      final recipients = [
        rust_wallet.PaymentRecipient(
          address: addr,
          amount: BigInt.from(_amountZat),
          memo: _memoText.isNotEmpty ? _memoText : null,
        ),
      ];
      final txid = await WalletService.instance.send(recipients);
      logger.i('Transaction sent: $txid');

      // Refresh balance
      await aa.updateBalance();
      await aa.updateTransactions();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transaction sent successfully'),
            backgroundColor: ZipherColors.green,
          ),
        );
        GoRouter.of(context).pop();
      }
    } catch (e) {
      _showError('Send failed: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
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
              child: Text(msg,
                  style: TextStyle(
                      fontSize: 13, color: ZipherColors.text90)),
            ),
          ],
        ),
        backgroundColor: ZipherColors.surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          side: BorderSide(
              color: ZipherColors.red.withValues(alpha: 0.15)),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
