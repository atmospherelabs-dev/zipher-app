import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../services/backup_status.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:screen_protector/screen_protector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils.dart';
import '../sensitive_qr.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_registry.dart';
import '../../services/secure_key_store.dart';
import '../../zipher_theme.dart';
import '../../generated/intl/messages.dart';

/// How long sensitive material stays in the clipboard after a Copy action.
/// Other apps (and clipboard managers) can read the system clipboard, so
/// secrets shouldn't linger there. 60s is enough for a normal "switch to
/// a password manager and paste" flow without being permanent.
const _kClipboardAutoClearDuration = Duration(seconds: 60);

/// Copy a sensitive value to the clipboard and auto-clear it after
/// [_kClipboardAutoClearDuration]. Snackbar is explicit about the
/// auto-clear so users know what to expect. Audit finding H2 (2026-05-18).
void _copyWithAutoClear(BuildContext context, String value,
    {String label = 'Copied'}) {
  Clipboard.setData(ClipboardData(text: value));
  final seconds = _kClipboardAutoClearDuration.inSeconds;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied — clipboard auto-clears in ${seconds}s'),
        duration: const Duration(seconds: 2),
        backgroundColor: ZipherColors.surface,
      ),
    );
  }
  // Schedule clear. If the user copies something else in the meantime,
  // we still overwrite back to empty after the timer fires; clipboard
  // managers may still have the value, but the live system clipboard
  // is cleared. Defense-in-depth, not a guarantee.
  Timer(_kClipboardAutoClearDuration, () async {
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // Best-effort; nothing actionable on failure.
    }
  });
}

/// Recovery phrase (default) or, with [advanced], viewing and spending keys
/// plus which wallets are backed up. Both share the same reveal protections.
class BackupPage extends StatefulWidget {
  BackupPage({super.key, this.advanced = false});

  final bool advanced;

  @override
  State<StatefulWidget> createState() => _BackupState();
}

class _BackupState extends State<BackupPage> with WidgetsBindingObserver {
  bool _seedWordsVisible = false;
  bool _skRevealed = false;
  bool _tskRevealed = false;
  bool _uvkRevealed = false;
  bool _fvkRevealed = false;
  bool _obscured = false;
  final String? _sourceWalletId = WalletService.instance.activeWalletId;
  final bool _sourceNetwork = isTestnet;
  int _revealEpoch = 0;
  bool _authorizingReveal = false;
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

  /// Which wallets have passed the backup check (advanced view).
  Map<String, bool> _walletBackedUp = {};

  Future<void> _loadAllWallets() async {
    final wallets = await WalletRegistry.instance.getAll();
    final backedUp = {
      for (final w in wallets) w.id: await BackupStatus.isBackedUp(w.id),
    };
    if (mounted) {
      setState(() {
        _allWallets = wallets;
        _walletBackedUp = backedUp;
      });
    }
  }

  Future<void> _loadVerificationState() async {
    final v =
        await BackupStatus.isBackedUp(WalletService.instance.activeWalletId);
    if (v && mounted) setState(() => _verificationPassed = true);
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
      setState(() {
        _obscured = true;
        _seedWordsVisible = false;
        _skRevealed = false;
        _tskRevealed = false;
        _uvkRevealed = false;
        _fvkRevealed = false;
      });
      if (state == AppLifecycleState.paused) {
        _revealEpoch++;
        final route = ModalRoute.of(context);
        if (route != null) Navigator.of(context).popUntil((r) => r == route);
      }
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
            icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: ZipherColors.text90),
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
                ZipherButton(
                  label: 'Tap to retry',
                  kind: ZipherButtonKind.plain,
                  size: ZipherButtonSize.small,
                  onPressed: _loadBackup,
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
    final seedValue = _keychainSeed ?? backup.seed;
    if (seedValue != null && !backup.saved) {
      setActiveAccount(aa.coin, aa.id);
    }

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          widget.advanced ? 'Advanced keys' : 'Recovery phrase',
          style: ZipherType.headline,
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              size: 20, color: ZipherColors.text90),
          onPressed: () => GoRouter.of(context).pop(),
        ),
      ),
      body: _obscured
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.shield_rounded,
                      size: 48, color: ZipherColors.text20),
                  Gap(16),
                  Text('Hidden while Zipher is in the background',
                      style: ZipherType.subhead),
                ],
              ),
            )
          : widget.advanced
              ? _advancedBody(backup, s)
              : _phraseBody(backup, seedValue, s),
    );
  }

  /// One job: show the phrase safely and confirm it was written down.
  Widget _phraseBody(_Backup backup, String? seedValue, S s) {
    final backedUp = _verificationPassed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(ZipherColors.pagePadding,
                ZipherSpacing.sm, ZipherColors.pagePadding, ZipherSpacing.lg),
            children: [
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(ZipherRadius.full),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                        width: 0.5),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.account_balance_wallet_outlined,
                        size: 14, color: ZipherColors.text60),
                    const Gap(6),
                    Text(backup.name ?? 'This wallet',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: ZipherColors.text90)),
                  ]),
                ),
                const Spacer(),
                Icon(
                    backedUp
                        ? Icons.check_circle_rounded
                        : Icons.error_outline_rounded,
                    size: 16,
                    color: backedUp ? ZipherColors.positive : ZipherColors.warm),
                const Gap(5),
                Text(backedUp ? 'Backed up' : 'Not backed up yet',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: backedUp
                            ? ZipherColors.positive
                            : ZipherColors.warm)),
              ]),
              const Gap(ZipherSpacing.md),
              if (seedValue != null) ...[
                _SeedCard(
                  onCopy: _copyRecovery,
                  seedPhrase: backup.index != 0
                      ? '$seedValue [${backup.index}]'
                      : seedValue,
                  wordsVisible: _seedWordsVisible,
                  onToggleWords: () => _toggleReveal(_seedWordsVisible,
                      () => _seedWordsVisible = !_seedWordsVisible),
                  onShowQR: () =>
                      _showQR(context, seedValue, '${s.seed} of ${backup.name}'),
                ),
                const Gap(ZipherSpacing.md),
                Text(
                    isTestnet
                        ? 'Testnet-only phrase, separate from your mainnet wallet. Testnet coins have no value.'
                        : 'Anyone with these words can take your funds. Never share them, and never type them into a website.',
                    style: ZipherType.footnote),
              ] else
                Text(
                    _testnetSeedMissing
                        ? 'This testnet wallet was created before phrases were stored. Turn testnet off and on again to recreate it with a phrase.'
                        : 'This wallet was imported from a viewing key, so it has no recovery phrase. It can show your history but can\'t spend.',
                    style: ZipherType.subhead),
            ],
          ),
        ),
        ZipherWidgets.bottomActions([
          if (seedValue != null && !backedUp)
            ZipherButton(
              label: 'I wrote them down',
              onPressed: () => _startVerification(seedValue),
            ),
          if (seedValue != null && backedUp)
            ZipherButton(
              label: 'Check my backup again',
              kind: ZipherButtonKind.secondary,
              onPressed: () => _startVerification(seedValue),
            ),
          ZipherButton(
            label: 'Advanced: viewing and spending keys',
            kind: ZipherButtonKind.plain,
            size: ZipherButtonSize.small,
            color: ZipherColors.text60,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => BackupPage(advanced: true))),
          ),
        ]),
      ],
    );
  }

  /// Keys most people never need, and which wallets are backed up.
  Widget _advancedBody(_Backup backup, S s) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(ZipherColors.pagePadding,
          ZipherSpacing.sm, ZipherColors.pagePadding, ZipherSpacing.xl),
      children: [
        const Text(
            'Most people never need these. Your recovery phrase already covers these keys.',
            style: ZipherType.subhead),
        const Gap(ZipherSpacing.lg),
        const Text('Viewing key', style: ZipherType.section),
        const Gap(ZipherSpacing.sm),
        if (backup.uvk != null)
          _KeyCard(
            onCopy: _copyRecovery,
            label: 'Unified viewing key',
            description:
                'Read-only. Share it to let someone, like an accountant, see this wallet’s full history. They can’t spend.',
            value: backup.uvk!,
            icon: Icons.visibility_rounded,
            revealed: _uvkRevealed,
            onToggleReveal: () =>
                _toggleReveal(_uvkRevealed, () => _uvkRevealed = !_uvkRevealed),
            onShowQR: () => _showQR(context, backup.uvk!,
                '${s.unifiedViewingKey} of ${backup.name}'),
          )
        else
          const Text('No viewing key is available for this wallet.',
              style: ZipherType.footnote),
        if (backup.fvk != null) ...[
          const Gap(ZipherSpacing.smMd),
          _KeyCard(
            onCopy: _copyRecovery,
            label: 'Sapling viewing key',
            description: 'Read-only, Sapling pool only.',
            value: backup.fvk!,
            icon: Icons.visibility_outlined,
            revealed: _fvkRevealed,
            onToggleReveal: () =>
                _toggleReveal(_fvkRevealed, () => _fvkRevealed = !_fvkRevealed),
            onShowQR: () => _showQR(
                context, backup.fvk!, '${s.viewingKey} of ${backup.name}'),
          ),
        ],
        if (backup.tsk != null || backup.sk != null) ...[
          const Gap(ZipherSpacing.lg),
          const Text('Spending keys', style: ZipherType.section),
          const Gap(ZipherSpacing.sm),
          if (backup.tsk != null)
            _KeyCard(
              onCopy: _copyRecovery,
              label: 'Transparent key',
              description: 'Full control of public funds. Developers only.',
              value: backup.tsk!,
              icon: Icons.key_rounded,
              revealed: _tskRevealed,
              onToggleReveal: () => _toggleReveal(
                  _tskRevealed, () => _tskRevealed = !_tskRevealed),
              onShowQR: () => _showQR(context, backup.tsk!,
                  '${s.transparentKey} of ${backup.name}'),
            ),
          if (backup.sk != null) ...[
            const Gap(ZipherSpacing.smMd),
            _KeyCard(
              onCopy: _copyRecovery,
              label: 'Secret key',
              description:
                  'Full control of shielded funds. Developers only.',
              value: backup.sk!,
              icon: Icons.vpn_key_rounded,
              revealed: _skRevealed,
              onToggleReveal: () =>
                  _toggleReveal(_skRevealed, () => _skRevealed = !_skRevealed),
              onShowQR: () => _showQR(
                  context, backup.sk!, '${s.secretKey} of ${backup.name}'),
            ),
          ],
        ],
        if (_allWallets.isNotEmpty) ...[
          const Gap(ZipherSpacing.lg),
          const Text('Your wallets', style: ZipherType.section),
          const Gap(ZipherSpacing.sm),
          ZipherWidgets.group([
            for (final w in _allWallets)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: ZipherSpacing.md, vertical: ZipherSpacing.smMd),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(w.name, style: ZipherType.rowTitle),
                        const Gap(2),
                        Text(
                            w.id == aa.walletId
                                ? 'Open now · its own recovery phrase'
                                : 'Its own recovery phrase',
                            style: ZipherType.footnote),
                      ],
                    ),
                  ),
                  Icon(
                      _walletBackedUp[w.id] == true
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: _walletBackedUp[w.id] == true
                          ? ZipherColors.positive
                          : ZipherColors.warm),
                ]),
              ),
          ]),
        ],
        if (_birthdayHeight != null) ...[
          const Gap(ZipherSpacing.md),
          Text('Wallet start: block $_birthdayHeight',
              style: ZipherType.footnote),
        ],
      ],
    );
  }

  Future<bool> _authorizeReveal() async {
    if (_authorizingReveal ||
        _sourceWalletId != WalletService.instance.activeWalletId ||
        _sourceNetwork != isTestnet) return false;
    _authorizingReveal = true;
    final epoch = _revealEpoch;
    final walletId = WalletService.instance.activeWalletId;
    final network = isTestnet;
    try {
      final ok =
          await authenticate(context, 'Show wallet recovery information');
      return ok &&
          mounted &&
          epoch == _revealEpoch &&
          walletId == WalletService.instance.activeWalletId &&
          network == isTestnet;
    } finally {
      _authorizingReveal = false;
    }
  }

  Future<void> _copyRecovery(String value) async {
    if (await _authorizeReveal() && mounted) {
      _copyWithAutoClear(context, value, label: 'Recovery information');
    }
  }

  Future<void> _toggleReveal(bool visible, VoidCallback reveal) async {
    if (visible || await _authorizeReveal()) {
      if (mounted) setState(reveal);
    }
  }

  void _startVerification(String seed) async {
    if (!await _authorizeReveal()) return;
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
              BackupStatus.instance
                  .markBackedUp(WalletService.instance.activeWalletId);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Backup verified'),
                  backgroundColor: ZipherColors.green.withValues(alpha: 0.8),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(ZipherRadius.md)),
                  duration: const Duration(seconds: 2),
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text(
                      'Incorrect words. Please check your seed phrase and try again.'),
                  backgroundColor: ZipherColors.red.withValues(alpha: 0.8),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(ZipherRadius.md)),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  void _showQR(BuildContext context, String value, String title) async {
    if (!await _authorizeReveal() || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SensitiveQrPage(
            title: title, value: value, authorize: _authorizeReveal)));
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
  final bool revealed;
  final VoidCallback? onToggleReveal;
  final VoidCallback? onShowQR;
  final ValueChanged<String> onCopy;

  const _KeyCard({
    required this.label,
    required this.description,
    required this.value,
    required this.icon,
    this.revealed = false,
    this.onToggleReveal,
    this.onShowQR,
    required this.onCopy,
  });

  bool get _isVisible => revealed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.card),
        border: Border.all(color: ZipherColors.borderSubtle, width: 0.5),
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
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(ZipherRadius.card),
                      border: Border.all(color: ZipherColors.borderSubtle, width: 0.5),
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
                  () => onCopy(value),
                ),
                const Gap(8),
                _actionButton(Icons.qr_code_rounded, 'QR', onShowQR),
                if (onToggleReveal != null) ...[
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

  Widget _actionButton(IconData icon, String label, VoidCallback? onTap) {
    return ZipherButton(
      label: label,
      icon: icon,
      kind: ZipherButtonKind.secondary,
      size: ZipherButtonSize.small,
      onPressed: onTap,
    );
  }
}

// ─── Seed card with per-word grid ───────────────────────────────────

class _SeedCard extends StatelessWidget {
  final String seedPhrase;
  final bool wordsVisible;
  final VoidCallback? onToggleWords;
  final VoidCallback? onShowQR;
  final ValueChanged<String> onCopy;

  const _SeedCard({
    required this.seedPhrase,
    required this.wordsVisible,
    this.onToggleWords,
    this.onShowQR,
    required this.onCopy,
  });

  String get _clean => seedPhrase.replaceAll(RegExp(r'\s*\[\d+\]\s*$'), '');

  @override
  Widget build(BuildContext context) {
    final words = _clean.trim().split(RegExp(r'\s+'));
    final grid = GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisExtent: 40,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: words.length,
      itemBuilder: (_, i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(ZipherRadius.sm),
        ),
        child: Row(children: [
          SizedBox(
            width: 22,
            child: Text('${i + 1}',
                style: const TextStyle(fontSize: 11, color: ZipherColors.text20)),
          ),
          Expanded(
            child: Text(
              wordsVisible ? words[i] : '••••',
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: wordsVisible ? ZipherColors.text90 : ZipherColors.text20,
                letterSpacing: wordsVisible ? 0 : 2,
              ),
            ),
          ),
        ]),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(ZipherSpacing.smMd),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(ZipherRadius.card),
            border: Border.all(color: ZipherColors.borderSubtle, width: 0.5),
          ),
          child: Stack(children: [
            grid,
            if (!wordsVisible)
              Positioned.fill(
                child: Semantics(
                  button: true,
                  label: 'Show recovery phrase',
                  child: GestureDetector(
                    onTap: onToggleWords,
                    child: Container(
                      decoration: BoxDecoration(
                        color: ZipherColors.bg.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(ZipherRadius.md),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.visibility_rounded,
                              size: 26, color: ZipherColors.text90),
                          Gap(8),
                          Text('Tap to show', style: ZipherType.rowTitle),
                          Gap(4),
                          Text('Make sure no one can see your screen',
                              style: ZipherType.footnote),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        if (wordsVisible) ...[
          const Gap(ZipherSpacing.smMd),
          Row(children: [
            Expanded(
              child: ZipherButton(
                label: 'Hide',
                icon: Icons.visibility_off_rounded,
                kind: ZipherButtonKind.secondary,
                size: ZipherButtonSize.small,
                onPressed: onToggleWords,
              ),
            ),
            const Gap(8),
            Expanded(
              child: ZipherButton(
                label: 'Copy',
                icon: Icons.copy_rounded,
                kind: ZipherButtonKind.secondary,
                size: ZipherButtonSize.small,
                onPressed: () => onCopy(_clean),
              ),
            ),
            const Gap(8),
            Expanded(
              child: ZipherButton(
                label: 'QR',
                icon: Icons.qr_code_rounded,
                kind: ZipherButtonKind.secondary,
                size: ZipherButtonSize.small,
                onPressed: onShowQR,
              ),
            ),
          ]),
        ],
      ],
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
          icon: Icon(Icons.close_rounded, color: ZipherColors.text60),
          onPressed: () {
            Navigator.of(context).pop();
            widget.onResult(null);
          },
        ),
        title: Text(
          'Verify backup',
          style: ZipherType.headline,
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
                  size: 48, color: ZipherColors.cyan.withValues(alpha: 0.5)),
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
                    borderRadius: BorderRadius.circular(ZipherRadius.card),
                    border: Border.all(color: ZipherColors.borderSubtle, width: 0.5),
                  ),
                  child: TextField(
                    controller: _controllers[i],
                    focusNode: _focusNodes[i],
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction:
                        i < 2 ? TextInputAction.next : TextInputAction.done,
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
              ZipherButton(
                label: 'Verify',
                onPressed: _verify,
              ),
              const Gap(16),
            ],
          ),
        ),
      ),
    );
  }
}
