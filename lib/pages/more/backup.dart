import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../services/secure_key_store.dart';
import '../../zipher_theme.dart';
import '../../generated/intl/messages.dart';

class BackupPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _BackupState();
}

class _BackupState extends State<BackupPage> with WidgetsBindingObserver {
  bool _showSpendingKeys = false;
  bool _seedRevealed = false;
  bool _skRevealed = false;
  bool _tskRevealed = false;
  bool _obscured = false;
  int? _birthdayHeight;
  bool _verificationPassed = false;

  Backup? _backup;
  String? _primary;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBackup();
    _loadBirthday();
  }

  String? _keychainSeed;

  void _loadBackup() async {
    try {
      final backup = WarpApi.getBackup(aa.coin, aa.id);

      // Read seed from Keychain (post-migration it won't be in the DB)
      final kcSeed = await SecureKeyStore.getSeed(aa.coin, aa.id);

      String primary;
      if (kcSeed != null)
        primary = kcSeed;
      else if (backup.seed != null)
        primary = backup.seed!;
      else if (backup.sk != null)
        primary = backup.sk!;
      else if (backup.uvk != null)
        primary = backup.uvk!;
      else if (backup.fvk != null)
        primary = backup.fvk!;
      else {
        setState(() => _loadError = 'Account has no key');
        return;
      }
      if (!mounted) return;
      setState(() {
        _backup = backup;
        _primary = primary;
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Obscure content when app goes to background (screenshot/task switcher)
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
            icon: Icon(Icons.arrow_back_rounded,
                color: ZipherColors.text60),
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
                    size: 40, color: ZipherColors.orange.withValues(alpha: 0.4)),
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
                      color: ZipherColors.cyan.withValues(alpha: 0.6),
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
          icon: Icon(Icons.arrow_back_rounded,
              color: ZipherColors.text60),
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
                        size: 48,
                        color: ZipherColors.cardBgElevated),
                    const Gap(16),
                    Text(
                      'Content hidden for security',
                      style: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text10,
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
                      borderRadius: BorderRadius.circular(14),
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
                                  .withValues(alpha: 0.7),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Gap(20),

                  // ═══════════════════════════════════
                  // WALLET INFO
                  // ═══════════════════════════════════
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: ZipherColors.borderSubtle,
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.account_circle_outlined,
                                size: 15,
                                color:
                                    ZipherColors.text20),
                            const Gap(8),
                            Text(
                              'Account',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    ZipherColors.text40,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${backup.name ?? 'Unknown'} (#${backup.index})',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color:
                                    ZipherColors.text60,
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 8),
                          child: Divider(
                            height: 1,
                            color: ZipherColors.cardBg,
                          ),
                        ),
                        Row(
                          children: [
                            Icon(Icons.backup_rounded,
                                size: 15,
                                color:
                                    ZipherColors.text20),
                            const Gap(8),
                            Text(
                              'Backup saved',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    ZipherColors.text40,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              backup.saved ? 'Yes' : 'No',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: backup.saved
                                    ? ZipherColors.green
                                        .withValues(alpha: 0.6)
                                    : ZipherColors.orange
                                        .withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                        if (_birthdayHeight != null) ...[
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 8),
                            child: Divider(
                              height: 1,
                              color:
                                  ZipherColors.cardBg,
                            ),
                          ),
                          Row(
                            children: [
                              Icon(Icons.cake_outlined,
                                  size: 15,
                                  color: Colors.white
                                      .withValues(alpha: 0.25)),
                              const Gap(8),
                              Text(
                                'Birthday',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white
                                      .withValues(alpha: 0.3),
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'Block $_birthdayHeight',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  const Gap(24),

                  // ═══════════════════════════════════
                  // VIEWING KEYS (safe, always visible)
                  // ═══════════════════════════════════
                  _sectionHeader(
                    'Viewing Keys',
                    'Read-only access — safe to share for auditing',
                    Icons.visibility_rounded,
                    ZipherColors.cyan,
                  ),
                  const Gap(12),

                  if (backup.uvk != null)
                    _KeyCard(
                      label: 'Unified Viewing Key',
                      description:
                          'Can view all transactions across all pools. Cannot spend funds.',
                      value: backup.uvk!,
                      accentColor: ZipherColors.purple,
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
                      accentColor: ZipherColors.cyan,
                      icon: Icons.visibility_outlined,
                      alwaysVisible: true,
                      onShowQR: () => _showQR(context, backup.fvk!,
                          '${s.viewingKey} of ${backup.name}'),
                    ),
                  ],

                  const Gap(28),

                  // ═══════════════════════════════════
                  // SPENDING KEYS (dangerous, hidden)
                  // ═══════════════════════════════════
                  if (_hasSpendingKeys(backup)) ...[
                    GestureDetector(
                      onTap: () => setState(
                          () => _showSpendingKeys = !_showSpendingKeys),
                      child: _sectionHeader(
                        'Spending Keys',
                        'Full control — never share these',
                        Icons.lock_rounded,
                        ZipherColors.orange,
                        trailing: Icon(
                          _showSpendingKeys
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: ZipherColors.text20,
                        ),
                      ),
                    ),

                    if (_showSpendingKeys) ...[
                      const Gap(12),

                      // Transparent Key
                      if (backup.tsk != null)
                        _KeyCard(
                          label: 'Transparent Key',
                          description:
                              'Can spend transparent (public) funds only.',
                          value: backup.tsk!,
                          accentColor: ZipherColors.text40,
                          icon: Icons.key_rounded,
                          revealed: _tskRevealed,
                          onToggleReveal: () =>
                              setState(() => _tskRevealed = !_tskRevealed),
                          onShowQR: () => _showQR(context, backup.tsk!,
                              '${s.transparentKey} of ${backup.name}'),
                        ),

                      // Secret Key
                      if (backup.sk != null) ...[
                        const Gap(12),
                        _KeyCard(
                          label: 'Secret Key',
                          description:
                              'Can spend all shielded funds in this account.',
                          value: backup.sk!,
                          accentColor: ZipherColors.red,
                          icon: Icons.vpn_key_rounded,
                          revealed: _skRevealed,
                          onToggleReveal: () =>
                              setState(() => _skRevealed = !_skRevealed),
                          onShowQR: () => _showQR(context, backup.sk!,
                              '${s.secretKey} of ${backup.name}'),
                        ),
                      ],

                      // Seed Phrase (most dangerous, last)
                      if ((_keychainSeed ?? backup.seed) != null) ...[
                        const Gap(12),
                        Builder(builder: (ctx) {
                          final seedValue = _keychainSeed ?? backup.seed!;
                          return _KeyCard(
                            label: 'Seed Phrase',
                            description:
                                'Master key — derives ALL accounts and keys. If lost, funds are unrecoverable. If stolen, everything is compromised.',
                            value: backup.index != 0
                                ? '$seedValue [${backup.index}]'
                                : seedValue,
                            accentColor: ZipherColors.orange,
                            icon: Icons.shield_rounded,
                            revealed: _seedRevealed,
                            onToggleReveal: () {
                              setState(
                                  () => _seedRevealed = !_seedRevealed);
                              if (_seedRevealed && !_backup!.saved) {
                                WarpApi.setBackupReminder(
                                    aa.coin, aa.id, true);
                                setActiveAccount(aa.coin, aa.id);
                              }
                            },
                            onShowQR: () => _showQR(context, seedValue,
                                '${s.seed} of ${backup.name}'),
                          );
                        }),

                        // Verify Backup button
                        if (_seedRevealed && !_verificationPassed) ...[
                          const Gap(16),
                          GestureDetector(
                            onTap: () => _startVerification(
                                (_keychainSeed ?? backup.seed)!),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                gradient: ZipherColors.primaryGradient,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.quiz_rounded, size: 18,
                                      color: ZipherColors.textOnBrand),
                                  const Gap(8),
                                  Text('Verify Backup', style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700,
                                    color: ZipherColors.textOnBrand,
                                  )),
                                ],
                              ),
                            ),
                          ),
                        ],

                        // Verified badge
                        if (_verificationPassed) ...[
                          const Gap(16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: ZipherColors.green.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: ZipherColors.green.withValues(alpha: 0.15),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.check_circle_rounded, size: 18,
                                    color: ZipherColors.green.withValues(alpha: 0.7)),
                                const Gap(8),
                                Text('Backup Verified', style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600,
                                  color: ZipherColors.green.withValues(alpha: 0.7),
                                )),
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

    final controllers = List.generate(3, (_) => TextEditingController());
    final focusNodes = List.generate(3, (_) => FocusNode());

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: ZipherColors.bg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border(
                top: BorderSide(color: ZipherColors.cardBgElevated, width: 0.5),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Gap(10),
                    Container(
                      width: 36, height: 4,
                      decoration: BoxDecoration(
                        color: ZipherColors.cardBgElevated,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const Gap(20),
                    Icon(Icons.quiz_rounded, size: 28,
                        color: ZipherColors.cyan.withValues(alpha: 0.5)),
                    const Gap(12),
                    Text('Verify Your Seed', style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700,
                      color: ZipherColors.text90,
                    )),
                    const Gap(6),
                    Text(
                      'Enter the requested words to confirm you saved your seed phrase.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: ZipherColors.text40,
                        height: 1.4,
                      ),
                    ),
                    const Gap(24),
                    for (int i = 0; i < 3; i++) ...[
                      if (i > 0) const Gap(12),
                      Container(
                        decoration: BoxDecoration(
                          color: ZipherColors.borderSubtle,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: TextField(
                          controller: controllers[i],
                          focusNode: focusNodes[i],
                          autofocus: i == 0,
                          textInputAction: i < 2 ? TextInputAction.next : TextInputAction.done,
                          onSubmitted: (_) {
                            if (i < 2) focusNodes[i + 1].requestFocus();
                          },
                          style: TextStyle(
                            fontSize: 14,
                            color: ZipherColors.text90,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Word #${sortedIndices[i] + 1}',
                            labelStyle: TextStyle(
                              fontSize: 13,
                              color: ZipherColors.text40,
                            ),
                            filled: false,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                          ),
                        ),
                      ),
                    ],
                    const Gap(24),
                    GestureDetector(
                      onTap: () {
                        bool allCorrect = true;
                        for (int i = 0; i < 3; i++) {
                          if (controllers[i].text.trim().toLowerCase() !=
                              words[sortedIndices[i]].toLowerCase()) {
                            allCorrect = false;
                            break;
                          }
                        }
                        Navigator.pop(ctx);
                        for (final c in controllers) c.dispose();
                        for (final f in focusNodes) f.dispose();

                        if (allCorrect) {
                          setState(() => _verificationPassed = true);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text('Backup verified successfully!'),
                              backgroundColor: ZipherColors.green.withValues(alpha: 0.8),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text('Incorrect words. Please check your seed phrase and try again.'),
                              backgroundColor: ZipherColors.red.withValues(alpha: 0.8),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          gradient: ZipherColors.primaryGradient,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: Text('Verify', style: TextStyle(
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
          ),
        );
      },
    );
  }

  bool _hasSpendingKeys(Backup b) =>
      _keychainSeed != null || b.seed != null || b.sk != null || b.tsk != null;

  Widget _sectionHeader(
      String title, String subtitle, IconData icon, Color color,
      {Widget? trailing}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color.withValues(alpha: 0.5)),
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
                  color: ZipherColors.text20,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: ZipherColors.text20,
      ),
    );
  }

  void _showQR(BuildContext context, String value, String title) {
    GoRouter.of(context).push('/showqr?title=$title', extra: value);
  }
}

// ═══════════════════════════════════════════════════════════
// KEY CARD WIDGET
// ═══════════════════════════════════════════════════════════

class _KeyCard extends StatelessWidget {
  final String label;
  final String description;
  final String value;
  final Color accentColor;
  final IconData icon;
  final bool alwaysVisible;
  final bool revealed;
  final VoidCallback? onToggleReveal;
  final VoidCallback? onShowQR;

  const _KeyCard({
    required this.label,
    required this.description,
    required this.value,
    required this.accentColor,
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
        color: accentColor.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Icon(icon, size: 14, color: accentColor.withValues(alpha: 0.5)),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: ZipherColors.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'READ-ONLY',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: ZipherColors.green.withValues(alpha: 0.5),
                    ),
                  ),
                ),
            ],
          ),

          const Gap(6),

          // Description
          Text(
            description,
            style: TextStyle(
              fontSize: 11,
              color: ZipherColors.text20,
              height: 1.4,
            ),
          ),

          const Gap(10),

          // Value
          _isVisible
              ? SelectableText(
                  value,
                  style: TextStyle(
                    fontSize: 12,
                    color: ZipherColors.text60,
                    height: 1.5,
                    fontFamily: 'monospace',
                  ),
                )
              : GestureDetector(
                  onTap: onToggleReveal,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.visibility_off_rounded,
                            size: 18,
                            color: ZipherColors.text10),
                        const Gap(4),
                        Text(
                          'Tap to reveal',
                          style: TextStyle(
                            fontSize: 11,
                            color: ZipherColors.text10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

          if (_isVisible) ...[
            const Gap(10),
            // Actions row
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
                _actionButton(
                  Icons.qr_code_rounded,
                  'QR',
                  onShowQR,
                ),
                if (!alwaysVisible && onToggleReveal != null) ...[
                  const Gap(8),
                  _actionButton(
                    Icons.visibility_off_rounded,
                    'Hide',
                    onToggleReveal,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(8),
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
                color: ZipherColors.text20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
