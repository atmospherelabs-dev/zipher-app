import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import '../../zipher_theme.dart';
import '../../accounts.dart';
import '../../services/wallet_service.dart';
import '../../services/ironwood_watch_service.dart';
import '../../src/rust/api/engine_api.dart' as engine;
import '../utils.dart';

class IronwoodPage extends StatefulWidget {
  const IronwoodPage({super.key});

  @override
  State<IronwoodPage> createState() => _IronwoodState();
}

enum _Phase { warning, ready, roundInProgress, success, error }

class _IronwoodState extends State<IronwoodPage> {
  _Phase _phase = _Phase.warning;
  String? _error;
  String? _txid;
  int? _lastAmount;
  int? _lastFee;
  bool _autoMode = false;

  int get _orchardBalance => aa.poolBalances.totalOrchard;

  @override
  void initState() {
    super.initState();
    if (IronwoodWatchService.instance.isMigrationActive) {
      _phase = _Phase.ready;
      _autoMode = true;
    }
  }

  Future<void> _doSingleRound() async {
    setState(() {
      _phase = _Phase.roundInProgress;
      _error = null;
      _txid = null;
      _lastAmount = null;
      _lastFee = null;
    });

    try {
      final round = await engine.engineMigrationNextRound(
        orchardBalanceZat: BigInt.from(_orchardBalance),
        largestNoteZat: BigInt.from(_orchardBalance),
        noteCount: 1,
      );

      if (round.action == 'done') {
        setState(() => _phase = _Phase.success);
        return;
      }

      if (round.action == 'consolidate') {
        setState(() {
          _error = 'Consolidation needed — notes are too small. Try again after syncing.';
          _phase = _Phase.error;
        });
        return;
      }

      final proposal = await engine.engineProposePoolTransfer(
        amount: round.amountZat,
        isMax: false,
      );

      setState(() {
        _lastAmount = proposal.sendAmount.toInt();
        _lastFee = proposal.fee.toInt();
      });

      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) throw Exception('Could not access wallet seed');

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

  void _startAutoMigration() {
    IronwoodWatchService.instance.startMigration();
    setState(() => _autoMode = true);
  }

  void _stopAutoMigration() {
    IronwoodWatchService.instance.stopMigration();
    setState(() => _autoMode = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'IRONWOOD MIGRATION',
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
      case _Phase.warning:
        return _buildWarningView();
      case _Phase.ready:
        return _buildReadyView();
      case _Phase.roundInProgress:
        return _buildProgressView();
      case _Phase.success:
        return _buildSuccessView();
      case _Phase.error:
        return _buildErrorView();
    }
  }

  Widget _buildWarningView() {
    return ListView(
      children: [
        const Gap(24),
        Icon(Icons.privacy_tip_outlined, color: ZipherColors.warm, size: 48),
        const Gap(16),
        Text(
          'Privacy Notice',
          style: TextStyle(
            color: ZipherColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const Gap(16),
        _warningCard(
          icon: Icons.visibility_outlined,
          title: 'Amount Visible On-Chain',
          body: 'Migration transactions reveal the transferred amount publicly '
              'on the blockchain. This is required by the turnstile mechanism '
              'to verify Zcash supply integrity.',
        ),
        const Gap(12),
        _warningCard(
          icon: Icons.wifi_outlined,
          title: 'IP Address Linkage',
          body: 'Your lightwalletd server can see your IP address alongside '
              'the migration amount. Without Tor, the server operator could '
              'learn your approximate balance.',
        ),
        const Gap(12),
        _warningCard(
          icon: Icons.shield_outlined,
          title: 'Mitigations Applied',
          body: 'Zipher uses randomized amounts (from a fixed set of buckets) '
              'and randomized timing (median 10-minute delays) to blend your '
              'migration with other users. Amounts are selected via '
              'coin-flip stepping to conceal your total balance.',
        ),
        const Gap(24),

        // Prominent Tor/Nym prompt
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZipherColors.warm.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZipherColors.warm.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.vpn_lock_rounded, color: ZipherColors.warm, size: 22),
                  const Gap(10),
                  Expanded(
                    child: Text(
                      'Connect to Tor or Nym Before Migrating',
                      style: TextStyle(
                        color: ZipherColors.warm,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const Gap(10),
              Text(
                'To protect your IP address from being linked to your '
                'migration amounts, connect to a network privacy layer '
                'before proceeding:',
                style: TextStyle(color: ZipherColors.text60, fontSize: 13),
              ),
              const Gap(10),
              _torStep('1', 'Enable Tor (e.g. Orbot app) or a Nym mixnet client'),
              const Gap(6),
              _torStep('2', 'Verify your connection is routed through Tor/Nym'),
              const Gap(6),
              _torStep('3', 'Then return here and start the migration'),
              const Gap(12),
              Text(
                'Without this, your lightwalletd server can see both your '
                'IP address and each migration amount — effectively revealing '
                'your balance to the server operator.',
                style: TextStyle(
                  color: ZipherColors.text40,
                  fontSize: 11.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        const Gap(32),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: () => setState(() => _phase = _Phase.ready),
            style: ElevatedButton.styleFrom(
              backgroundColor: ZipherColors.cyan,
              foregroundColor: ZipherColors.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'I Understand, Continue',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const Gap(12),
        Center(
          child: TextButton(
            onPressed: () => context.pop(),
            child: Text('Cancel', style: TextStyle(color: ZipherColors.text40)),
          ),
        ),
        const Gap(40),
      ],
    );
  }

  Widget _torStep(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: ZipherColors.warm.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(number,
                style: TextStyle(
                    color: ZipherColors.warm,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
        ),
        const Gap(8),
        Expanded(
          child: Text(text,
              style: TextStyle(color: ZipherColors.textPrimary, fontSize: 13)),
        ),
      ],
    );
  }

  Widget _warningCard({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: ZipherColors.warm, size: 20),
          const Gap(12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                      color: ZipherColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    )),
                const Gap(4),
                Text(body,
                    style: TextStyle(
                      color: ZipherColors.text60,
                      fontSize: 13,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
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
              'Migration Complete',
              style: TextStyle(color: ZipherColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const Gap(8),
            Text(
              'All funds are in the Ironwood pool.',
              style: TextStyle(color: ZipherColors.text60, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const Gap(24),
            TextButton(
              onPressed: () => context.pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        const Gap(24),

        // Balance card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZipherColors.borderSubtle),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.account_balance_wallet_outlined,
                      color: ZipherColors.purple, size: 20),
                  const Gap(12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Orchard balance to migrate',
                          style: TextStyle(color: ZipherColors.text40, fontSize: 12)),
                      const Gap(2),
                      Text(
                        '${amountToString2(orchard)} ZEC',
                        style: TextStyle(
                          color: ZipherColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'JetBrains Mono',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (aa.poolBalances.totalIronwood > 0) ...[
                const Gap(12),
                Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        color: ZipherColors.cyan, size: 16),
                    const Gap(8),
                    Text(
                      '${amountToString2(aa.poolBalances.totalIronwood)} ZEC already in Ironwood',
                      style: TextStyle(color: ZipherColors.cyan, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Gap(24),

        // Migration mode explanation
        Text(
          'How Migration Works',
          style: TextStyle(
            color: ZipherColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Gap(8),
        Text(
          'Funds are migrated in randomized rounds using amounts from a '
          'fixed set of buckets (0.001 to 5000 ZEC). Each round is separated '
          'by a random delay (median 10 minutes) to blend with other users.',
          style: TextStyle(color: ZipherColors.text60, fontSize: 13),
        ),
        const Gap(24),

        // Auto migration toggle
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _autoMode
                ? ZipherColors.cyan.withValues(alpha: 0.08)
                : ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _autoMode
                  ? ZipherColors.cyan.withValues(alpha: 0.3)
                  : ZipherColors.borderSubtle,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Automatic Migration',
                        style: TextStyle(
                          color: ZipherColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        )),
                    const Gap(2),
                    Text(
                      _autoMode
                          ? 'Running — rounds execute automatically'
                          : 'Rounds will execute while the app is open',
                      style: TextStyle(color: ZipherColors.text40, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _autoMode,
                onChanged: (v) {
                  if (v) {
                    _startAutoMigration();
                  } else {
                    _stopAutoMigration();
                  }
                },
                activeTrackColor: ZipherColors.cyan,
                thumbColor: WidgetStatePropertyAll(ZipherColors.textPrimary),
              ),
            ],
          ),
        ),
        const Gap(16),

        // Manual trigger button
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _doSingleRound,
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text(
              'Migrate Now',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: ZipherColors.cyan,
              foregroundColor: ZipherColors.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const Gap(8),
        Center(
          child: Text(
            'Executes one round immediately (user-triggered)',
            style: TextStyle(color: ZipherColors.text40, fontSize: 11),
          ),
        ),
        const Gap(32),
      ],
    );
  }

  Widget _buildProgressView() {
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
            'Migration Round in Progress',
            style: TextStyle(color: ZipherColors.textPrimary, fontSize: 16),
          ),
          const Gap(8),
          Text(
            'Selecting amount, generating proof, broadcasting...',
            style: TextStyle(color: ZipherColors.text40, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          if (_lastAmount != null) ...[
            const Gap(12),
            Text(
              'Amount: ${amountToString2(_lastAmount!)} ZEC',
              style: TextStyle(
                color: ZipherColors.textPrimary,
                fontSize: 14,
                fontFamily: 'JetBrains Mono',
              ),
            ),
          ],
          if (_lastFee != null) ...[
            const Gap(4),
            Text(
              'Fee: ${amountToString2(_lastFee!)} ZEC',
              style: TextStyle(color: ZipherColors.text40, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    final isDone = _orchardBalance == 0;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDone ? Icons.celebration_outlined : Icons.check_circle_outline,
            color: ZipherColors.cyan,
            size: 72,
          ),
          const Gap(24),
          Text(
            isDone ? 'Migration Complete' : 'Round Complete',
            style: TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(12),
          if (_lastAmount != null)
            Text(
              '${amountToString2(_lastAmount!)} ZEC moved to Ironwood',
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
          if (!isDone) ...[
            const Gap(8),
            Text(
              'Remaining: ${amountToString2(_orchardBalance)} ZEC',
              style: TextStyle(color: ZipherColors.text60, fontSize: 13),
            ),
          ],
          const Gap(32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!isDone)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _phase = _Phase.ready;
                      _txid = null;
                      _lastAmount = null;
                      _lastFee = null;
                    });
                  },
                  child: Text('Continue',
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
            'Round Failed',
            style: TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _error ?? 'Unknown error',
              style: TextStyle(color: ZipherColors.text60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
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
