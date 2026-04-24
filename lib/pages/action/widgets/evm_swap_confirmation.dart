import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../../zipher_theme.dart';
import '../../../services/chain_config.dart';
import '../../../services/secure_key_store.dart';
import '../../../services/wallet_service.dart';
import '../../../src/rust/api/engine_api.dart' as rust_engine;
import '../../../coin/coins.dart' show isTestnet;

class EvmSwapConfirmation extends StatefulWidget {
  final String fromToken;
  final String toToken;
  final double amount;
  final ChainConfig chain;
  final String srcAddress;
  final int srcDecimals;
  final String destAddress;
  final int destDecimals;
  final void Function(String text) onResult;
  final VoidCallback? onBalanceChanged;

  const EvmSwapConfirmation({
    super.key,
    required this.fromToken,
    required this.toToken,
    required this.amount,
    required this.chain,
    required this.srcAddress,
    required this.srcDecimals,
    required this.destAddress,
    required this.destDecimals,
    required this.onResult,
    this.onBalanceChanged,
  });

  @override
  State<EvmSwapConfirmation> createState() => _EvmSwapConfirmationState();
}

class _EvmSwapConfirmationState extends State<EvmSwapConfirmation> {
  bool _loading = true;
  bool _executing = false;
  bool _confirmed = false;
  String? _error;

  String _destAmountHuman = '...';
  int _slippageBps = 200;

  @override
  void initState() {
    super.initState();
    _fetchQuote();
  }

  Future<void> _fetchQuote() async {
    try {
      final rawAmount = BigInt.from(
        (widget.amount * BigInt.from(10).pow(widget.srcDecimals).toDouble()).round(),
      );
      final quote = await rust_engine.engineEvmSwapQuote(
        chainId: BigInt.from(widget.chain.chainId),
        srcToken: widget.srcAddress,
        srcDecimals: widget.srcDecimals,
        destToken: widget.destAddress,
        destDecimals: widget.destDecimals,
        amountRaw: rawAmount.toString(),
        userAddress: await _getEvmAddress(),
      );

      final destRaw = BigInt.tryParse(quote.destAmount) ?? BigInt.zero;
      final destHuman = (destRaw / BigInt.from(10).pow(quote.destDecimals)).toDouble() +
          (destRaw % BigInt.from(10).pow(quote.destDecimals)).toDouble() /
              BigInt.from(10).pow(quote.destDecimals).toDouble();

      if (mounted) {
        setState(() {
          _destAmountHuman = destHuman.toStringAsFixed(destHuman >= 1 ? 4 : 6);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Quote failed: $e';
          _loading = false;
        });
      }
    }
  }

  Future<String> _getEvmAddress() async {
    final seed = await _getSeed();
    return rust_engine.engineDeriveEvmAddress(seedPhrase: seed);
  }

  Future<String> _getSeed() async {
    final walletId = WalletService.instance.activeWalletId;
    if (walletId == null) throw Exception('No active wallet');
    final key = isTestnet ? '${walletId}_testnet' : walletId;
    final seed = await SecureKeyStore.getSeedForWallet(key);
    if (seed == null) throw Exception('Seed not found');
    return seed;
  }

  Future<void> _executeSwap() async {
    if (_executing) return;
    setState(() {
      _executing = true;
      _confirmed = true;
    });
    HapticFeedback.mediumImpact();

    try {
      final seed = await _getSeed();
      final evmAddress = await rust_engine.engineDeriveEvmAddress(seedPhrase: seed);
      final rawAmount = BigInt.from(
        (widget.amount * BigInt.from(10).pow(widget.srcDecimals).toDouble()).round(),
      );

      final result = await rust_engine.engineEvmSwapExecute(
        rpcUrl: widget.chain.rpc.rpcUrl,
        seedPhrase: seed,
        chainId: BigInt.from(widget.chain.chainId),
        userAddress: evmAddress,
        srcToken: widget.srcAddress,
        srcDecimals: widget.srcDecimals,
        destToken: widget.destAddress,
        destDecimals: widget.destDecimals,
        amountRaw: rawAmount.toString(),
        slippageBps: _slippageBps,
      );

      if (result.success) {
        HapticFeedback.heavyImpact();
        widget.onResult(
          'Swap complete.\n'
          '${widget.amount} ${widget.fromToken} -> ~$_destAmountHuman ${widget.toToken}\n'
          'tx: ${result.txHash.substring(0, 10)}...${result.txHash.substring(result.txHash.length - 6)}',
        );
      } else {
        HapticFeedback.vibrate();
        widget.onResult('Swap reverted in block ${result.blockNumber}.');
      }
      widget.onBalanceChanged?.call();
    } catch (e) {
      HapticFeedback.vibrate();
      widget.onResult('Swap failed: $e');
    }

    if (mounted) setState(() => _executing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_confirmed) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle),
        ),
        child: Row(children: [
          const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.cyan),
          ),
          const Gap(12),
          const Text('Executing swap...', style: TextStyle(color: ZipherColors.textSecondary, fontSize: 13)),
        ]),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.swap_horiz_rounded, color: ZipherColors.cyan, size: 18),
          const Gap(8),
          Text('Confirm Swap', style: const TextStyle(
            color: ZipherColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
        const Gap(14),

        _detailRow('From', '${widget.amount.toStringAsFixed(widget.amount >= 1 ? 4 : 6)} ${widget.fromToken}'),
        _detailRow('To', _loading ? '...' : '$_destAmountHuman ${widget.toToken}'),
        _detailRow('Chain', widget.chain.name),
        _detailRow('Slippage', '${(_slippageBps / 100).toStringAsFixed(1)}%'),

        if (_error != null) ...[
          const Gap(8),
          Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],

        const Gap(16),
        Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () => widget.onResult('Swap cancelled.'),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: ZipherColors.text20),
              foregroundColor: ZipherColors.textSecondary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
            ),
            child: const Text('Cancel'),
          )),
          const Gap(12),
          Expanded(child: ElevatedButton(
            onPressed: _loading || _error != null ? null : _executeSwap,
            style: ElevatedButton.styleFrom(
              backgroundColor: ZipherColors.cyan,
              foregroundColor: ZipherColors.textOnBrand,
              disabledBackgroundColor: ZipherColors.text20,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZipherRadius.sm)),
            ),
            child: _loading
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.textPrimary))
                : const Text('Swap'),
          )),
        ]),
      ]),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 80, child: Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13))),
        Expanded(child: Text(value, style: const TextStyle(
          color: ZipherColors.textPrimary, fontSize: 13, fontFamily: 'JetBrains Mono'))),
      ]),
    );
  }
}
