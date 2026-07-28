import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  static const _prefTor = 'ironwood_tor_enabled';
  static const _prefAuto = 'ironwood_auto_migration';

  _Phase _phase = _Phase.warning;
  String? _error;
  String? _txid;
  int? _lastAmount;
  int? _lastFee;
  bool _autoMode = false;
  bool _torEnabled = false;
  bool _torBootstrapping = false;
  int? _torVerifiedHeight;

  int get _orchardBalance => aa.poolBalances.totalOrchard;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTor = prefs.getBool(_prefTor) ?? false;
    final savedAuto = prefs.getBool(_prefAuto) ?? false;

    if (IronwoodWatchService.instance.isAutoMigrationActive || savedAuto) {
      _phase = _Phase.ready;
      _autoMode = true;
    }

    // Show in-progress state if a round is currently executing
    if (IronwoodWatchService.instance.isRoundInProgress) {
      _phase = _Phase.roundInProgress;
    }

    if (mounted) setState(() {});

    // Re-enable Tor from saved preference
    if (savedTor) {
      await _toggleTor(true);
    } else {
      await _checkTorStatus();
    }
  }

  Future<void> _checkTorStatus() async {
    try {
      final enabled = await engine.engineIsTorEnabled();
      if (mounted) setState(() => _torEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _toggleTor(bool enable) async {
    final prefs = await SharedPreferences.getInstance();
    if (enable) {
      setState(() {
        _torBootstrapping = true;
        _torVerifiedHeight = null;
      });
      try {
        final dataDir = await WalletService.instance.walletDir();
        await engine.engineEnableTor(dataDir: dataDir);
        // Verify by fetching block height through Tor
        final height = await engine.engineVerifyTor();
        await prefs.setBool(_prefTor, true);
        if (mounted) setState(() {
          _torEnabled = true;
          _torBootstrapping = false;
          _torVerifiedHeight = height.toInt();
        });
      } catch (e) {
        await prefs.setBool(_prefTor, false);
        if (mounted) setState(() {
          _torBootstrapping = false;
          _torVerifiedHeight = null;
          _error = 'Tor failed: $e';
        });
      }
    } else {
      await engine.engineDisableTor();
      await prefs.setBool(_prefTor, false);
      if (mounted) setState(() {
        _torEnabled = false;
        _torVerifiedHeight = null;
      });
    }
  }

  Future<void> _doSingleRound() async {
    if (IronwoodWatchService.instance.isRoundInProgress) {
      setState(() {
        _error = 'A migration round is already in progress. Please wait for it to complete.';
        _phase = _Phase.error;
      });
      return;
    }

    setState(() {
      _phase = _Phase.roundInProgress;
      _error = null;
      _txid = null;
      _lastAmount = null;
      _lastFee = null;
    });

    IronwoodWatchService.instance.markRoundStarted();
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
      final msg = e.toString();
      String userMessage;
      if (msg.contains('InsufficientFunds') || msg.contains('insufficient')) {
        userMessage = 'Previous transaction hasn\'t confirmed yet. '
            'Wait ~75 seconds for the next block and try again.';
      } else if (msg.contains('Pool transfer proposal failed')) {
        userMessage = msg.replaceAll(RegExp(r'Stack backtrace:.*', dotAll: true), '').trim();
      } else {
        userMessage = msg.length > 200 ? '${msg.substring(0, 200)}...' : msg;
      }
      setState(() {
        _phase = _Phase.error;
        _error = userMessage;
      });
    } finally {
      IronwoodWatchService.instance.markRoundEnded();
    }
  }

  Future<void> _startAutoMigration() async {
    try {
      await IronwoodWatchService.instance.startAutoMigration(
        orchardBalanceZat: _orchardBalance,
        torEnabled: _torEnabled,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAuto, true);
      setState(() => _autoMode = true);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _stopAutoMigration() async {
    await IronwoodWatchService.instance.cancelAutoMigration();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAuto, false);
    setState(() => _autoMode = false);
  }

  String _autoMigrationSubtitle() {
    final state = IronwoodWatchService.instance.state;
    if (state == null) return 'Starting...';

    final done = state.migrationsConfirmed + state.migrationsBroadcast;
    final total = state.targets.length;
    final remaining = state.timeUntilNextBroadcast;

    if (state.phase == AutoPhase.complete) return 'Complete — all funds in Ironwood';
    if (remaining.inSeconds > 0) {
      final min = remaining.inMinutes;
      final sec = remaining.inSeconds % 60;
      return '$done/$total rounds — next in ${min}m ${sec}s';
    }
    return '$done/$total rounds — broadcasting...';
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
              _torStep('1', 'Use the built-in Tor toggle on the next screen, or enable an external Tor app (e.g. Orbot)'),
              const Gap(6),
              _torStep('2', 'Verify your connection is routed through Tor/Nym'),
              const Gap(6),
              _torStep('3', 'Then start the migration'),
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
              backgroundColor: ZipherColors.warm,
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
            Icon(Icons.check_circle_outline, color: ZipherColors.warm, size: 56),
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
                        color: ZipherColors.warm, size: 16),
                    const Gap(8),
                    Text(
                      '${amountToString2(aa.poolBalances.totalIronwood)} ZEC already in Ironwood',
                      style: TextStyle(color: ZipherColors.warm, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Gap(24),

        // Single-note privacy notice
        if (_orchardBalance > 0) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ZipherColors.warm.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ZipherColors.warm.withValues(alpha: 0.2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: ZipherColors.warm, size: 16),
                const Gap(10),
                Expanded(
                  child: Text(
                    'The amount crossing from Orchard to Ironwood is visible on-chain. '
                    'Tor hides your IP address from the server. '
                    'No names or addresses are revealed.',
                    style: TextStyle(color: ZipherColors.text60, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const Gap(16),
        ],

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
                ? ZipherColors.warm.withValues(alpha: 0.08)
                : ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _autoMode
                  ? ZipherColors.warm.withValues(alpha: 0.3)
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
                          ? _autoMigrationSubtitle()
                          : 'Resumes each time you open the app',
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
                activeTrackColor: ZipherColors.warm,
                thumbColor: WidgetStatePropertyAll(ZipherColors.textPrimary),
              ),
            ],
          ),
        ),
        const Gap(16),

        // Tor toggle
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _torEnabled
                ? ZipherColors.green.withValues(alpha: 0.08)
                : ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _torEnabled
                  ? ZipherColors.green.withValues(alpha: 0.3)
                  : ZipherColors.borderSubtle,
            ),
          ),
          child: Row(
            children: [
              Icon(
                _torEnabled ? Icons.vpn_lock_rounded : Icons.vpn_lock_outlined,
                color: _torEnabled ? ZipherColors.green : ZipherColors.text40,
                size: 20,
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Route through Tor',
                        style: TextStyle(
                          color: ZipherColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        )),
                    const Gap(2),
                    Text(
                      _torBootstrapping
                          ? 'Connecting to Tor network...'
                          : _torEnabled
                              ? _torVerifiedHeight != null
                                  ? 'Verified — block $_torVerifiedHeight via Tor'
                                  : 'Active — IP address hidden from server'
                              : 'Protects your IP during migration',
                      style: TextStyle(color: ZipherColors.text40, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (_torBootstrapping)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: ZipherColors.green,
                  ),
                )
              else
                Switch(
                  value: _torEnabled,
                  onChanged: _toggleTor,
                  activeTrackColor: ZipherColors.green,
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
              backgroundColor: ZipherColors.warm,
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
              color: ZipherColors.warm,
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
            color: ZipherColors.warm,
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
                      style: TextStyle(color: ZipherColors.warm)),
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
                    style: TextStyle(color: ZipherColors.warm)),
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
