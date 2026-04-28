import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:screen_protector/screen_protector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_registry.dart';
import '../../services/secure_key_store.dart';
import '../../zipher_theme.dart';
import '../../generated/intl/messages.dart';

class BackupPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _BackupState();
}

class _BackupState extends State<BackupPage> with WidgetsBindingObserver {
  bool _showSpendingKeys = false;
  bool _seedWordsVisible = false;
  bool _skRevealed = false;
  bool _tskRevealed = false;
  bool _obscured = false;
  int? _birthdayHeight;
  bool _verificationPassed = false;

  _Backup? _backup;
  String? _loadError;
  List<WalletProfile> _allWallets = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enableScreenProtection();
    _loadBackup();
    _loadBirthday();
    _loadVerificationState();
    _loadAllWallets();
  }

  Future<void> _loadAllWallets() async {
    final wallets = await WalletRegistry.instance.getAll();
    if (mounted) setState(() => _allWallets = wallets);
  }

  Future<void> _loadVerificationState() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'seed_verified_${aa.coin}_${aa.id}';
    final v = prefs.getBool(key) ?? false;
    if (v && mounted) setState(() => _verificationPassed = true);
  }

  Future<void> _saveVerificationState(bool passed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('seed_verified_${aa.coin}_${aa.id}', passed);
  }

  Future<void> _enableScreenProtection() async {
    await ScreenProtector.protectDataLeakageOn();
  }

  Future<void> _disableScreenProtection() async {
    await ScreenProtector.protectDataLeakageOff();
  }

  String? _keychainSeed;

  bool _testnetSeedMissing = false;

  void _loadBackup() async {
    try {
      final ws = WalletService.instance;
      final walletSeed = aa.walletId.isNotEmpty
          ? await SecureKeyStore.getSeedForWallet(
              isTestnet ? '${aa.walletId}_testnet' : aa.walletId)
          : null;
      final kcSeed = walletSeed ?? await SecureKeyStore.getSeed(aa.coin, aa.id);
      String? uvk;
      String? seed;
      try {
        uvk = await ws.exportUfvk();
        if (kcSeed == null) seed = await ws.getSeedPhrase();
      } catch (_) {}
      final hasKey = kcSeed != null || seed != null || uvk != null;
      if (!hasKey) {
        setState(() => _loadError = 'Account has no key');
        return;
      }
      if (!mounted) return;
      final hasSeed = kcSeed != null || seed != null;
      setState(() {
        _testnetSeedMissing = isTestnet && !hasSeed;
        _backup = _Backup(
          name: aa.name,
          index: aa.id,
          seed: kcSeed ?? seed,
          sk: null,
          tsk: null,
          uvk: uvk,
          fvk: null,
          saved: false,
        );
        _keychainSeed = kcSeed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = 'Could not load backup: $e');
    }
  }

  void _loadBirthday() async {
    final prefs = await SharedPreferences.getInstance();
    final h = prefs.getInt('birthday_${aa.coin}_${aa.id}');
    if (h != null && mounted) {
      setState(() => _birthdayHeight = h);
    }
  }

  @override
  void dispose() {
    _disableScreenProtection();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      setState(() => _obscured = true);
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _obscured = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    if (_loadError != null) {
      return Scaffold(
        backgroundColor: ZipherColors.bg,
        appBar: AppBar(
          backgroundColor: ZipherColors.bg,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
            onPressed: () => GoRouter.of(context).pop(),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 40,
                    color: ZipherColors.orange.withValues(alpha: 0.7)),
                const Gap(16),
                Text(
                  _loadError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text40,
                    height: 1.4,
                  ),
                ),
                const Gap(20),
                GestureDetector(
                  onTap: _loadBackup,
                  child: Text(
                    'Tap to retry',
                    style: TextStyle(
                      fontSize: 13,
                      color: ZipherColors.cyan.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_backup == null) {
      return Scaffold(
        backgroundColor: ZipherColors.bg,
        body: Center(
          child: CircularProgressIndicator(
            color: ZipherColors.cyan,
            strokeWidth: 2,
          ),
        ),
      );
    }

    final backup = _backup!;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'BACKUP',
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
      ),
      body: _obscured
          ? Container(
              color: ZipherColors.bg,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield_rounded,
                        size: 48, color: ZipherColors.cardBgElevated),
                    const Gap(16),
                    Text(
                      'Content hidden for security',
                      style: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text40,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Warning banner
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ZipherColors.orange.withValues(alpha: 0.08),
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.lg),
                      border: Border.all(
                        color:
                            ZipherColors.orange.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 18,
                            color: ZipherColors.orange
                                .withValues(alpha: 0.7)),
                        const Gap(10),
                        Expanded(
                          child: Text(
                            'Never share your seed phrase or spending keys. Anyone with access can steal your funds.',
                            style: TextStyle(
                              fontSize: 12,
                              color: ZipherColors.orange
                                  .withValues(alpha: 0.9),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (isTestnet) ...[
                    const Gap(12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color:
                            ZipherColors.orange.withValues(alpha: 0.06),
                        borderRadius:
                            BorderRadius.circular(ZipherRadius.lg),
                        border: Border.all(
                          color: ZipherColors.orange
                              .withValues(alpha: 0.12),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.science_rounded,
                              size: 18,
                              color: ZipherColors.orange
                                  .withValues(alpha: 0.7)),
                          const Gap(10),
                          Expanded(
                            child: Text(
                              'You are viewing a testnet wallet. This seed is independent from your mainnet seed. Testnet coins (TAZ) have no real value.',
                              style: TextStyle(
                                fontSize: 12,
                                color: ZipherColors.orange
                                    .withValues(alpha: 0.8),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const Gap(20),

                  // Wallet info card
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.lg),
                      border:
                          Border.all(color: ZipherColors.borderSubtle),
                    ),
                    child: Column(
                      children: [
                        _infoRow(
                          Icons.account_circle_outlined,
                          'Account',
                          '${backup.name ?? 'Unknown'} (#${backup.index})',
                        ),
                        _divider(),
                        _infoRow(
                          Icons.backup_rounded,
                          'Backup saved',
                          backup.saved ? 'Yes' : 'No',
                          valueColor: backup.saved
                              ? ZipherColors.green
                                  .withValues(alpha: 0.6)
                              : ZipherColors.orange
                                  .withValues(alpha: 0.9),
                        ),
                        if (_birthdayHeight != null) ...[
                          _divider(),
                          _infoRow(
                            Icons.cake_outlined,
                            'Birthday',
                            'Block $_birthdayHeight',
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Seed coverage
                  if (_allWallets.length > 1) ...[
                    const Gap(20),
                    _sectionHeader(
                      'Seed Coverage',
                      'Which accounts each seed phrase covers',
                      Icons.account_tree_rounded,
                    ),
                    const Gap(12),
                    ..._allWallets.map((w) {
                      final isCurrent = w.id == aa.walletId;
                      final accountNames = w.visibleAccounts
                          .map((a) => a.name)
                          .join(', ');
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? ZipherColors.cyan
                                    .withValues(alpha: 0.04)
                                : ZipherColors.cardBg,
                            borderRadius: BorderRadius.circular(
                                ZipherRadius.lg),
                            border: Border.all(
                              color: isCurrent
                                  ? ZipherColors.cyan
                                      .withValues(alpha: 0.12)
                                  : ZipherColors.borderSubtle,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.key_rounded,
                                size: 14,
                                color: isCurrent
                                    ? ZipherColors.cyan
                                        .withValues(alpha: 0.6)
                                    : ZipherColors.text20,
                              ),
                              const Gap(10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          w.name,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color:
                                                ZipherColors.text60,
                                          ),
                                        ),
                                        if (isCurrent) ...[
                                          const Gap(6),
                                          Container(
                                            padding: const EdgeInsets
                                                .symmetric(
                                                horizontal: 5,
                                                vertical: 1),
                                            decoration: BoxDecoration(
                                              color: ZipherColors.cyan
                                                  .withValues(
                                                      alpha: 0.08),
                                              borderRadius:
                                                  BorderRadius
                                                      .circular(4),
                                            ),
                                            child: Text(
                                              'viewing',
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight:
                                                    FontWeight.w600,
                                                color: ZipherColors
                                                    .cyan
                                                    .withValues(
                                                        alpha: 0.7),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const Gap(2),
                                    Text(
                                      'Covers: $accountNames',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: ZipherColors.text40,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],

                  const Gap(24),

                  // Viewing keys
                  _sectionHeader(
                    'Viewing Keys',
                    'Read-only access \u2014 safe to share for auditing',
                    Icons.visibility_rounded,
                  ),
                  const Gap(12),

                  if (backup.uvk != null)
                    _KeyCard(
                      label: 'Unified Viewing Key',
                      description:
                          'Can view all transactions across all pools. Cannot spend funds.',
                      value: backup.uvk!,
                      icon: Icons.visibility_rounded,
                      alwaysVisible: true,
                      onShowQR: () => _showQR(context, backup.uvk!,
                          '${s.unifiedViewingKey} of ${backup.name}'),
                    ),

                  if (backup.fvk != null) ...[
                    const Gap(12),
                    _KeyCard(
                      label: 'Full Viewing Key',
                      description:
                          'Can view shielded (Sapling) transactions only. Cannot spend.',
                      value: backup.fvk!,
                      icon: Icons.visibility_outlined,
                      alwaysVisible: true,
                      onShowQR: () => _showQR(context, backup.fvk!,
                          '${s.viewingKey} of ${backup.name}'),
                    ),
                  ],

                  if (_testnetSeedMissing) ...[
                    const Gap(20),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: ZipherColors.cardBg,
                        borderRadius:
                            BorderRadius.circular(ZipherRadius.lg),
                        border: Border.all(
                            color: ZipherColors.borderSubtle),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 18, color: ZipherColors.text40),
                          const Gap(10),
                          Expanded(
                            child: Text(
                              'This testnet wallet was created before seed storage was enabled. '
                              'Toggle testnet off and back on to recreate it with a stored seed.',
                              style: TextStyle(
                                fontSize: 12,
                                color: ZipherColors.text40,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const Gap(28),

                  // Spending keys
                  if (_hasSpendingKeys(backup)) ...[
                    GestureDetector(
                      onTap: () => setState(
                          () => _showSpendingKeys = !_showSpendingKeys),
                      child: _sectionHeader(
                        'Spending Keys',
                        'Full control \u2014 never share these',
                        Icons.lock_rounded,
                        trailing: Icon(
                          _showSpendingKeys
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: ZipherColors.text20,
                        ),
                      ),
                    ),

                    if (_showSpendingKeys) ...[
                      const Gap(12),

                      if (backup.tsk != null)
                        _KeyCard(
                          label: 'Transparent Key',
                          description:
                              'Can spend transparent (public) funds only.',
                          value: backup.tsk!,
                          icon: Icons.key_rounded,
                          revealed: _tskRevealed,
                          onToggleReveal: () => setState(
                              () => _tskRevealed = !_tskRevealed),
                          onShowQR: () => _showQR(
                              context,
                              backup.tsk!,
                              '${s.transparentKey} of ${backup.name}'),
                        ),

                      if (backup.sk != null) ...[
                        const Gap(12),
                        _KeyCard(
                          label: 'Secret Key',
                          description:
                              'Can spend all shielded funds in this account.',
                          value: backup.sk!,
                          icon: Icons.vpn_key_rounded,
                          revealed: _skRevealed,
                          onToggleReveal: () => setState(
                              () => _skRevealed = !_skRevealed),
                          onShowQR: () => _showQR(
                              context,
                              backup.sk!,
                              '${s.secretKey} of ${backup.name}'),
                        ),
                      ],

                      // Seed phrase
                      if ((_keychainSeed ?? backup.seed) != null) ...[
                        const Gap(12),
                        Builder(builder: (ctx) {
                          final seedValue =
                              _keychainSeed ?? backup.seed!;
                          final seedLabel = isTestnet
                              ? 'Testnet Seed Phrase'
                              : 'Seed Phrase';
                          final seedDesc = isTestnet
                              ? 'Testnet-only seed \u2014 independent from your mainnet seed. Testnet coins have no value.'
                              : 'Master key \u2014 derives ALL accounts and keys. If lost, funds are unrecoverable. If stolen, everything is compromised.';
                          if (!_backup!.saved) {
                            setActiveAccount(aa.coin, aa.id);
                          }
                          return _SeedCard(
                            label: seedLabel,
                            description: seedDesc,
                            seedPhrase: backup.index != 0
                                ? '$seedValue [${backup.index}]'
                                : seedValue,
                            wordsVisible: _seedWordsVisible,
                            onToggleWords: () => setState(() =>
                                _seedWordsVisible =
                                    !_seedWordsVisible),
                            onShowQR: () => _showQR(
                                context,
                                seedValue,
                                '${s.seed} of ${backup.name}'),
                          );
                        }),

                        if (!_verificationPassed) ...[
                          const Gap(16),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _startVerification(
                                  (_keychainSeed ?? backup.seed)!),
                              borderRadius: BorderRadius.circular(
                                  ZipherRadius.lg),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 14),
                                decoration: BoxDecoration(
                                  color: ZipherColors.cyan
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(
                                      ZipherRadius.lg),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.quiz_rounded,
                                        size: 18,
                                        color: ZipherColors.cyan
                                            .withValues(alpha: 0.9)),
                                    const Gap(8),
                                    Text(
                                      'Verify Backup',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: ZipherColors.cyan
                                            .withValues(alpha: 0.9),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],

                        // Verified badge
                        if (_verificationPassed) ...[
                          const Gap(16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                vertical: 14),
                            decoration: BoxDecoration(
                              color: ZipherColors.green
                                  .withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(
                                  ZipherRadius.lg),
                              border: Border.all(
                                color: ZipherColors.green
                                    .withValues(alpha: 0.15),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                                Icon(Icons.check_circle_rounded,
                                    size: 18,
                                    color: ZipherColors.green
                                        .withValues(alpha: 0.7)),
                                const Gap(8),
                                Text(
                                  'Backup Verified',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: ZipherColors.green
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ],

                  const Gap(40),
                ],
              ),
            ),
    );
  }

  void _startVerification(String seed) {
    final words = seed.trim().split(RegExp(r'\s+'));
    if (words.length < 6) return;

    final rng = math.Random();
    final indices = <int>{};
    while (indices.length < 3) {
      indices.add(rng.nextInt(words.length));
    }
    final sortedIndices = indices.toList()..sort();

    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _SeedVerificationPage(
          words: words,
          indices: sortedIndices,
          onResult: (passed) {
            if (passed == null) return;
            if (passed) {
              setState(() => _verificationPassed = true);
              _saveVerificationState(true);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Backup verified successfully!'),
                  backgroundColor:
                      ZipherColors.green.withValues(alpha: 0.8),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.md)),
                  duration: const Duration(seconds: 2),
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text(
                      'Incorrect words. Please check your seed phrase and try again.'),
                  backgroundColor:
                      ZipherColors.red.withValues(alpha: 0.8),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.md)),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  bool _hasSpendingKeys(_Backup b) =>
      _keychainSeed != null ||
      b.seed != null ||
      b.sk != null ||
      b.tsk != null;

  Widget _sectionHeader(String title, String subtitle, IconData icon,
      {Widget? trailing}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: ZipherColors.text40),
        const Gap(8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ZipherColors.text60,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text40,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _infoRow(IconData icon, String label, String value,
      {Color? valueColor}) {
    return Row(
      children: [
        Icon(icon, size: 15, color: ZipherColors.text20),
        const Gap(8),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: ZipherColors.text40),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: valueColor ?? ZipherColors.text60,
          ),
        ),
      ],
    );
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 1, color: ZipherColors.borderSubtle),
    );
  }

  void _showQR(BuildContext context, String value, String title) {
    GoRouter.of(context).push('/showqr?title=$title', extra: value);
  }
}

/// Local backup type.
class _Backup {
  final String? name;
  final int index;
  final String? seed;
  final String? sk;
  final String? tsk;
  final String? uvk;
  final String? fvk;
  final bool saved;
  _Backup({
    this.name,
    required this.index,
    this.seed,
    this.sk,
    this.tsk,
    this.uvk,
    this.fvk,
    required this.saved,
  });
}

// ─── Key card (viewing keys, spending keys) ─────────────────────────

class _KeyCard extends StatelessWidget {
  final String label;
  final String description;
  final String value;
  final IconData icon;
  final bool alwaysVisible;
  final bool revealed;
  final VoidCallback? onToggleReveal;
  final VoidCallback? onShowQR;

  const _KeyCard({
    required this.label,
    required this.description,
    required this.value,
    required this.icon,
    this.alwaysVisible = false,
    this.revealed = false,
    this.onToggleReveal,
    this.onShowQR,
  });

  bool get _isVisible => alwaysVisible || revealed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: ZipherColors.text20),
              const Gap(6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.text60,
                  ),
                ),
              ),
              if (alwaysVisible)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: ZipherColors.cyan.withValues(alpha: 0.08),
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.xs),
                  ),
                  child: Text(
                    'READ-ONLY',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: ZipherColors.cyan.withValues(alpha: 0.6),
                    ),
                  ),
                ),
            ],
          ),
          const Gap(6),
          Text(
            description,
            style: TextStyle(
              fontSize: 11,
              color: ZipherColors.text40,
              height: 1.4,
            ),
          ),
          const Gap(10),
          _isVisible
              ? SelectableText(
                  value,
                  style: TextStyle(
                    fontSize: 12,
                    color: ZipherColors.text60,
                    height: 1.5,
                    fontFamily: 'JetBrainsMono',
                  ),
                )
              : GestureDetector(
                  onTap: onToggleReveal,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBgElevated,
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.md),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.visibility_off_rounded,
                            size: 18, color: ZipherColors.text10),
                        const Gap(4),
                        Text(
                          'Tap to reveal',
                          style: TextStyle(
                            fontSize: 11,
                            color: ZipherColors.text40,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          if (_isVisible) ...[
            const Gap(10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _actionButton(
                  Icons.copy_rounded,
                  'Copy',
                  () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Copied to clipboard'),
                        duration: const Duration(seconds: 1),
                        backgroundColor: ZipherColors.surface,
                      ),
                    );
                  },
                ),
                const Gap(8),
                _actionButton(Icons.qr_code_rounded, 'QR', onShowQR),
                if (!alwaysVisible && onToggleReveal != null) ...[
                  const Gap(8),
                  _actionButton(
                      Icons.visibility_off_rounded, 'Hide', onToggleReveal),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionButton(
      IconData icon, String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: ZipherColors.text20),
            const Gap(4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: ZipherColors.text40,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Seed card with per-word grid ───────────────────────────────────

class _SeedCard extends StatelessWidget {
  final String label;
  final String description;
  final String seedPhrase;
  final bool wordsVisible;
  final VoidCallback? onToggleWords;
  final VoidCallback? onShowQR;

  const _SeedCard({
    required this.label,
    required this.description,
    required this.seedPhrase,
    required this.wordsVisible,
    this.onToggleWords,
    this.onShowQR,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_rounded,
                  size: 14, color: ZipherColors.text20),
              const Gap(6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.text60,
                  ),
                ),
              ),
            ],
          ),
          const Gap(6),
          Text(
            description,
            style: TextStyle(
              fontSize: 11,
              color: ZipherColors.text40,
              height: 1.4,
            ),
          ),
          const Gap(10),
          Row(
            children: [
              GestureDetector(
                onTap: onToggleWords,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      wordsVisible
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 13,
                      color: ZipherColors.text20,
                    ),
                    const Gap(4),
                    Text(
                      wordsVisible ? 'Hide words' : 'Show words',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: ZipherColors.text40,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Gap(8),
          _buildWordGrid(),
          const Gap(10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _actionButton(
                context,
                Icons.copy_rounded,
                'Copy',
                () {
                  final clean = seedPhrase.replaceAll(
                      RegExp(r'\s*\[\d+\]\s*$'), '');
                  Clipboard.setData(ClipboardData(text: clean));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Seed phrase copied'),
                      duration: const Duration(seconds: 1),
                      backgroundColor: ZipherColors.surface,
                    ),
                  );
                },
              ),
              const Gap(8),
              _actionButton(
                  context, Icons.qr_code_rounded, 'QR', onShowQR),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWordGrid() {
    // Parse seed words, strip optional account index suffix like " [1]"
    final cleanSeed =
        seedPhrase.replaceAll(RegExp(r'\s*\[\d+\]\s*$'), '');
    final words = cleanSeed.trim().split(RegExp(r'\s+'));
    final rows = (words.length / 3).ceil();

    return Column(
      children: List.generate(rows, (row) {
        return Padding(
          padding: EdgeInsets.only(bottom: row < rows - 1 ? 6 : 0),
          child: Row(
            children: List.generate(3, (col) {
              final idx = row * 3 + col;
              if (idx >= words.length) {
                return const Expanded(child: SizedBox());
              }
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: col > 0 ? 4 : 0,
                    right: col < 2 ? 0 : 0,
                  ),
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBgElevated,
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.sm),
                      border: Border.all(
                          color: ZipherColors.borderSubtle),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          child: Text(
                            '${idx + 1}',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: ZipherColors.text20,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            wordsVisible ? words[idx] : '\u2022\u2022\u2022\u2022',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: wordsVisible
                                  ? ZipherColors.text90
                                  : ZipherColors.text20,
                              fontFamily: 'JetBrainsMono',
                              letterSpacing:
                                  wordsVisible ? 0 : 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        );
      }),
    );
  }

  Widget _actionButton(BuildContext context, IconData icon,
      String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: ZipherColors.text20),
            const Gap(4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: ZipherColors.text40,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Seed verification page ─────────────────────────────────────────

class _SeedVerificationPage extends StatefulWidget {
  final List<String> words;
  final List<int> indices;
  final void Function(bool? passed) onResult;

  const _SeedVerificationPage({
    required this.words,
    required this.indices,
    required this.onResult,
  });

  @override
  State<_SeedVerificationPage> createState() => _SeedVerificationState();
}

class _SeedVerificationState extends State<_SeedVerificationPage> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(3, (_) => TextEditingController());
    _focusNodes = List.generate(3, (_) => FocusNode());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNodes[0].requestFocus();
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _verify() {
    bool allCorrect = true;
    for (int i = 0; i < 3; i++) {
      if (_controllers[i].text.trim().toLowerCase() !=
          widget.words[widget.indices[i]].toLowerCase()) {
        allCorrect = false;
        break;
      }
    }
    Navigator.of(context).pop();
    widget.onResult(allCorrect);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        leading: IconButton(
          icon:
              Icon(Icons.close_rounded, color: ZipherColors.text60),
          onPressed: () {
            Navigator.of(context).pop();
            widget.onResult(null);
          },
        ),
        title: Text(
          'VERIFY BACKUP',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Icon(Icons.quiz_rounded,
                  size: 48,
                  color: ZipherColors.cyan.withValues(alpha: 0.5)),
              const Gap(20),
              Text(
                'Verify Your Seed',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: ZipherColors.text90,
                ),
              ),
              const Gap(10),
              Text(
                'Enter the requested words to confirm\nyou saved your seed phrase correctly.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: ZipherColors.text40,
                  height: 1.6,
                ),
              ),
              const Gap(40),
              for (int i = 0; i < 3; i++) ...[
                if (i > 0) const Gap(14),
                Container(
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBg,
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.lg),
                    border:
                        Border.all(color: ZipherColors.borderSubtle),
                  ),
                  child: TextField(
                    controller: _controllers[i],
                    focusNode: _focusNodes[i],
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: i < 2
                        ? TextInputAction.next
                        : TextInputAction.done,
                    onSubmitted: (_) {
                      if (i < 2) {
                        _focusNodes[i + 1].requestFocus();
                      } else {
                        _verify();
                      }
                    },
                    style: TextStyle(
                      fontSize: 16,
                      color: ZipherColors.text90,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Word #${widget.indices[i] + 1}',
                      labelStyle: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text40,
                      ),
                      filled: false,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                    ),
                  ),
                ),
              ],
              const Spacer(flex: 3),
              SizedBox(
                width: double.infinity,
                child: ZipherWidgets.gradientButton(
                  label: 'Verify',
                  onPressed: _verify,
                ),
              ),
              const Gap(16),
            ],
          ),
        ),
      ),
    );
  }
}
