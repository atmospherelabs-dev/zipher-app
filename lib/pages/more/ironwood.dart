import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import '../../zipher_theme.dart';
import '../../accounts.dart';
import '../../services/wallet_service.dart';
import '../../src/rust/api/engine_api.dart' as engine;
import '../utils.dart';

class IronwoodPage extends StatefulWidget {
  const IronwoodPage({super.key});

  @override
  State<IronwoodPage> createState() => _IronwoodState();
}

enum _Phase { ready, proposing, confirming, broadcasting, success, error }

class _IronwoodState extends State<IronwoodPage> {
  _Phase _phase = _Phase.ready;
  String? _error;
  String? _txid;
  int? _selectedAmountZat;
  int? _fee;

  int get _orchardBalance => aa.poolBalances.orchard;

  static const List<int> _denominations = [
    100000,      // 0.001 ZEC
    1000000,     // 0.01  ZEC
    10000000,    // 0.1   ZEC
    100000000,   // 1     ZEC
    1000000000,  // 10    ZEC
  ];

  List<int> get _availableDenoms {
    return _denominations.where((d) => d <= _orchardBalance).toList().reversed.toList();
  }

  String _formatZec(int zat) {
    final zec = zat / 100000000.0;
    if (zec >= 1.0) return '${zec.toStringAsFixed(0)} ZEC';
    if (zec >= 0.01) return '${zec.toStringAsFixed(2)} ZEC';
    return '${zec.toStringAsFixed(3)} ZEC';
  }

  Future<void> _transfer(int amountZat) async {
    setState(() {
      _selectedAmountZat = amountZat;
      _phase = _Phase.proposing;
      _error = null;
      _fee = null;
    });

    try {
      final addresses = await engine.engineGetAddresses();
      if (addresses.isEmpty) throw Exception('No wallet address available');
      final ownAddress = addresses.first.address;

      final proposal = await engine.engineProposeSend(
        address: ownAddress,
        amount: BigInt.from(amountZat),
        memo: null,
        isMax: false,
        priority: false,
      );

      setState(() {
        _fee = proposal.fee.toInt();
        _phase = _Phase.confirming;
      });

      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) throw Exception('Could not access wallet seed');

      setState(() => _phase = _Phase.broadcasting);

      final txid = await engine.engineConfirmSend(seedPhrase: seed);

      setState(() {
        _txid = txid;
        _phase = _Phase.success;
      });
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'IRONWOOD TRANSFER',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.ready:
        return _buildReadyView();
      case _Phase.proposing:
      case _Phase.confirming:
      case _Phase.broadcasting:
        return _buildProgressView();
      case _Phase.success:
        return _buildSuccessView();
      case _Phase.error:
        return _buildErrorView();
    }
  }

  Widget _buildReadyView() {
    final orchard = _orchardBalance;
    if (orchard == 0) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, color: ZipherColors.cyan, size: 56),
            const Gap(16),
            Text(
              'No Orchard funds to migrate',
              style: TextStyle(color: ZipherColors.text60, fontSize: 15),
            ),
            const Gap(8),
            Text(
              'Your funds are already in the Ironwood pool.',
              style: TextStyle(color: ZipherColors.text40, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const Gap(24),
            TextButton(
              onPressed: () => context.pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      );
    }

    final denoms = _availableDenoms;
    return ListView(
      children: [
        const Gap(24),
        Text(
          'Migrate Orchard to Ironwood',
          style: TextStyle(
            color: ZipherColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Gap(8),
        Text(
          'Transfer funds from the deprecated Orchard pool to the new Ironwood shielded pool.',
          style: TextStyle(color: ZipherColors.text60, fontSize: 14),
        ),
        const Gap(24),

        // Balance card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZipherColors.borderSubtle),
          ),
          child: Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  color: ZipherColors.purple, size: 20),
              const Gap(12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Orchard balance',
                      style: TextStyle(color: ZipherColors.text40, fontSize: 12)),
                  const Gap(2),
                  Text(
                    '${amountToString2(orchard)} ZEC',
                    style: TextStyle(
                      color: ZipherColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Gap(24),

        Text(
          'Choose amount to transfer',
          style: TextStyle(
            color: ZipherColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Gap(4),
        Text(
          'Each transfer is a single private transaction.',
          style: TextStyle(color: ZipherColors.text40, fontSize: 12),
        ),
        const Gap(16),

        // Denomination buttons grid
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: denoms.map((d) => _denomButton(d)).toList(),
        ),

        // "Max" button if balance doesn't match a clean denomination
        if (denoms.isEmpty || orchard > denoms.first) ...[
          const Gap(10),
          _maxButton(orchard),
        ],

        const Gap(32),

        // Info box
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: ZipherColors.cyan.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZipherColors.cyan.withValues(alpha: 0.2)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: ZipherColors.cyan, size: 16),
              const Gap(10),
              Expanded(
                child: Text(
                  'The Zcash SDK automatically routes your funds from Orchard to Ironwood. '
                  'Repeat transfers until your Orchard balance is zero.',
                  style: TextStyle(color: ZipherColors.text60, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
        const Gap(40),
      ],
    );
  }

  Widget _denomButton(int amountZat) {
    return SizedBox(
      width: 100,
      height: 48,
      child: ElevatedButton(
        onPressed: () => _transfer(amountZat),
        style: ElevatedButton.styleFrom(
          backgroundColor: ZipherColors.cardBgElevated,
          foregroundColor: ZipherColors.textPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: ZipherColors.borderSubtle),
          ),
          padding: EdgeInsets.zero,
        ),
        child: Text(
          _formatZec(amountZat),
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFamily: 'JetBrains Mono',
          ),
        ),
      ),
    );
  }

  Widget _maxButton(int orchardBal) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: () => _transferMax(),
        style: ElevatedButton.styleFrom(
          backgroundColor: ZipherColors.cyan.withValues(alpha: 0.1),
          foregroundColor: ZipherColors.cyan,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: ZipherColors.cyan.withValues(alpha: 0.3)),
          ),
        ),
        child: Text(
          'Transfer all (${amountToString2(orchardBal)} ZEC)',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Future<void> _transferMax() async {
    setState(() {
      _selectedAmountZat = _orchardBalance;
      _phase = _Phase.proposing;
      _error = null;
      _fee = null;
    });

    try {
      final addresses = await engine.engineGetAddresses();
      if (addresses.isEmpty) throw Exception('No wallet address available');
      final ownAddress = addresses.first.address;

      final proposal = await engine.engineProposeSend(
        address: ownAddress,
        amount: BigInt.from(_orchardBalance),
        memo: null,
        isMax: true,
        priority: false,
      );

      setState(() {
        _fee = proposal.fee.toInt();
        _phase = _Phase.confirming;
      });

      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) throw Exception('Could not access wallet seed');

      setState(() => _phase = _Phase.broadcasting);

      final txid = await engine.engineConfirmSend(seedPhrase: seed);

      setState(() {
        _txid = txid;
        _phase = _Phase.success;
      });
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _error = e.toString();
      });
    }
  }

  Widget _buildProgressView() {
    String message;
    switch (_phase) {
      case _Phase.proposing:
        message = 'Preparing transaction...';
        break;
      case _Phase.confirming:
        message = 'Generating proof...';
        break;
      case _Phase.broadcasting:
        message = 'Broadcasting...';
        break;
      default:
        message = '';
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              color: ZipherColors.cyan,
            ),
          ),
          const Gap(24),
          Text(
            message,
            style: TextStyle(color: ZipherColors.textPrimary, fontSize: 16),
          ),
          if (_selectedAmountZat != null) ...[
            const Gap(8),
            Text(
              'Transferring ${amountToString2(_selectedAmountZat!)} ZEC',
              style: TextStyle(color: ZipherColors.text40, fontSize: 13),
            ),
          ],
          if (_fee != null) ...[
            const Gap(4),
            Text(
              'Fee: ${amountToString2(_fee!)} ZEC',
              style: TextStyle(color: ZipherColors.text40, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, color: ZipherColors.cyan, size: 72),
          const Gap(24),
          Text(
            'Transfer Complete',
            style: TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(12),
          Text(
            '${amountToString2(_selectedAmountZat ?? 0)} ZEC moved to Ironwood',
            style: TextStyle(color: ZipherColors.text60, fontSize: 14),
          ),
          if (_txid != null) ...[
            const Gap(8),
            Text(
              'txid: ${_txid!.substring(0, 16)}...',
              style: TextStyle(
                color: ZipherColors.text40,
                fontSize: 11,
                fontFamily: 'JetBrains Mono',
              ),
            ),
          ],
          const Gap(32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _phase = _Phase.ready;
                    _txid = null;
                    _selectedAmountZat = null;
                    _fee = null;
                  });
                },
                child: Text('Transfer More',
                    style: TextStyle(color: ZipherColors.cyan)),
              ),
              const Gap(16),
              TextButton(
                onPressed: () => context.pop(),
                child: Text('Done',
                    style: TextStyle(color: ZipherColors.text60)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: ZipherColors.red, size: 48),
          const Gap(16),
          Text(
            'Transfer Failed',
            style: TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(8),
          Text(
            _error ?? 'Unknown error',
            style: TextStyle(color: ZipherColors.text60, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const Gap(24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _phase = _Phase.ready;
                    _error = null;
                  });
                },
                child: Text('Try Again',
                    style: TextStyle(color: ZipherColors.cyan)),
              ),
              const Gap(16),
              TextButton(
                onPressed: () => context.pop(),
                child: Text('Back',
                    style: TextStyle(color: ZipherColors.text60)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
