import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../zipher_theme.dart';
import '../../accounts.dart';
import '../../services/app_log.dart';
import '../../services/wallet_service.dart';
import '../../services/ironwood_watch_service.dart';
import '../../src/rust/api/engine_api.dart' as engine;
import '../utils.dart';

final _log = createLogger();

class IronwoodPage extends StatefulWidget {
  const IronwoodPage({super.key});

  @override
  State<IronwoodPage> createState() => _IronwoodState();
}

enum _Phase { warning, planReview, ready, roundInProgress, success, error }

class _IronwoodState extends State<IronwoodPage> {
  static const _prefTor = 'ironwood_tor_enabled';

  _Phase _phase = _Phase.warning;
  String? _error;
  bool _autoMode = false;
  bool _torEnabled = false;
  bool _torBootstrapping = false;
  int? _torVerifiedHeight;
  engine.IronwoodSdkProgress? _sdkProgress;
  engine.IronwoodSdkPlan? _sdkPlan;

  int get _orchardBalance => aa.poolBalances.totalOrchard;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTor = prefs.getBool(_prefTor) ?? false;

    try {
      final progress = await IronwoodWatchService.instance.refreshStatus();
      _sdkProgress = progress;
      _log.i('[Ironwood/UI] status check: ${_fmtProgress(progress)}');
      if (progress.status == 'committed' || progress.status == 'in_progress') {
        _phase = _Phase.ready;
        _autoMode = true;
      }
    } catch (e) {
      _log.d('[Ironwood/UI] no active migration: $e');
    }

    if (IronwoodWatchService.instance.isRoundInProgress) {
      _phase = _Phase.roundInProgress;
    }

    if (mounted) setState(() {});

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

  /// Manually trigger the next SDK tick (prove + broadcast the next due tx).
  Future<void> _triggerTick() async {
    if (IronwoodWatchService.instance.isRoundInProgress) {
      _log.w('[Ironwood/UI] tick blocked — round already in progress');
      setState(() {
        _error = 'A migration round is already in progress. Please wait.';
        _phase = _Phase.error;
      });
      return;
    }

    _log.i('[Ironwood/UI] tick triggered by user');
    setState(() {
      _phase = _Phase.roundInProgress;
      _error = null;
    });

    IronwoodWatchService.instance.markRoundStarted();
    try {
      final seed = await WalletService.instance.getSeedPhrase();
      if (seed == null) throw Exception('Could not access wallet seed');
      _log.d('[Ironwood/UI] seed obtained, calling engineIronwoodSdkTick...');

      final result = await engine.engineIronwoodSdkTick(seedPhrase: seed);
      _sdkProgress = result;
      _log.i('[Ironwood/UI] tick result: ${_fmtProgress(result)}');

      if (result.status == 'complete') {
        setState(() => _phase = _Phase.success);
      } else {
        setState(() => _phase = _Phase.ready);
      }
    } catch (e) {
      _log.e('[Ironwood/UI] tick error: $e');
      final msg = e.toString();
      String userMessage;
      if (msg.contains('No transfer in progress')) {
        userMessage = 'No migration in progress. Start automatic migration first.';
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

  Future<void> _fetchPlan() async {
    _log.i('[Ironwood/UI] fetching migration plan...');
    setState(() {
      _phase = _Phase.roundInProgress;
      _error = null;
    });
    try {
      final plan = await IronwoodWatchService.instance.planMigration();
      _sdkPlan = plan;
      _log.i('[Ironwood/UI] plan: ${plan.transferTxCount} transfers, '
          '${plan.prepTxCount} prep (${plan.prepLayers} layers), '
          '${plan.totalTxCount} total, '
          'crossings=${plan.crossingValues.map((v) => v).toList()}');
      setState(() => _phase = _Phase.planReview);
    } catch (e) {
      _log.e('[Ironwood/UI] plan failed: $e');
      setState(() {
        _error = e.toString();
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _confirmAndCommit() async {
    _log.i('[Ironwood/UI] user confirmed plan, committing...');
    setState(() {
      _phase = _Phase.roundInProgress;
      _error = null;
    });
    try {
      final progress = await IronwoodWatchService.instance.commitMigration();
      _sdkProgress = progress;
      _log.i('[Ironwood/UI] commit OK: ${_fmtProgress(progress)}');
      setState(() {
        _autoMode = true;
        _phase = _Phase.ready;
      });
    } catch (e) {
      _log.e('[Ironwood/UI] commit failed: $e');
      setState(() {
        _error = e.toString();
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _stopAutoMigration() async {
    _log.i('[Ironwood/UI] cancelling migration');
    try {
      await IronwoodWatchService.instance.cancelMigration();
    } catch (e) {
      _log.w('[Ironwood/UI] cancel error: $e');
    }
    setState(() {
      _autoMode = false;
      _sdkProgress = null;
    });
  }

  String _autoMigrationSubtitle() {
    final p = _sdkProgress ?? IronwoodWatchService.instance.progress;
    if (p == null) return 'Starting...';

    if (p.status == 'complete') return 'Complete — all funds in Ironwood';

    final confirmed = p.confirmedCount;
    final total = p.totalTxCount;
    final broadcast = p.broadcastCount;

    if (broadcast > confirmed) {
      return '$confirmed/$total confirmed ($broadcast broadcast)';
    }
    return '$confirmed/$total transactions confirmed';
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
      case _Phase.planReview:
        return _buildPlanReviewView();
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

  Widget _buildPlanReviewView() {
    final plan = _sdkPlan;
    if (plan == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final zec = BigInt.from(100000000);
    final totalZec = plan.totalMigratingZat ~/ zec;
    final totalFrac = (plan.totalMigratingZat % zec).toString().padLeft(8, '0');
    final feeZec = plan.estimatedTotalFeeZat ~/ zec;
    final feeFrac = (plan.estimatedTotalFeeZat % zec).toString().padLeft(8, '0');

    return ListView(
      children: [
        const Gap(24),
        Icon(Icons.account_tree_outlined, color: ZipherColors.warm, size: 48),
        const Gap(16),
        Text(
          'Migration Plan',
          style: TextStyle(
            color: ZipherColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const Gap(8),
        Text(
          'The SDK will split your balance into standard denominations '
          'and migrate each one separately.',
          style: TextStyle(color: ZipherColors.text60, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const Gap(24),

        // Denomination breakdown
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZipherColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Crossing Denominations',
                  style: TextStyle(
                    color: ZipherColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  )),
              const Gap(12),
              ...plan.crossingValues.map((v) {
                final whole = v ~/ zec;
                final frac = (v % zec).toString().padLeft(8, '0');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(Icons.arrow_forward_rounded,
                          size: 14, color: ZipherColors.warm),
                      const Gap(8),
                      Text(
                        '$whole.$frac ZEC',
                        style: TextStyle(
                          color: ZipherColors.textPrimary,
                          fontSize: 14,
                          fontFamily: 'JetBrains Mono',
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        const Gap(16),

        // Summary stats
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZipherColors.borderSubtle),
          ),
          child: Column(
            children: [
              _planRow('Total migrating', '$totalZec.$totalFrac ZEC'),
              const Gap(8),
              _planRow('Estimated fees', '$feeZec.$feeFrac ZEC'),
              const Gap(8),
              _planRow('Preparation txs', '${plan.prepTxCount} (${plan.prepLayers} layers)'),
              _planRow('Transfer txs', '${plan.transferTxCount}'),
              const Gap(8),
              Divider(color: ZipherColors.borderSubtle),
              const Gap(4),
              _planRow('Total transactions', '${plan.totalTxCount}'),
            ],
          ),
        ),
        const Gap(12),

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
              Icon(Icons.schedule_rounded, color: ZipherColors.warm, size: 16),
              const Gap(10),
              Expanded(
                child: Text(
                  'Each transaction will be broadcast as its scheduled block '
                  'height arrives. The process runs automatically once started.',
                  style: TextStyle(color: ZipherColors.text60, fontSize: 12, height: 1.4),
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
            onPressed: _confirmAndCommit,
            style: ElevatedButton.styleFrom(
              backgroundColor: ZipherColors.warm,
              foregroundColor: ZipherColors.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Start Migration',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const Gap(12),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _phase = _Phase.ready),
            child: Text('Cancel', style: TextStyle(color: ZipherColors.text40)),
          ),
        ),
        const Gap(40),
      ],
    );
  }

  Widget _planRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
        Text(value, style: TextStyle(
          color: ZipherColors.textPrimary,
          fontSize: 13,
          fontFamily: 'JetBrains Mono',
        )),
      ],
    );
  }

  Widget _buildReadyView() {
    final orchard = _orchardBalance;
    final p = _sdkProgress;
    final hasActiveMigration = p != null &&
        (p.status == 'committed' || p.status == 'in_progress') &&
        p.status != 'complete';

    if (orchard == 0 && !hasActiveMigration) {
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

    if (orchard == 0 && hasActiveMigration) {
      return _buildStuckMigrationView(p);
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

        // ZIP-318 compliance badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: ZipherColors.green.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ZipherColors.green.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified_outlined, color: ZipherColors.green, size: 16),
              const Gap(6),
              Text(
                'ZIP-318 Compliant',
                style: TextStyle(
                  color: ZipherColors.green,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const Gap(16),

        // How it works
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
          'The SDK decomposes your balance into standard denominations '
          '(1-2-5 series), selects boundary-aligned anchors shared with '
          'other wallets, and builds unpadded Ironwood bundles. Each '
          'transaction is pre-signed and broadcast as its scheduled block '
          'height arrives.',
          style: TextStyle(color: ZipherColors.text60, fontSize: 13),
        ),
        const Gap(24),

        // Migration toggle
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
                    Text(_autoMode ? 'Migration Active' : 'Start Migration',
                        style: TextStyle(
                          color: ZipherColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        )),
                    const Gap(2),
                    Text(
                      _autoMode
                          ? _autoMigrationSubtitle()
                          : 'Plans, signs, and broadcasts automatically',
                      style: TextStyle(color: ZipherColors.text40, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _autoMode,
                onChanged: (v) {
                  if (v) {
                    _fetchPlan();
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

        // Process next (only when migration is active)
        if (_autoMode) ...[
          Builder(builder: (_) {
            final p = _sdkProgress;
            final hasPendingBroadcast = p != null && p.broadcastCount > p.confirmedCount;
            return Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: hasPendingBroadcast ? null : _triggerTick,
                    icon: Icon(
                      hasPendingBroadcast ? Icons.hourglass_top_rounded : Icons.fast_forward_rounded,
                      size: 18,
                    ),
                    label: Text(
                      hasPendingBroadcast
                          ? 'Waiting for Confirmation...'
                          : 'Process Next Transaction',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: hasPendingBroadcast
                          ? ZipherColors.text10.withValues(alpha: 0.08)
                          : ZipherColors.warm.withValues(alpha: 0.12),
                      foregroundColor: hasPendingBroadcast
                          ? ZipherColors.text40
                          : ZipherColors.warm,
                      disabledBackgroundColor: ZipherColors.text10.withValues(alpha: 0.08),
                      disabledForegroundColor: ZipherColors.text40,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
                const Gap(8),
                Center(
                  child: Text(
                    hasPendingBroadcast
                        ? 'Previous transaction must confirm before the next can be proved'
                        : 'Prove and broadcast the next due transaction now',
                    style: TextStyle(color: ZipherColors.text40, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            );
          }),
        ],
        const Gap(32),
      ],
    );
  }

  Widget _buildStuckMigrationView(engine.IronwoodSdkProgress p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, color: ZipherColors.warm, size: 56),
            const Gap(16),
            Text(
              'Migration Stuck',
              style: TextStyle(
                color: ZipherColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Gap(12),
            Text(
              'A previous migration has ${p.broadcastCount} broadcast transactions '
              'that were never confirmed. They likely expired before being mined.',
              style: TextStyle(color: ZipherColors.text60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const Gap(8),
            Text(
              '${p.confirmedCount}/${p.totalTxCount} confirmed',
              style: TextStyle(
                color: ZipherColors.textPrimary,
                fontSize: 14,
                fontFamily: 'JetBrains Mono',
              ),
            ),
            const Gap(24),
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
                      'Cancelling clears the stale state. No funds are lost — '
                      'expired transactions are automatically returned to your wallet. '
                      'You can start a fresh migration afterwards.',
                      style: TextStyle(color: ZipherColors.text60, fontSize: 12, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const Gap(24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () async {
                  await _stopAutoMigration();
                  setState(() => _phase = _Phase.ready);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZipherColors.warm,
                  foregroundColor: ZipherColors.bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Cancel Stale Migration',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const Gap(12),
            Center(
              child: TextButton(
                onPressed: () => context.pop(),
                child: Text('Back', style: TextStyle(color: ZipherColors.text40)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressView() {
    final p = _sdkProgress;
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
            'Processing Migration',
            style: TextStyle(color: ZipherColors.textPrimary, fontSize: 16),
          ),
          const Gap(8),
          Text(
            'Generating ZK proof and broadcasting...',
            style: TextStyle(color: ZipherColors.text40, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          if (p != null) ...[
            const Gap(12),
            Text(
              '${p.confirmedCount}/${p.totalTxCount} confirmed',
              style: TextStyle(
                color: ZipherColors.textPrimary,
                fontSize: 14,
                fontFamily: 'JetBrains Mono',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    final p = _sdkProgress;
    final isDone = _orchardBalance == 0 || (p != null && p.status == 'complete');
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
            isDone ? 'Migration Complete' : 'Migration In Progress',
            style: TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(12),
          if (p != null) ...[
            Text(
              '${p.confirmedCount}/${p.totalTxCount} transactions confirmed',
              style: TextStyle(color: ZipherColors.text60, fontSize: 14),
            ),
            if (p.totalPlannedZat > BigInt.zero) ...[
              const Gap(4),
              Text(
                '${amountToString2(p.totalPlannedZat.toInt())} ZEC planned',
                style: TextStyle(color: ZipherColors.text40, fontSize: 12),
              ),
            ],
          ],
          if (!isDone && _orchardBalance > 0) ...[
            const Gap(8),
            Text(
              'Remaining in Orchard: ${amountToString2(_orchardBalance)} ZEC',
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
                    });
                  },
                  child: Text('Back',
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

  static String _fmtProgress(engine.IronwoodSdkProgress p) {
    final zec = BigInt.from(100000000);
    final crossings = p.crossingValues.map((v) => '${v ~/ zec}.${(v % zec).toString().padLeft(8, '0')}').join(', ');
    return 'status=${p.status} '
        'txs=${p.confirmedCount}/${p.totalTxCount} '
        'broadcast=${p.broadcastCount} '
        'planned=${p.totalPlannedZat ~/ zec}.${(p.totalPlannedZat % zec).toString().padLeft(8, '0')}ZEC '
        'confirmed=${p.totalConfirmedZat ~/ zec}.${(p.totalConfirmedZat % zec).toString().padLeft(8, '0')}ZEC '
        'nextDueH=${p.nextDueHeight} '
        'fees=${p.feesPaidZat}zat '
        'crossings=[$crossings]';
  }
}
