import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:zipher/pages/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../accounts.dart';
import '../appsettings.dart';
import '../services/near_intents.dart';
import '../zipher_theme.dart';
import 'scan.dart';

enum SwapDirection { fromZec, intoZec }

BigInt _toBigInt(double amount, int decimals) {
  final shifted = (amount * math.pow(10, decimals)).truncate();
  return BigInt.from(shifted);
}

class NearSwapPage extends StatefulWidget {
  @override
  State<NearSwapPage> createState() => _NearSwapPageState();
}

class _NearSwapPageState extends State<NearSwapPage> with WithLoadingAnimation {
  final _nearApi = NearIntentsService();
  final _amountController = TextEditingController();
  final _addressController = TextEditingController();

  SwapDirection _direction = SwapDirection.fromZec;
  NearToken? _zecToken;
  List<NearToken> _swappableTokens = [];
  NearToken? _selectedToken;
  String? _error;
  bool _loadingTokens = true;
  bool _loadingQuote = false;
  int _slippageBps = 100;
  Timer? _debounce;

  // Price estimate (always computed client-side from USD prices)
  double _estimatedOutput = 0;
  double _rate = 0;
  String _cachedTAddr = '';

  int get _spendableZat {
    final b = WarpApi.getPoolBalances(aa.coin, aa.id, appSettings.anchorOffset, false).unpack();
    return b.transparent + b.sapling + b.orchard;
  }

  NearToken get _originToken => _direction == SwapDirection.fromZec ? _zecToken! : _selectedToken!;
  NearToken get _destToken => _direction == SwapDirection.fromZec ? _selectedToken! : _zecToken!;

  @override
  void initState() {
    super.initState();
    _loadTokens();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _addressController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadTokens() async {
    try {
      final tokens = await _nearApi.getTokens();
      final zec = _nearApi.findZecToken(tokens);
      final swappable = _nearApi.getSwappableTokens(tokens);
      setState(() {
        _zecToken = zec;
        _swappableTokens = swappable;
        _selectedToken = swappable.isNotEmpty ? swappable.first : null;
        _loadingTokens = false;
      });
      _updateEstimate();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loadingTokens = false;
      });
    }
  }

  void _flipDirection() {
    setState(() {
      _direction = _direction == SwapDirection.fromZec
          ? SwapDirection.intoZec
          : SwapDirection.fromZec;
      _error = null;
    });
    _updateEstimate();
  }

  void _onAmountChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _updateEstimate);
  }

  void _updateEstimate() {
    if (_zecToken == null || _selectedToken == null) return;
    final amountStr = _amountController.text.trim();
    final parsed = double.tryParse(amountStr) ?? 0;

    final op = _originToken.price ?? 0;
    final dp = _destToken.price ?? 0;

    if (parsed <= 0 || op == 0 || dp == 0) {
      setState(() { _estimatedOutput = 0; _rate = 0; });
      return;
    }

    setState(() {
      _rate = op / dp;
      _estimatedOutput = parsed * _rate;
    });
  }

  // ─── Get Quote & Show Confirmation ────────────────────────

  Future<void> _getQuote() async {
    final amountStr = _amountController.text.trim();
    if (amountStr.isEmpty || _zecToken == null || _selectedToken == null) return;

    final parsed = double.tryParse(amountStr);
    if (parsed == null || parsed <= 0) {
      setState(() => _error = 'Invalid amount');
      return;
    }

    final addr = _addressController.text.trim();
    if (_direction == SwapDirection.fromZec && addr.isEmpty) {
      setState(() => _error = 'Enter recipient address');
      return;
    }

    if (_direction == SwapDirection.fromZec) {
      final sendZat = stringToAmount(amountStr);
      if (sendZat > _spendableZat) {
        final missing = (sendZat - _spendableZat) / ZECUNIT;
        setState(() => _error = 'Insufficient ZEC (need ${missing.toStringAsFixed(8)} more)');
        return;
      }
    }

    setState(() { _loadingQuote = true; _error = null; });

    try {
      final amountBigInt = _toBigInt(parsed, _originToken.decimals);
      final tAddr = WarpApi.getAddress(aa.coin, aa.id, 1);
      _cachedTAddr = tAddr;
      final refund = _direction == SwapDirection.fromZec ? tAddr : addr;
      final recipient = _direction == SwapDirection.fromZec ? addr : tAddr;

      logger.i('[Swap] getQuote: origin=${_originToken.symbol} dest=${_destToken.symbol} slippage=$_slippageBps');

      final quote = await _nearApi.getQuote(
        dry: false,
        originAsset: _originToken.assetId,
        destinationAsset: _destToken.assetId,
        amount: amountBigInt,
        refundTo: refund,
        recipient: recipient,
        slippageBps: _slippageBps,
      );

      logger.i('[Swap] Quote received OK');

      if (!mounted) return;
      setState(() => _loadingQuote = false);
      _showConfirmationSheet(quote, amountStr, parsed);
    } on NearIntentsException catch (e) {
      logger.e('[Swap] Quote NearIntentsException: ${e.message}');
      if (mounted) setState(() { _error = e.message; _loadingQuote = false; });
    } catch (e) {
      logger.e('[Swap] Quote error: $e');
      if (mounted) setState(() { _error = e.toString(); _loadingQuote = false; });
    }
  }

  // ─── Confirmation Bottom Sheet (Zashi-style) ──────────────

  void _showConfirmationSheet(NearQuoteResponse quote, String amountStr, double amountDouble) {
    final origin = _originToken;
    final dest = _destToken;
    final amountIn = quote.amountIn.toDouble() / math.pow(10, origin.decimals);
    final amountOut = quote.amountOut.toDouble() / math.pow(10, dest.decimals);
    final usdIn = origin.price != null ? amountIn * origin.price! : 0.0;
    final usdOut = dest.price != null ? amountOut * dest.price! : 0.0;
    final slippageUsd = usdOut * _slippageBps / 10000;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: ZipherWidgets.sheetDecoration,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ZipherWidgets.sheetHandle(),
                  const Gap(20),

                  Text('Swap Now', style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700,
                    color: ZipherColors.text90,
                  )),
                  const Gap(24),

                  // Two token cards side by side
                  Row(
                    children: [
                      Expanded(child: _confirmTokenCard(
                        token: origin,
                        amount: amountIn,
                        usd: usdIn,
                        color: ZipherColors.cyan,
                      )),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Icon(Icons.arrow_forward_rounded, size: 16,
                            color: ZipherColors.text20),
                      ),
                      Expanded(child: _confirmTokenCard(
                        token: dest,
                        amount: amountOut,
                        usd: usdOut,
                        color: ZipherColors.purple,
                      )),
                    ],
                  ),
                  const Gap(20),

                  // Details
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        _detailRow('Swap from', 'Zipher'),
                        _sheetDivider(),
                        _detailRow('Swap to', centerTrim(_addressController.text.trim(), length: 16)),
                        _sheetDivider(),
                        _detailRow('Slippage', '${(_slippageBps / 100).toStringAsFixed(1)}%'),
                        if (quote.deadline.isNotEmpty) ...[
                          _sheetDivider(),
                          _detailRow('Expires', _fmtDeadline(quote.deadline)),
                        ],
                        _sheetDivider(),
                        _detailRow('Total Amount',
                          '${amountIn.toStringAsFixed(8)} ${origin.symbol}',
                          subtitle: '\$${usdIn.toStringAsFixed(2)}',
                          bold: true,
                        ),
                      ],
                    ),
                  ),
                  const Gap(12),

                  // Slippage warning
                  if (slippageUsd > 0.01)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded, size: 14,
                              color: ZipherColors.text20),
                          const Gap(8),
                          Expanded(
                            child: Text(
                              'You could receive up to \$${slippageUsd.toStringAsFixed(2)} less based on the ${(_slippageBps / 100).toStringAsFixed(1)}% slippage you set.',
                              style: TextStyle(
                                fontSize: 11,
                                color: ZipherColors.text40,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Confirm button
                  GestureDetector(
                    onTap: () async {
                      final protectSend = appSettings.protectSend;
                      if (protectSend) {
                        final authed = await authBarrier(ctx, dismissable: true);
                        if (!authed) return;
                      }
                      Navigator.pop(ctx);
                      await Future.delayed(const Duration(milliseconds: 300));
                      _executeSwap(quote, amountStr);
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        gradient: ZipherColors.primaryGradient,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Text('Confirm', style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700,
                          color: ZipherColors.textOnBrand,
                        )),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _confirmTokenCard({
    required NearToken token,
    required double amount,
    required double usd,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.10)),
      ),
      child: Column(
        children: [
          TokenIcon(token: token, size: 32, showChainBadge: true),
          const Gap(8),
          Text(token.symbol, style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700,
            color: ZipherColors.text90,
          )),
          Text(_chainDisplayName(token.blockchain), style: TextStyle(
            fontSize: 10, color: ZipherColors.text40,
          )),
          const Gap(8),
          Text(
            amount.toStringAsFixed(amount < 1 ? 6 : 4),
            style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w600,
              color: ZipherColors.text90,
            ),
          ),
          Text(
            '\$${usd.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 11, color: ZipherColors.text40,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, {String? subtitle, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(
            fontSize: 12,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            color: bold ? ZipherColors.text60 : ZipherColors.text40,
          )),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value, style: TextStyle(
                fontSize: 12,
                fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
                color: bold ? ZipherColors.text90 : ZipherColors.text60,
              )),
              if (subtitle != null)
                Text(subtitle, style: TextStyle(
                  fontSize: 10, color: ZipherColors.text20,
                )),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sheetDivider() => Divider(height: 1, color: ZipherColors.cardBg);

  // ─── Execute Swap ────────────────────────────────────────

  Map<String, dynamic> _statusExtra(NearQuoteResponse quote, String amountStr) {
    final origin = _originToken;
    final dest = _destToken;
    final outDouble = quote.amountOut.toDouble() / math.pow(10, dest.decimals);
    return {
      'depositAddress': quote.depositAddress,
      'fromCurrency': origin.symbol,
      'fromAmount': amountStr,
      'toCurrency': dest.symbol,
      'toAmount': outDouble.toStringAsFixed(8),
    };
  }

  void _executeSwap(NearQuoteResponse quote, String amountStr) async {
    logger.i('[Swap] _executeSwap: direction=$_direction');
    if (_direction == SwapDirection.fromZec) {
      _executeZecSend(quote, amountStr);
    } else {
      try {
        await _storeSwap(quote, amountStr);
      } catch (e, st) {
        logger.e('[Swap] intoZec store error: $e\n$st');
      }
      try {
        if (mounted) {
          GoRouter.of(context).push('/swap/status', extra: _statusExtra(quote, amountStr));
        }
      } catch (e, st) {
        logger.e('[Swap] intoZec nav error: $e\n$st');
      }
    }
  }

  Future<void> _executeZecSend(NearQuoteResponse quote, String amountStr) async {
    load(() async {
      try {
        final depositAddr = quote.depositAddress;
        final amountZat = stringToAmount(amountStr);

        final recipient = Recipient(RecipientObjectBuilder(
          address: depositAddr,
          amount: amountZat,
        ).toBytes());

        final txPlan = await WarpApi.prepareTx(
          aa.coin, aa.id, [recipient], 7,
          coinSettings.replyUa, appSettings.anchorOffset, coinSettings.feeT,
        );

        final txIdJson = await WarpApi.signAndBroadcast(aa.coin, aa.id, txPlan);
        final txId = jsonDecode(txIdJson);

        try {
          await _nearApi.submitDeposit(txHash: txId, depositAddress: depositAddr);
        } catch (e) {
          logger.w('[Swap] NEAR deposit notification failed: $e');
        }

        if (mounted) {
          GoRouter.of(context).push('/swap/status', extra: _statusExtra(quote, amountStr));
        }

        await _storeSwap(quote, amountStr, txId: txId);
      } on String catch (e) {
        logger.e('[Swap] String error: $e');
        if (mounted) showMessageBox2(context, 'Error', e);
      } catch (e, st) {
        logger.e('[Swap] Unexpected error: $e\n$st');
        if (mounted) showMessageBox2(context, 'Error', e.toString());
      }
    });
  }

  Future<void> _storeSwap(NearQuoteResponse quote, String amountStr, {String? txId}) async {
    final origin = _originToken;
    final dest = _destToken;
    final outDouble = quote.amountOut.toDouble() / math.pow(10, dest.decimals);

    final swap = StoredSwap(
      provider: 'near_intents',
      depositAddress: quote.depositAddress,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      fromCurrency: origin.symbol,
      fromAmount: amountStr,
      toCurrency: dest.symbol,
      toAmount: outDouble.toStringAsFixed(8),
      toAddress: _direction == SwapDirection.fromZec
          ? _addressController.text.trim()
          : _cachedTAddr,
      txId: txId,
    );
    await SwapStore.save(swap);
  }

  // ═══════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return wrapWithLoading(
      Scaffold(
        backgroundColor: ZipherColors.bg,
        body: _loadingTokens
            ? const Center(child: CircularProgressIndicator())
            : _zecToken == null
                ? _buildErrorState(topPad)
                : _buildBody(topPad),
      ),
    );
  }

  Widget _buildErrorState(double topPad) {
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(40, topPad + 60, 40, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                color: ZipherColors.red.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.wifi_off_rounded, size: 26,
                  color: ZipherColors.red.withValues(alpha: 0.5)),
            ),
            const Gap(20),
            Text('Could not load tokens', style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w600,
              color: ZipherColors.text90,
            )),
            const Gap(8),
            Text(
              _error ?? 'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ZipherColors.text40, height: 1.5),
            ),
            const Gap(24),
            GestureDetector(
              onTap: () {
                setState(() { _loadingTokens = true; _error = null; });
                _loadTokens();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.15)),
                ),
                child: Text('Retry', style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600,
                  color: ZipherColors.cyan.withValues(alpha: 0.8),
                )),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(double topPad) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Gap(topPad + 20),

            // ── Header ──
            Row(
              children: [
                Text('Swap', style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w700,
                  color: ZipherColors.text90,
                )),
                const Spacer(),
                GestureDetector(
                  onTap: () => GoRouter.of(context).push('/account/swap/history'),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBgElevated,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.history_rounded, size: 18,
                        color: ZipherColors.text40),
                  ),
                ),
              ],
            ),
            const Gap(24),

            // ── From ──
            _buildFromSection(),

            const Gap(12),

            // ── Flip button ──
            Center(
              child: GestureDetector(
                onTap: _flipDirection,
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.swap_vert_rounded, size: 18,
                      color: ZipherColors.cyan.withValues(alpha: 0.7)),
                ),
              ),
            ),

            const Gap(12),

            // ── To ──
            _buildToSection(),

            const Gap(16),

            // ── Slippage + Rate ──
            _buildSlippageAndRate(),

            const Gap(20),

            // ── Address ──
            _buildAddressCard(),

            const Gap(20),

            // ── Error ──
            if (_error != null) ...[
              _buildError(),
              const Gap(20),
            ],

            // ── Get a quote button ──
            _buildQuoteButton(),
            const Gap(32),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // FROM section
  // ═══════════════════════════════════════════════════════════

  Widget _buildFromSection() {
    final isZecFrom = _direction == SwapDirection.fromZec;
    final token = isZecFrom ? _zecToken! : _selectedToken;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('From', style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w500,
              color: ZipherColors.text40,
            )),
            const Spacer(),
            if (isZecFrom) ...[
              Text(
                'Spendable: ${amountToString2(_spendableZat)}',
                style: TextStyle(fontSize: 12, color: ZipherColors.text40),
              ),
              const Gap(8),
              GestureDetector(
                onTap: () {
                  final maxZec = _spendableZat / ZECUNIT;
                  final fee = 0.00001;
                  final maxSend = maxZec - fee;
                  if (maxSend <= 0) return;
                  _amountController.text = maxSend.toStringAsFixed(8);
                  _onAmountChanged('');
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: ZipherColors.cyan.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('MAX', style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: ZipherColors.cyan.withValues(alpha: 0.6),
                  )),
                ),
              ),
            ],
          ],
        ),
        const Gap(8),
        Container(
          height: 56,
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Gap(6),
              _buildTokenPill(token, isZecSide: isZecFrom),
              Expanded(
                child: TextField(
                  controller: _amountController,
                  onChanged: _onAmountChanged,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600,
                    color: ZipherColors.text90,
                  ),
                  decoration: InputDecoration(
                    hintText: '0.00',
                    hintStyle: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600,
                      color: ZipherColors.text10,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_inputUsd > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                '\$${_inputUsd.toStringAsFixed(2)}',
                style: TextStyle(fontSize: 12, color: ZipherColors.text20),
              ),
            ),
          ),
      ],
    );
  }

  double get _inputUsd {
    final parsed = double.tryParse(_amountController.text.trim()) ?? 0;
    if (parsed <= 0 || _originToken.price == null) return 0;
    return parsed * _originToken.price!;
  }

  // ═══════════════════════════════════════════════════════════
  // TO section
  // ═══════════════════════════════════════════════════════════

  Widget _buildToSection() {
    final isZecTo = _direction == SwapDirection.intoZec;
    final token = isZecTo ? _zecToken! : _selectedToken;
    final outputUsd = _destToken.price != null ? _estimatedOutput * _destToken.price! : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('To', style: TextStyle(
          fontSize: 14, fontWeight: FontWeight.w500,
          color: ZipherColors.text40,
        )),
        const Gap(8),
        Container(
          height: 56,
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Gap(6),
              _buildTokenPill(token, isZecSide: isZecTo),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  _estimatedOutput > 0
                      ? _estimatedOutput.toStringAsFixed(_estimatedOutput < 1 ? 6 : 4)
                      : '0.00',
                  style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600,
                    color: _estimatedOutput > 0 ? ZipherColors.text90 : ZipherColors.text10,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (outputUsd > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                '\$${outputUsd.toStringAsFixed(2)}',
                style: TextStyle(fontSize: 12, color: ZipherColors.text20),
              ),
            ),
          ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Token pill
  // ═══════════════════════════════════════════════════════════

  Widget _buildTokenPill(NearToken? token, {required bool isZecSide}) {
    return GestureDetector(
      onTap: isZecSide ? null : _showTokenPicker,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        decoration: BoxDecoration(
          color: isZecSide ? Colors.transparent : ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (token != null)
              TokenIcon(token: token, size: 24, showChainBadge: false)
            else
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: ZipherColors.cardBgElevated,
                  shape: BoxShape.circle,
                ),
              ),
            const Gap(8),
            Text(
              token?.symbol ?? '???',
              style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
                color: ZipherColors.text90,
              ),
            ),
            if (!isZecSide) ...[
              const Gap(4),
              Icon(Icons.keyboard_arrow_down_rounded,
                  size: 16, color: ZipherColors.text20),
            ],
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Token picker
  // ═══════════════════════════════════════════════════════════

  void _showTokenPicker() {
    final searchController = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final query = searchController.text.toLowerCase();
            final filtered = query.isEmpty
                ? _swappableTokens
                : _swappableTokens.where((t) =>
                    t.symbol.toLowerCase().contains(query) ||
                    t.blockchain.toLowerCase().contains(query) ||
                    _chainDisplayName(t.blockchain).toLowerCase().contains(query)).toList();
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7,
              ),
              decoration: ZipherWidgets.sheetDecoration,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ZipherWidgets.sheetHandle(),
                  const Gap(16),
                  Text('SELECT ASSET', style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: ZipherColors.text60,
                  )),
                  const Gap(14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: ZipherColors.cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: ZipherColors.borderSubtle),
                      ),
                      child: TextField(
                        controller: searchController,
                        onChanged: (_) => setModalState(() {}),
                        style: TextStyle(fontSize: 14, color: ZipherColors.text90),
                        decoration: InputDecoration(
                          hintText: 'Search by name or ticker...',
                          hintStyle: TextStyle(color: ZipherColors.text20),
                          prefixIcon: Icon(Icons.search_rounded, size: 18,
                              color: ZipherColors.text20),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const Gap(8),
                  Divider(height: 1, color: ZipherColors.cardBg,
                      indent: 20, endIndent: 20),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 16),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final t = filtered[i];
                        final isSelected = t.assetId == _selectedToken?.assetId;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                setState(() { _selectedToken = t; });
                                Navigator.pop(ctx);
                                _updateEstimate();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? ZipherColors.cardBg
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    TokenIcon(token: t, size: 38),
                                    const Gap(12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(t.symbol, style: TextStyle(
                                            fontSize: 14, fontWeight: FontWeight.w600,
                                            color: ZipherColors.text90,
                                          )),
                                          const Gap(2),
                                          Text(_chainDisplayName(t.blockchain), style: TextStyle(
                                            fontSize: 11,
                                            color: ZipherColors.text40,
                                          )),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right_rounded, size: 18,
                                        color: isSelected ? ZipherColors.text60 : ZipherColors.text10),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Address card
  // ═══════════════════════════════════════════════════════════

  Widget _buildAddressCard() {
    final label = _direction == SwapDirection.fromZec ? 'Recipient address' : 'Refund address';
    final chain = _selectedToken?.blockchain ?? '';
    final hint = _direction == SwapDirection.fromZec
        ? '${_chainDisplayName(chain)} address'
        : 'Your ${_chainDisplayName(chain)} address';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(
          fontSize: 14, fontWeight: FontWeight.w500,
          color: ZipherColors.text40,
        )),
        const Gap(8),
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
          ),
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
                    hintText: hint,
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
                ),
              ),
              _iconBtn(Icons.content_paste_rounded, () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null && data!.text!.isNotEmpty) {
                  _addressController.text = data.text!;
                }
              }),
              _iconBtn(Icons.qr_code_rounded, () {
                GoRouter.of(context).push(
                  '/scan',
                  extra: ScanQRContext((code) {
                    _addressController.text = code;
                    return true;
                  }),
                );
              }),
              const Gap(4),
            ],
          ),
        ),
      ],
    );
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
  // Slippage + Rate (inline like Zashi)
  // ═══════════════════════════════════════════════════════════

  Widget _buildSlippageAndRate() {
    return Column(
      children: [
        Row(
          children: [
            Text('Slippage tolerance', style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w500,
              color: ZipherColors.text40,
            )),
            const Spacer(),
            for (final bps in [50, 100, 200])
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _slippageBps = bps),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _slippageBps == bps
                          ? ZipherColors.cyan.withValues(alpha: 0.10)
                          : ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _slippageBps == bps
                            ? ZipherColors.cyan.withValues(alpha: 0.20)
                            : ZipherColors.borderSubtle,
                      ),
                    ),
                    child: Text(
                      '${(bps / 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600,
                        color: _slippageBps == bps
                            ? ZipherColors.cyan.withValues(alpha: 0.7)
                            : ZipherColors.text40,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (_rate > 0) ...[
          const Gap(12),
          Row(
            children: [
              Text('Rate', style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500,
                color: ZipherColors.text40,
              )),
              const Spacer(),
              Text(
                '1 ${_originToken.symbol} = ${_rate.toStringAsFixed(_rate < 1 ? 6 : 4)} ${_destToken.symbol}',
                style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500,
                  color: ZipherColors.text60,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Error banner
  // ═══════════════════════════════════════════════════════════

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZipherColors.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZipherColors.red.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16,
              color: ZipherColors.red.withValues(alpha: 0.5)),
          const Gap(10),
          Expanded(
            child: Text(_error!, style: TextStyle(
              fontSize: 12,
              color: ZipherColors.red.withValues(alpha: 0.7),
              height: 1.4,
            )),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // "Get a quote" button
  // ═══════════════════════════════════════════════════════════

  Widget _buildQuoteButton() {
    final hasAmount = _amountController.text.trim().isNotEmpty;
    final hasAddress = _addressController.text.trim().isNotEmpty;
    final enabled = hasAmount && hasAddress && _selectedToken != null && !_loadingQuote;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? _getQuote : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: enabled
                ? ZipherColors.cyan.withValues(alpha: 0.12)
                : ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_loadingQuote)
                SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: ZipherColors.cyan.withValues(alpha: 0.6),
                  ),
                )
              else ...[
                Icon(Icons.swap_horiz_rounded,
                    size: 20,
                    color: enabled
                        ? ZipherColors.cyan.withValues(alpha: 0.9)
                        : ZipherColors.text10),
                const Gap(10),
                Text(
                  'Get a quote',
                  style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600,
                    color: enabled
                        ? ZipherColors.cyan.withValues(alpha: 0.9)
                        : ZipherColors.text10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════

  String _chainDisplayName(String chain) {
    const names = {
      'eth': 'Ethereum', 'btc': 'Bitcoin', 'sol': 'Solana', 'arb': 'Arbitrum',
      'base': 'Base', 'bsc': 'Binance Smart Chain', 'tron': 'Tron',
      'near': 'NEAR', 'pol': 'Polygon', 'op': 'Optimism', 'avax': 'Avalanche',
      'gnosis': 'Gnosis', 'sui': 'Sui', 'ton': 'TON', 'stellar': 'Stellar',
      'doge': 'Dogecoin', 'xrp': 'XRP Ledger', 'ltc': 'Litecoin',
      'bch': 'Bitcoin Cash', 'cardano': 'Cardano', 'aptos': 'Aptos',
      'starknet': 'Starknet', 'bera': 'Berachain', 'aleo': 'Aleo',
      'monad': 'Monad', 'xlayer': 'X Layer', 'plasma': 'Plasma',
    };
    return names[chain.toLowerCase()] ?? chain;
  }

  String _fmtDeadline(String iso) {
    try {
      final dt = DateTime.parse(iso);
      final diff = dt.difference(DateTime.now().toUtc());
      if (diff.isNegative) return 'Expired';
      if (diff.inMinutes > 60) return '${diff.inHours}h ${diff.inMinutes % 60}m';
      return '${diff.inMinutes}m';
    } catch (_) { return iso; }
  }
}
