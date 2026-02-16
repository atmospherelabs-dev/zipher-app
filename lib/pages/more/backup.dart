import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../zipher_theme.dart';
import '../../generated/intl/messages.dart';

class BackupPage extends StatefulWidget {
  late final Backup backup;
  late final String primary;

  BackupPage() {
    backup = WarpApi.getBackup(aa.coin, aa.id);
    if (backup.seed != null)
      primary = backup.seed!;
    else if (backup.sk != null)
      primary = backup.sk!;
    else if (backup.uvk != null)
      primary = backup.uvk!;
    else if (backup.fvk != null)
      primary = backup.fvk!;
    else
      throw 'Account has no key';
  }

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBirthday();
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
    final backup = widget.backup;

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
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded,
              color: Colors.white.withValues(alpha: 0.5)),
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
                        color: Colors.white.withValues(alpha: 0.08)),
                    const Gap(16),
                    Text(
                      'Content hidden for security',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.15),
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
                      color: Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.account_circle_outlined,
                                size: 15,
                                color:
                                    Colors.white.withValues(alpha: 0.25)),
                            const Gap(8),
                            Text(
                              'Account',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    Colors.white.withValues(alpha: 0.3),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${backup.name ?? 'Unknown'} (#${backup.index})',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color:
                                    Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 8),
                          child: Divider(
                            height: 1,
                            color: Colors.white.withValues(alpha: 0.04),
                          ),
                        ),
                        Row(
                          children: [
                            Icon(Icons.backup_rounded,
                                size: 15,
                                color:
                                    Colors.white.withValues(alpha: 0.25)),
                            const Gap(8),
                            Text(
                              'Backup saved',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    Colors.white.withValues(alpha: 0.3),
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
                                  Colors.white.withValues(alpha: 0.04),
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
                          color: Colors.white.withValues(alpha: 0.2),
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
                          accentColor: Colors.white.withValues(alpha: 0.4),
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
                      if (backup.seed != null) ...[
                        const Gap(12),
                        _KeyCard(
                          label: 'Seed Phrase',
                          description:
                              'Master key — derives ALL accounts and keys. If lost, funds are unrecoverable. If stolen, everything is compromised.',
                          value: backup.index != 0
                              ? '${backup.seed!} [${backup.index}]'
                              : backup.seed!,
                          accentColor: ZipherColors.orange,
                          icon: Icons.shield_rounded,
                          revealed: _seedRevealed,
                          onToggleReveal: () {
                            setState(
                                () => _seedRevealed = !_seedRevealed);
                            if (_seedRevealed && !widget.backup.saved) {
                              WarpApi.setBackupReminder(
                                  aa.coin, aa.id, true);
                              // Reload active account so aa.saved updates
                              setActiveAccount(aa.coin, aa.id);
                            }
                          },
                          onShowQR: () => _showQR(context, backup.seed!,
                              '${s.seed} of ${backup.name}'),
                        ),
                      ],
                    ],
                  ],

                  const Gap(40),
                ],
              ),
            ),
    );
  }

  bool _hasSpendingKeys(Backup b) =>
      b.seed != null || b.sk != null || b.tsk != null;

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
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.18),
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
        color: Colors.white.withValues(alpha: 0.2),
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
                    color: Colors.white.withValues(alpha: 0.5),
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
              color: Colors.white.withValues(alpha: 0.18),
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
                    color: Colors.white.withValues(alpha: 0.7),
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
                      color: Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.visibility_off_rounded,
                            size: 18,
                            color: Colors.white.withValues(alpha: 0.12)),
                        const Gap(4),
                        Text(
                          'Tap to reveal',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.12),
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
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: Colors.white.withValues(alpha: 0.25)),
            const Gap(4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: Colors.white.withValues(alpha: 0.25),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
