import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';

import '../../zipher_theme.dart';

/// Post-DKG step: coordinator must save participant #3's backup share offline.
///
/// Never auto-copies to clipboard — user explicitly chooses when to copy.
class FrostBackupShareStep extends StatefulWidget {
  final String backupKeyPackage;
  final VoidCallback onSaved;

  const FrostBackupShareStep({
    super.key,
    required this.backupKeyPackage,
    required this.onSaved,
  });

  @override
  State<FrostBackupShareStep> createState() => _FrostBackupShareStepState();
}

class _FrostBackupShareStepState extends State<FrostBackupShareStep> {
  bool _acknowledged = false;
  bool _revealed = false;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.backupKeyPackage));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Backup share copied',
            style: TextStyle(color: ZipherColors.text90, fontSize: 13)),
        backgroundColor: ZipherColors.surface,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _revealed
        ? widget.backupKeyPackage
        : '${widget.backupKeyPackage.substring(0, 24)}…'
            '${widget.backupKeyPackage.substring(widget.backupKeyPackage.length - 12)}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.warm.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.warm.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.save_alt_rounded, color: ZipherColors.warm, size: 22),
              const Gap(10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Save your backup share',
                      style: TextStyle(
                        color: ZipherColors.text90,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Gap(6),
                    Text(
                      'Store this offline in a password manager or encrypted backup. '
                      'If you lose your phone and a co-signer, this share is the only way to recover spending access.',
                      style: TextStyle(
                        color: ZipherColors.text60,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Gap(16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ZipherColors.cardBg,
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              border: Border.all(color: ZipherColors.borderSubtle),
            ),
            child: Text(
              preview,
              style: TextStyle(
                color: ZipherColors.text60,
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                height: 1.4,
              ),
            ),
          ),
          const Gap(12),
          Row(
            children: [
              Expanded(
                child: _MiniButton(
                  label: _revealed ? 'Hide' : 'Reveal',
                  icon: _revealed
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  onTap: () => setState(() => _revealed = !_revealed),
                ),
              ),
              const Gap(10),
              Expanded(
                child: _MiniButton(
                  label: _copied ? 'Copied' : 'Copy share',
                  icon: Icons.content_copy_rounded,
                  onTap: _copy,
                ),
              ),
            ],
          ),
          const Gap(14),
          GestureDetector(
            onTap: () => setState(() => _acknowledged = !_acknowledged),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Checkbox(
                    value: _acknowledged,
                    onChanged: (v) => setState(() => _acknowledged = v ?? false),
                    activeColor: ZipherColors.cyan,
                    side: BorderSide(color: ZipherColors.text40),
                  ),
                ),
                const Gap(10),
                Expanded(
                  child: Text(
                    'I saved this backup share in a secure place separate from this phone.',
                    style: TextStyle(
                      color: ZipherColors.text60,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Gap(14),
          _MiniButton(
            label: 'Continue to wallet',
            icon: Icons.arrow_forward_rounded,
            filled: true,
            enabled: _acknowledged,
            onTap: _acknowledged ? widget.onSaved : () {},
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  final bool enabled;

  const _MiniButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.filled = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? ZipherColors.cyan : ZipherColors.text40;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: filled ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const Gap(6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
