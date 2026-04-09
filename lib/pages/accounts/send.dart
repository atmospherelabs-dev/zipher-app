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
    try {
      String? scheme;
      if (puri.startsWith('zcash:')) {
        scheme = 'zcash:';
      } else if (puri.startsWith('zcash-test:')) {
        scheme = 'zcash-test:';
      }
      if (scheme != null) {
        final parts = puri.substring(scheme.length).split('?');
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
    } catch (_) {
      return null;
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
  int get _spendable => aa.poolBalances.shielded;

  bool get _isTransparentAddress =>
      _address.startsWith('t1') || _address.startsWith('t3');

  bool get _hasUnshieldedFunds => aa.poolBalances.transparent > 0;

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
                        _buildAmount(),
                        const Gap(20),
                        _buildSendTo(),
                        const Gap(20),
                        if (!_isTransparentAddress) _buildMessage(),
                        if (_isTransparentAddress) ...[
                          Row(
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  size: 13,
                                  color: ZipherColors.text20),
                              const Gap(6),
                              Text(
                                'Transparent addresses don\'t support memos',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ZipherColors.text20,
                                ),
                              ),
                            ],
                          ),
                        ],
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
          if (_hasUnshieldedFunds) ...[
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: ZipherColors.warm.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(ZipherRadius.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined,
                      size: 13, color: ZipherColors.warm),
                  const Gap(6),
                  Text(
                    '${amountToString2(aa.poolBalances.transparent)} ZEC needs shielding',
                    style: TextStyle(
                      fontSize: 11,
                      color: ZipherColors.warm.withValues(alpha: 0.8),
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
                  if (text.isEmpty) return;
                  final parsed = SendContext.fromPaymentURI(text);
                  if (parsed != null) {
                    _didUpdateSendContext(parsed);
                    setState(() {});
                  } else {
                    _addressController.text = text;
                    setState(() => _address = text.trim());
                  }
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
          child: ZipherWidgets.gradientButton(
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
    if (_amountZat <= 0) {
      _showError('Enter a valid amount');
      return;
    }
    if (_amountZat > _spendable) {
      _showError(s.notEnoughBalance);
      return;
    }

    final validation = await WalletService.instance.validateAddress(addr);
    if (!validation.isValid) {
      _showError('Invalid Zcash address');
      return;
    }

    _showConfirmationSheet(addr);
  }

  void _showConfirmationSheet(String addr) {
    final isTransparent = addr.startsWith('t1') || addr.startsWith('t3');
    final memo = isTransparent ? null : (_memoText.isNotEmpty ? _memoText : null);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ConfirmSendSheet(
        address: addr,
        enteredAmount: _amountZat,
        spendable: _spendable,
        isMax: _deductFee,
        isTransparent: isTransparent,
        memo: memo,
        onConfirmed: () => _executeConfirmedSend(),
      ),
    );
  }

  Future<void> _executeConfirmedSend() async {
    if (mounted) {
      GoRouter.of(context).go('/account/submit_tx');
    }
  }

  String _friendlyError(String raw) {
    final r = raw.toLowerCase();
    if (r.contains('insufficientfunds') || r.contains('insufficient funds') ||
        r.contains('proposal failed')) {
      if (_hasUnshieldedFunds && _spendable == 0) {
        return 'Your funds need shielding before you can send. '
            'Use the Shield button on the home screen.';
      }
      final available = RegExp(r'available.*?(\d+)').firstMatch(raw);
      final required = RegExp(r'required.*?(\d+)').firstMatch(raw);
      if (available != null && required != null) {
        final avail = int.tryParse(available.group(1)!) ?? 0;
        final req = int.tryParse(required.group(1)!) ?? 0;
        final fee = (req - avail) / ZECUNIT;
        return 'Not enough funds. You need ${fee.toStringAsFixed(4)} ZEC more to cover the network fee.';
      }
      return 'Not enough funds to cover the transaction and network fee.';
    }
    if (r.contains('checkpointnotfound')) {
      return 'Wallet is still syncing. Please wait for sync to complete before sending.';
    }
    if (r.contains('failed to create payment')) {
      return 'Invalid payment. Check the address and amount.';
    }
    if (r.contains('wallet not initialized')) {
      return 'Wallet is not open. Please restart the app.';
    }
    // Strip stack traces — only show the first line
    final firstLine = raw.split('\n').first;
    if (firstLine.length > 120) return '${firstLine.substring(0, 120)}…';
    return firstLine;
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

/// Confirmation bottom sheet — calculates the fee and shows a full
/// breakdown before the user commits to sending.
class _ConfirmSendSheet extends StatefulWidget {
  final String address;
  final int enteredAmount;
  final int spendable;
  final bool isMax;
  final bool isTransparent;
  final String? memo;
  final Future<void> Function() onConfirmed;

  const _ConfirmSendSheet({
    required this.address,
    required this.enteredAmount,
    required this.spendable,
    required this.isMax,
    required this.isTransparent,
    required this.memo,
    required this.onConfirmed,
  });

  @override
  State<_ConfirmSendSheet> createState() => _ConfirmSendSheetState();
}

class _ConfirmSendSheetState extends State<_ConfirmSendSheet> {
  bool _loading = true;
  bool _sending = false;
  String? _error;
  int _fee = 0;
  bool _feeEstimated = false;
  int _sendAmount = 0;

  String _cleanError(String raw) {
    final s = raw.replaceFirst(RegExp(r'^(Exception|AnyhowException):\s*'), '');
    if (s.contains('InsufficientFunds') || s.contains('insufficient funds')) {
      return 'Not enough shielded funds to cover the transaction and network fee.';
    }
    final first = s.split('\n').first.split('Stack backtrace').first.trim();
    if (first.length > 150) return '${first.substring(0, 150)}…';
    return first;
  }

  @override
  void initState() {
    super.initState();
    _calculateFee();
  }

  Future<void> _calculateFee() async {
    try {
      final result = await WalletService.instance.proposeSend(
        widget.address,
        widget.isMax ? 0 : widget.enteredAmount,
        memo: widget.memo,
        isMax: widget.isMax,
      );

      _sendAmount = result.sendAmount;
      _fee = result.fee;
      _feeEstimated = !result.isExact;

      if (!widget.isMax && _sendAmount + _fee > widget.spendable) {
        setState(() {
          _loading = false;
          _error =
              'Not enough funds. You need ${amountToString2((_sendAmount + _fee) - widget.spendable)} '
              'ZEC more to cover the network fee.';
        });
        return;
      }

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = _cleanError(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: ZipherColors.border, width: 0.5),
        ),
      ),
      padding: EdgeInsets.fromLTRB(24, 16, 24, 16 + bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: ZipherColors.text20,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Gap(20),
          Text(
            'Confirm Transaction',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: ZipherColors.text90,
            ),
          ),
          const Gap(24),
          if (_loading) ...[
            const Gap(32),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                color: ZipherColors.cyan,
                strokeWidth: 2,
              ),
            ),
            const Gap(12),
            Text(
              'Calculating fee...',
              style: TextStyle(fontSize: 13, color: ZipherColors.text40),
            ),
            const Gap(32),
          ] else if (_error != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: ZipherColors.red.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(ZipherRadius.md),
                border: Border.all(
                  color: ZipherColors.red.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: ZipherColors.red),
                  const Gap(10),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                          fontSize: 13, color: ZipherColors.text90),
                    ),
                  ),
                ],
              ),
            ),
            const Gap(20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: ZipherColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ZipherRadius.lg),
                  ),
                ),
                child: Text(
                  'Go back',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: ZipherColors.text60,
                  ),
                ),
              ),
            ),
          ] else ...[
            _row('To', _shortAddress(widget.address)),
            _divider(),
            _row('Amount', '${amountToString2(_sendAmount)} ZEC'),
            _divider(),
            _row('Network fee',
                '${_feeEstimated ? "~" : ""}${amountToString2(_fee)} ZEC',
                valueColor: ZipherColors.text40),
            if (widget.memo != null && widget.memo!.isNotEmpty) ...[
              _divider(),
              _row('Memo', widget.memo!, maxLines: 2),
            ],
            _divider(),
            _row(
              'Total',
              '${amountToString2(_sendAmount + _fee)} ZEC',
              labelStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ZipherColors.text90,
              ),
              valueStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const Gap(28),
            SizedBox(
              width: double.infinity,
              child: _sending
                  ? Center(
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          color: ZipherColors.cyan,
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  : ZipherWidgets.gradientButton(
                      label: 'Confirm & Send',
                      icon: Icons.check_rounded,
                      onPressed: () async {
                        setState(() => _sending = true);
                        Navigator.of(context).pop();
                        await widget.onConfirmed();
                      },
                    ),
            ),
            const Gap(8),
            if (!_sending)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text40,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(
    String label,
    String value, {
    Color? valueColor,
    TextStyle? labelStyle,
    TextStyle? valueStyle,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment:
            maxLines > 1 ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: labelStyle ??
                TextStyle(fontSize: 13, color: ZipherColors.text40),
          ),
          const Gap(16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: valueStyle ??
                  TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: valueColor ?? ZipherColors.text90,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Divider(
        height: 1,
        color: ZipherColors.border.withValues(alpha: 0.3),
      );

  String _shortAddress(String addr) {
    if (addr.length <= 20) return addr;
    return '${addr.substring(0, 10)}...${addr.substring(addr.length - 10)}';
  }
}
