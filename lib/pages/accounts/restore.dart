import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../generated/intl/messages.dart';
import '../../zipher_theme.dart';
import '../utils.dart';

/// Clean seed phrase restore page — Zipher minimal style.
class RestoreAccountPage extends StatefulWidget {
  @override
  State<RestoreAccountPage> createState() => _RestoreAccountPageState();
}

class _RestoreAccountPageState extends State<RestoreAccountPage> {
  final _seedController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _seedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(16),
              // Back
              IconButton(
                onPressed: () => GoRouter.of(context).pop(),
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: ZipherColors.cyan, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: ZipherColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const Gap(32),
              // Icon
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.restore_outlined,
                    color: ZipherColors.cyan, size: 28),
              ),
              const Gap(20),
              // Title
              const Text(
                'Restore Wallet',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: ZipherColors.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const Gap(8),
              Text(
                'Enter your seed phrase to restore an existing Zcash wallet.',
                style: TextStyle(
                  fontSize: 15,
                  color: ZipherColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const Gap(32),
              // Seed input
              Expanded(
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _seedController,
                        maxLines: 4,
                        style: const TextStyle(
                          fontSize: 16,
                          color: ZipherColors.textPrimary,
                          height: 1.5,
                        ),
                        decoration: InputDecoration(
                          hintText: 'word1 word2 word3 ...',
                          hintStyle: TextStyle(
                            color: ZipherColors.textMuted.withValues(alpha: 0.5),
                          ),
                          filled: true,
                          fillColor: ZipherColors.surface,
                          contentPadding: const EdgeInsets.all(16),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide:
                                const BorderSide(color: ZipherColors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide:
                                const BorderSide(color: ZipherColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide:
                                const BorderSide(color: ZipherColors.cyan),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide:
                                const BorderSide(color: ZipherColors.red),
                          ),
                        ),
                        validator: _validateSeed,
                      ),
                      if (_error != null) ...[
                        const Gap(12),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: ZipherColors.red,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const Gap(16),
                      // Hint
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: ZipherColors.cyan.withValues(alpha: 0.06),
                          borderRadius:
                              BorderRadius.circular(ZipherRadius.sm),
                          border: Border.all(
                            color: ZipherColors.cyan.withValues(alpha: 0.15),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline,
                                color: ZipherColors.cyan, size: 18),
                            const Gap(10),
                            Expanded(
                              child: Text(
                                'Typically 24 words separated by spaces. '
                                'Supports 12, 15, 18, 21, or 24 word phrases.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ZipherColors.textSecondary,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Restore button
              SizedBox(
                width: double.infinity,
                child: _loading
                    ? Center(
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            color: ZipherColors.cyan,
                            strokeWidth: 2,
                          ),
                        ),
                      )
                    : ZipherWidgets.gradientButton(
                        label: 'Restore',
                        icon: Icons.download_done,
                        onPressed: _restore,
                      ),
              ),
              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  String? _validateSeed(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your seed phrase';
    }
    if (WarpApi.isValidTransparentKey(value.trim())) {
      return 'Transparent keys are not supported';
    }
    const coin = 0; // Zcash
    final keyType = WarpApi.validKey(coin, value.trim());
    if (keyType < 0) {
      return 'Invalid seed phrase or key';
    }
    return null;
  }

  Future<void> _restore() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      const coin = 0; // Zcash
      final seed = _seedController.text.trim();
      final account = await WarpApi.newAccount(coin, 'Main', seed, 0);
      if (account < 0) {
        setState(() => _error = 'This account already exists');
        return;
      }
      setActiveAccount(coin, account);
      final prefs = await SharedPreferences.getInstance();
      await aa.save(prefs);
      if (mounted) GoRouter.of(context).go('/account/rescan');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
