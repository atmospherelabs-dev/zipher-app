import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../services/secure_key_store.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';

/// Seed phrase restore — single-page flow with optional wallet birthday.
class RestoreAccountPage extends StatefulWidget {
  @override
  State<RestoreAccountPage> createState() => _RestoreAccountPageState();
}

class _RestoreAccountPageState extends State<RestoreAccountPage> {
  final _seedController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  String? _error;

  // Wallet birthday
  DateTime? _selectedDate;
  bool _showDatePicker = false;

  static final _sapling = activationDate; // Oct 2018

  @override
  void dispose() {
    _seedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Gap(12),
                    // Back — minimal, matching disclaimer
                    IconButton(
                      onPressed: () => GoRouter.of(context).pop(),
                      icon: Icon(Icons.arrow_back_rounded,
                          color: ZipherColors.text60,
                          size: 22),
                    ),
                    const Gap(24),
                    // Title
                    Text(
                      'Restore Wallet',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: ZipherColors.text90,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const Gap(8),
                    Text(
                      'Enter your seed phrase to restore an existing Zcash wallet.',
                      style: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text40,
                        height: 1.4,
                      ),
                    ),
                    const Gap(28),

                    // ── Seed input ──
                    Form(
                      key: _formKey,
                      child: TextFormField(
                        controller: _seedController,
                        maxLines: 4,
                        style: TextStyle(
                          fontSize: 15,
                          color: ZipherColors.text90,
                          height: 1.5,
                        ),
                        decoration: InputDecoration(
                          hintText: 'word1 word2 word3 ...',
                          hintStyle: TextStyle(
                            color: ZipherColors.text20,
                          ),
                          filled: true,
                          fillColor: ZipherColors.cardBg,
                          contentPadding: const EdgeInsets.all(16),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide: BorderSide(
                                color:
                                    ZipherColors.borderSubtle),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide: BorderSide(
                                color:
                                    ZipherColors.borderSubtle),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide: BorderSide(
                                color: ZipherColors.cyan
                                    .withValues(alpha: 0.4)),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide: BorderSide(
                                color: ZipherColors.red
                                    .withValues(alpha: 0.5)),
                          ),
                          focusedErrorBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(ZipherRadius.md),
                            borderSide: BorderSide(
                                color: ZipherColors.red
                                    .withValues(alpha: 0.5)),
                          ),
                          errorStyle: TextStyle(
                            color: ZipherColors.red.withValues(alpha: 0.8),
                            fontSize: 12,
                          ),
                        ),
                        validator: _validateSeed,
                      ),
                    ),

                    if (_error != null) ...[
                      const Gap(10),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: ZipherColors.red.withValues(alpha: 0.8),
                          fontSize: 13,
                        ),
                      ),
                    ],

                    const Gap(8),
                    Text(
                      'Supports 12, 15, 18, 21, or 24 word seed phrases.',
                      style: TextStyle(
                        fontSize: 12,
                        color: ZipherColors.text20,
                      ),
                    ),

                    const Gap(24),

                    // ── Wallet birthday section ──
                    GestureDetector(
                      onTap: () =>
                          setState(() => _showDatePicker = !_showDatePicker),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: _selectedDate != null
                              ? ZipherColors.cyan.withValues(alpha: 0.04)
                              : ZipherColors.cardBg,
                          borderRadius:
                              BorderRadius.circular(ZipherRadius.md),
                          border: Border.all(
                            color: _selectedDate != null
                                ? ZipherColors.cyan.withValues(alpha: 0.15)
                                : ZipherColors.borderSubtle,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.calendar_today_rounded,
                              size: 16,
                              color: _selectedDate != null
                                  ? ZipherColors.cyan.withValues(alpha: 0.7)
                                  : ZipherColors.text20,
                            ),
                            const Gap(12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _selectedDate != null
                                        ? DateFormat.yMMMd()
                                            .format(_selectedDate!)
                                        : 'Wallet birthday',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: _selectedDate != null
                                          ? ZipherColors.text90
                                          : ZipherColors.text60,
                                    ),
                                  ),
                                  if (_selectedDate == null) ...[
                                    const Gap(2),
                                    Text(
                                      'Optional — speeds up scanning',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: ZipherColors.text20,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (_selectedDate != null)
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _selectedDate = null),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  color:
                                      ZipherColors.text20,
                                ),
                              )
                            else
                              Icon(
                                _showDatePicker
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                size: 18,
                                color: ZipherColors.text20,
                              ),
                          ],
                        ),
                      ),
                    ),

                    // Date picker (collapsible)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      child: _showDatePicker
                          ? Column(
                              children: [
                                const Gap(8),
                                // Year shortcuts
                                SizedBox(
                                  height: 32,
                                  child: ListView(
                                    scrollDirection: Axis.horizontal,
                                    children: [
                                      for (final year in [
                                        2019, 2020, 2021, 2022, 2023, 2024, 2025, 2026
                                      ])
                                        if (DateTime(year)
                                            .isBefore(DateTime.now()))
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                right: 6),
                                            child: _YearChip(
                                              year: year,
                                              selected:
                                                  _selectedDate?.year ==
                                                      year,
                                              onTap: () => setState(() {
                                                _selectedDate =
                                                    DateTime(year);
                                                _showDatePicker = false;
                                              }),
                                            ),
                                          ),
                                    ],
                                  ),
                                ),
                                const Gap(8),
                                Container(
                                  decoration: BoxDecoration(
                                    color: ZipherColors.cardBg,
                                    borderRadius: BorderRadius.circular(
                                        ZipherRadius.md),
                                    border: Border.all(
                                      color: ZipherColors.borderSubtle,
                                    ),
                                  ),
                                  child: Theme(
                                    data: ThemeData.dark().copyWith(
                                      colorScheme: ColorScheme.dark(
                                        primary: ZipherColors.cyan,
                                        onPrimary: Colors.white,
                                        surface: ZipherColors.bg,
                                        onSurface: ZipherColors.text90,
                                      ),
                                    ),
                                    child: CalendarDatePicker(
                                      initialDate:
                                          _selectedDate ?? DateTime(2022),
                                      firstDate: _sapling,
                                      lastDate: DateTime.now(),
                                      onDateChanged: (date) {
                                        setState(() {
                                          _selectedDate = date;
                                          _showDatePicker = false;
                                        });
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),

                    const Gap(16),

                    // Info hint
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(Icons.info_outline_rounded,
                              size: 14,
                              color:
                                  ZipherColors.text20),
                        ),
                        const Gap(8),
                        Expanded(
                          child: Text(
                            _selectedDate != null
                                ? 'Scanning from ${DateFormat.yMMMd().format(_selectedDate!)}. '
                                  'Transactions before this date won\'t appear.'
                                : 'Full scan from chain activation. '
                                  'This is thorough but takes longer.',
                            style: TextStyle(
                              fontSize: 12,
                              color: ZipherColors.text20,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Gap(24),
                  ],
                ),
              ),
            ),

            // Restore button (pinned at bottom)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
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
                        label: _selectedDate != null
                            ? 'Restore from ${_selectedDate!.year}'
                            : 'Restore (full scan)',
                        icon: Icons.download_done_rounded,
                        onPressed: _restore,
                      ),
              ),
            ),
          ],
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
    final coin = activeCoin.coin;
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
      final coin = activeCoin.coin;
      final name = isTestnet ? 'Testnet' : 'Main';
      final seed = _seedController.text.trim();
      final account = await WarpApi.newAccount(coin, name, seed, 0);
      if (account < 0) {
        setState(() {
          _error = 'This account already exists';
          _loading = false;
        });
        return;
      }
      // Store seed in Keychain, load keys, then clear from DB
      await SecureKeyStore.storeSeed(coin, account, seed, 0);
      WarpApi.loadKeysFromSeed(coin, account, seed, 0);
      WarpApi.clearAccountSecrets(coin, account);
      setActiveAccount(coin, account, canPayOverride: true);
      final prefs = await SharedPreferences.getInstance();
      await aa.save(prefs);

      // Determine scan height
      int scanHeight;
      if (_selectedDate != null) {
        scanHeight =
            await WarpApi.getBlockHeightByTime(coin, _selectedDate!);
      } else {
        scanHeight = 419200; // Sapling activation
      }

      // Start rescan from the determined height
      aa.reset(scanHeight);
      Future(() => syncStatus2.rescan(scanHeight));

      if (mounted) GoRouter.of(context).go('/account');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

// ─── Year shortcut chip ─────────────────────────────────────

class _YearChip extends StatelessWidget {
  final int year;
  final bool selected;
  final VoidCallback onTap;

  const _YearChip({
    required this.year,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? ZipherColors.cyan.withValues(alpha: 0.1)
              : ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? ZipherColors.cyan.withValues(alpha: 0.25)
                : ZipherColors.borderSubtle,
          ),
        ),
        child: Text(
          '$year',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected
                ? ZipherColors.cyan.withValues(alpha: 0.9)
                : ZipherColors.text40,
          ),
        ),
      ),
    );
  }
}
