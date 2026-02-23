import 'dart:async';
import 'dart:math' as math;

import 'package:YWallet/pages/utils.dart';
import 'package:flutter/material.dart';
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
  NearQuoteResponse? _quote;
  String? _error;
  bool _loadingTokens = true;
  bool _loadingQuote = false;
  int _slippageBps = 100;
  Timer? _debounce;

  int get _spendableZat {
    final b = WarpApi.getPoolBalances(aa.coin, aa.id, appSettings.anchorOffset, false).unpack();
    return b.transparent + b.sapling + b.orchard;
  }

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
      _quote = null;
      _error = null;
    });
  }

  void _onAmountChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _fetchDryQuote);
  }

  Future<void> _fetchDryQuote() async {
    final amountStr = _amountController.text.trim();
    if (amountStr.isEmpty || _zecToken == null || _selectedToken == null) return;

    final parsed = double.tryParse(amountStr);
    if (parsed == null || parsed <= 0) return;

    final addrText = _addressController.text.trim();
    final hasAddress = addrText.isNotEmpty;

    if (!hasAddress) {
      _showPriceEstimate(parsed);
      return;
    }

    setState(() { _loadingQuote = true; _error = null; });

    try {
      final originToken = _direction == SwapDirection.fromZec ? _zecToken! : _selectedToken!;
      final amountBigInt = _toBigInt(parsed, originToken.decimals);

      final tAddr = WarpApi.getAddress(aa.coin, aa.id, 1);
      final refund = _direction == SwapDirection.fromZec ? tAddr : addrText;
      final recipient = _direction == SwapDirection.fromZec ? addrText : tAddr;

      final quote = await _nearApi.getQuote(
        dry: true,
        originAsset: originToken.assetId,
        destinationAsset: (_direction == SwapDirection.fromZec ? _selectedToken! : _zecToken!).assetId,
        amount: amountBigInt,
        refundTo: refund,
        recipient: recipient,
        slippageBps: _slippageBps,
      );

      if (mounted) setState(() { _quote = quote; _loadingQuote = false; });
    } on NearIntentsException catch (e) {
      if (mounted) setState(() { _error = e.message; _quote = null; _loadingQuote = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _quote = null; _loadingQuote = false; });
    }
  }

  void _showPriceEstimate(double inputAmount) {
    final originToken = _direction == SwapDirection.fromZec ? _zecToken! : _selectedToken!;
    final destToken = _direction == SwapDirection.fromZec ? _selectedToken! : _zecToken!;
    if (originToken.price == null || destToken.price == null ||
        originToken.price == 0 || destToken.price == 0) {
      setState(() { _quote = null; _error = null; _loadingQuote = false; });
      return;
    }
    final estOutput = inputAmount * originToken.price! / destToken.price!;
    final estOutBigInt = _toBigInt(estOutput, destToken.decimals);
    final estInBigInt = _toBigInt(inputAmount, originToken.decimals);
    setState(() {
      _quote = NearQuoteResponse(
        depositAddress: '',
        amountIn: estInBigInt,
        amountOut: estOutBigInt,
        deadline: '',
        raw: {'estimate': true},
      );
      _loadingQuote = false;
      _error = null;
    });
  }

  Future<void> _confirmSwap() async {
    final amountStr = _amountController.text.trim();
    if (amountStr.isEmpty || _zecToken == null || _selectedToken == null) return;

    final parsed = double.tryParse(amountStr);
    if (parsed == null || parsed <= 0) {
      setState(() => _error = 'Invalid amount');
      return;
    }

    if (_direction == SwapDirection.fromZec && _addressController.text.trim().isEmpty) {
      setState(() => _error = 'Enter recipient address on destination chain');
      return;
    }

    if (_direction == SwapDirection.fromZec) {
      final sendZat = stringToAmount(amountStr);
      if (sendZat > _spendableZat) {
        final missing = (sendZat - _spendableZat) / ZECUNIT;
        setState(() => _error = 'Insufficient ZEC balance (need ${missing.toStringAsFixed(8)} more)');
        return;
      }
    }

    setState(() { _loadingQuote = true; _error = null; });

    try {
      final originToken = _direction == SwapDirection.fromZec ? _zecToken! : _selectedToken!;
      final destToken = _direction == SwapDirection.fromZec ? _selectedToken! : _zecToken!;
      final amountBigInt = _toBigInt(parsed, originToken.decimals);

      final tAddr = WarpApi.getAddress(aa.coin, aa.id, 1);
      final refund = _direction == SwapDirection.fromZec ? tAddr : _addressController.text.trim();
      final recipient = _direction == SwapDirection.fromZec
          ? _addressController.text.trim()
          : tAddr;

      final quote = await _nearApi.getQuote(
        dry: false,
        originAsset: originToken.assetId,
        destinationAsset: destToken.assetId,
        amount: amountBigInt,
        refundTo: refund,
        recipient: recipient,
        slippageBps: _slippageBps,
      );

      setState(() { _quote = quote; _loadingQuote = false; });
      if (!mounted) return;

      if (_direction == SwapDirection.fromZec) {
        await _executeZecSend(quote, amountStr);
      } else {
        _showDepositInfo(quote, amountStr);
      }
    } on NearIntentsException catch (e) {
      if (mounted) setState(() { _error = e.message; _loadingQuote = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loadingQuote = false; });
    }
  }

  Future<void> _executeZecSend(NearQuoteResponse quote, String amountStr) async {
    load(() async {
      try {
        final depositAddr = quote.depositAddress;
        final recipient = Recipient(RecipientObjectBuilder(
          address: depositAddr,
          amount: stringToAmount(amountStr),
        ).toBytes());
        final txPlan = await WarpApi.prepareTx(
          aa.coin, aa.id, [recipient], 7,
          coinSettings.replyUa, appSettings.anchorOffset, coinSettings.feeT,
        );

        if (!mounted) return;
        final result = await GoRouter.of(context).push<String>(
          '/account/txplan?tab=swap',
          extra: txPlan,
        );

        if (result != null && result.isNotEmpty) {
          try {
            await _nearApi.submitDeposit(txHash: result, depositAddress: depositAddr);
          } catch (_) {}
          _storeSwap(quote, amountStr);
          if (mounted) GoRouter.of(context).push('/swap/status', extra: depositAddr);
        }
      } on String catch (e) {
        if (mounted) showMessageBox2(context, 'Error', e);
      }
    });
  }

  void _showDepositInfo(NearQuoteResponse quote, String amountStr) {
    _storeSwap(quote, amountStr);
    GoRouter.of(context).push('/swap/status', extra: quote.depositAddress);
  }

  void _storeSwap(NearQuoteResponse quote, String amountStr) {
    final originToken = _direction == SwapDirection.fromZec ? _zecToken! : _selectedToken!;
    final destToken = _direction == SwapDirection.fromZec ? _selectedToken! : _zecToken!;
    final outDouble = quote.amountOut.toDouble() / math.pow(10, destToken.decimals);

    final swap = SwapT(
      provider: 'near_intents',
      providerId: quote.depositAddress,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      fromCurrency: originToken.symbol,
      fromAmount: amountStr,
      fromAddress: quote.depositAddress,
      toCurrency: destToken.symbol,
      toAmount: outDouble.toStringAsFixed(8),
      toAddress: _direction == SwapDirection.fromZec
          ? _addressController.text.trim()
          : WarpApi.getAddress(aa.coin, aa.id, 1),
    );
    WarpApi.storeSwap(aa.coin, aa.id, swap);
  }

  // ─── Build ─────────────────────────────────────────────────

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
            Text(
              'Could not load tokens',
              style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
            const Gap(8),
            Text(
              _error ?? 'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.3),
                height: 1.5,
              ),
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
    final fromToken = _direction == SwapDirection.fromZec ? _zecToken! : _selectedToken;
    final toToken = _direction == SwapDirection.fromZec ? _selectedToken : _zecToken!;

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
                  color: Colors.white.withValues(alpha: 0.9),
                )),
                const Spacer(),
                GestureDetector(
                  onTap: () => GoRouter.of(context).push('/account/swap/history'),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.history_rounded, size: 18,
                        color: Colors.white.withValues(alpha: 0.4)),
                  ),
                ),
              ],
            ),
            const Gap(24),

            // ── You send ──
            _buildAmountCard(
              label: 'You send',
              token: fromToken,
              isInput: true,
            ),
            const Gap(2),

            // ── Flip button ──
            Center(
              child: GestureDetector(
                onTap: _flipDirection,
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: ZipherColors.bg,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Icon(Icons.swap_vert_rounded, size: 18,
                      color: ZipherColors.cyan.withValues(alpha: 0.7)),
                ),
              ),
            ),
            const Gap(2),

            // ── You receive ──
            _buildAmountCard(
              label: 'You receive',
              token: toToken,
              isInput: false,
            ),
            const Gap(16),

            // ── Address field ──
            if (_direction == SwapDirection.fromZec) ...[
              _buildAddressCard(
                label: 'Recipient address',
                hint: 'Enter ${_selectedToken?.blockchain ?? ''} address',
              ),
              const Gap(16),
            ],
            if (_direction == SwapDirection.intoZec) ...[
              _buildAddressCard(
                label: 'Refund address',
                hint: 'Your ${_selectedToken?.blockchain ?? ''} address',
              ),
              const Gap(16),
            ],

            // ── Slippage ──
            _buildSlippage(),
            const Gap(16),

            // ── Quote summary ──
            if (_quote != null) ...[
              _buildQuoteSummary(fromToken, toToken),
              const Gap(16),
            ],

            // ── Error ──
            if (_error != null) ...[
              _buildError(),
              const Gap(16),
            ],

            // ── Confirm button ──
            _buildConfirmButton(),
            const Gap(32),
          ],
        ),
      ),
    );
  }

  // ─── Amount card ───────────────────────────────────────────

  Widget _buildAmountCard({
    required String label,
    required NearToken? token,
    required bool isInput,
  }) {
    final showBalance = isInput && _direction == SwapDirection.fromZec;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.25),
              )),
              const Spacer(),
              if (showBalance)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Balance: ${amountToString2(_spendableZat)} ZEC',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                    const Gap(6),
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
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: ZipherColors.cyan.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.15)),
                        ),
                        child: Text('MAX', style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700,
                          color: ZipherColors.cyan.withValues(alpha: 0.6),
                          letterSpacing: 0.5,
                        )),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const Gap(12),
          Row(
            children: [
              Expanded(
                child: isInput
                    ? TextField(
                        controller: _amountController,
                        onChanged: _onAmountChanged,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                        decoration: InputDecoration(
                          hintText: '0.0',
                          hintStyle: TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.10),
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                      )
                    : Text(
                        _quoteOutputDisplay(token),
                        style: TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: _quote != null ? 0.9 : 0.10),
                        ),
                      ),
              ),
              const Gap(12),
              _buildTokenPill(token, isInput),
            ],
          ),
        ],
      ),
    );
  }

  String _quoteOutputDisplay(NearToken? token) {
    if (_loadingQuote) return '...';
    if (_quote == null || token == null) return '0.0';
    final out = _quote!.amountOut.toDouble() / math.pow(10, token.decimals);
    return out.toStringAsFixed(token.decimals > 6 ? 6 : token.decimals);
  }

  // ─── Token pill ────────────────────────────────────────────

  Widget _buildTokenPill(NearToken? token, bool isInput) {
    final isZecSide = (isInput && _direction == SwapDirection.fromZec) ||
        (!isInput && _direction == SwapDirection.intoZec);

    return GestureDetector(
      onTap: isZecSide ? null : _showTokenPicker,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
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
                  color: Colors.white.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.help_outline, size: 14,
                    color: Colors.white.withValues(alpha: 0.3)),
              ),
            const Gap(8),
            Text(
              token?.symbol ?? '???',
              style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
            if (!isZecSide) ...[
              const Gap(4),
              Icon(Icons.keyboard_arrow_down_rounded,
                  size: 16, color: Colors.white.withValues(alpha: 0.25)),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Token picker bottom sheet ─────────────────────────────

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
                    t.blockchain.toLowerCase().contains(query)).toList();
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7,
              ),
              decoration: BoxDecoration(
                color: ZipherColors.bg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.06), width: 0.5),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Gap(10),
                  Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const Gap(16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text('SELECT ASSET', style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                      color: Colors.white.withValues(alpha: 0.7),
                    )),
                  ),
                  const Gap(14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      child: TextField(
                        controller: searchController,
                        onChanged: (_) => setModalState(() {}),
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search by name or ticker...',
                          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
                          prefixIcon: Icon(Icons.search_rounded, size: 18,
                              color: Colors.white.withValues(alpha: 0.2)),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const Gap(8),
                  Divider(height: 1, color: Colors.white.withValues(alpha: 0.04),
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
                                setState(() { _selectedToken = t; _quote = null; });
                                Navigator.pop(ctx);
                                if (_amountController.text.trim().isNotEmpty) _fetchDryQuote();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Colors.white.withValues(alpha: 0.05)
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
                                            color: Colors.white.withValues(alpha: 0.9),
                                          )),
                                          const Gap(2),
                                          Text(_chainDisplayName(t.blockchain), style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white.withValues(alpha: 0.3),
                                          )),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right_rounded, size: 18,
                                        color: Colors.white.withValues(alpha: isSelected ? 0.5 : 0.12)),
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

  // ─── Address card ──────────────────────────────────────────

  Widget _buildAddressCard({required String label, required String hint}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.25),
          )),
          const Gap(4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addressController,
                  onChanged: (_) => _onAmountChanged(''),
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.12)),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  GoRouter.of(context).push(
                    '/scan',
                    extra: ScanQRContext((code) {
                      _addressController.text = code;
                      return true;
                    }),
                  );
                },
                child: Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.qr_code_scanner_rounded, size: 16,
                      color: Colors.white.withValues(alpha: 0.3)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

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

  // ─── Slippage ──────────────────────────────────────────────

  Widget _buildSlippage() {
    return Row(
      children: [
        Text('Slippage', style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w500,
          color: Colors.white.withValues(alpha: 0.25),
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
                      : Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _slippageBps == bps
                        ? ZipherColors.cyan.withValues(alpha: 0.20)
                        : Colors.white.withValues(alpha: 0.05),
                  ),
                ),
                child: Text(
                  '${(bps / 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: _slippageBps == bps
                        ? ZipherColors.cyan.withValues(alpha: 0.7)
                        : Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ─── Quote summary ────────────────────────────────────────

  Widget _buildQuoteSummary(NearToken? fromToken, NearToken? toToken) {
    if (_quote == null || fromToken == null || toToken == null) return const SizedBox();

    final originToken = _direction == SwapDirection.fromZec ? _zecToken! : _selectedToken!;
    final destToken = _direction == SwapDirection.fromZec ? _selectedToken! : _zecToken!;

    final amountIn = _quote!.amountIn.toDouble() / math.pow(10, originToken.decimals);
    final amountOut = _quote!.amountOut.toDouble() / math.pow(10, destToken.decimals);
    final rate = amountIn > 0 ? amountOut / amountIn : 0.0;
    final isEstimate = _quote!.raw['estimate'] == true;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          if (isEstimate) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Price estimate · enter address for exact quote',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic,
                    color: Colors.white.withValues(alpha: 0.2))),
            ),
            _divider(),
          ],
          _row('Rate', '1 ${originToken.symbol} ≈ ${rate.toStringAsFixed(6)} ${destToken.symbol}'),
          _divider(),
          _row('You send', '${amountIn.toStringAsFixed(8)} ${originToken.symbol}'),
          _divider(),
          _row('You receive', '≈ ${amountOut.toStringAsFixed(6)} ${destToken.symbol}'),
          if (!isEstimate) ...[
            _divider(),
            _row('Slippage', '${(_slippageBps / 100).toStringAsFixed(1)}%'),
          ],
          if (_quote!.deadline.isNotEmpty) ...[
            _divider(),
            _row('Expires', _fmtDeadline(_quote!.deadline)),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(
            fontSize: 12, color: Colors.white.withValues(alpha: 0.3),
          )),
          Flexible(
            child: Text(value, style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.7),
            ), textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Divider(height: 1, color: Colors.white.withValues(alpha: 0.04));

  String _fmtDeadline(String iso) {
    try {
      final dt = DateTime.parse(iso);
      final diff = dt.difference(DateTime.now().toUtc());
      if (diff.isNegative) return 'Expired';
      if (diff.inMinutes > 60) return '${diff.inHours}h ${diff.inMinutes % 60}m';
      return '${diff.inMinutes}m';
    } catch (_) { return iso; }
  }

  // ─── Error banner ──────────────────────────────────────────

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

  // ─── Confirm button ────────────────────────────────────────

  Widget _buildConfirmButton() {
    final enabled = _amountController.text.trim().isNotEmpty &&
        _selectedToken != null && !_loadingQuote;

    final label = _loadingQuote
        ? 'Getting quote...'
        : _direction == SwapDirection.fromZec
            ? 'Swap ZEC → ${_selectedToken?.symbol ?? ''}'
            : 'Swap ${_selectedToken?.symbol ?? ''} → ZEC';

    return GestureDetector(
      onTap: enabled ? _confirmSwap : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: enabled ? ZipherColors.primaryGradient : null,
          color: enabled ? null : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: _loadingQuote
              ? SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: enabled ? ZipherColors.textOnBrand : Colors.white.withValues(alpha: 0.2),
                  ),
                )
              : Text(label, style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600,
                  color: enabled
                      ? ZipherColors.textOnBrand
                      : Colors.white.withValues(alpha: 0.15),
                )),
        ),
      ),
    );
  }
}
