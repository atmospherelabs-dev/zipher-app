import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:screen_protector/screen_protector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../services/wallet_service.dart';
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
  bool _seedVisible = false;
  String? _error;

  DateTime? _selectedDate;
  bool _showDatePicker = false;
  int? _expandedYear;

  static final _sapling = activationDate; // Oct 2018

  @override
  void initState() {
    super.initState();
    ScreenProtector.protectDataLeakageOn();
  }

  @override
  void dispose() {
    ScreenProtector.protectDataLeakageOff();
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
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Gap(12),
                    IconButton(
                      onPressed: () => GoRouter.of(context).pop(),
                      icon: Icon(Icons.arrow_back_rounded,
                          color: ZipherColors.text60,
                          size: 22),
                    ),
                    const Gap(24),
                    Text(
                      'Import Account',
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

                    // Seed input
                    Row(
                      children: [
                        Text(
                          'Seed Phrase',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: ZipherColors.text40,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _seedVisible = !_seedVisible),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _seedVisible
                                    ? Icons.visibility_off_rounded
                                    : Icons.visibility_rounded,
                                size: 14,
                                color: ZipherColors.text20,
                              ),
                              const Gap(4),
                              Text(
                                _seedVisible ? 'Hide' : 'Show',
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
                    const Gap(8),
                    Form(
                      key: _formKey,
                      child: GestureDetector(
                        onTap: _seedVisible
                            ? null
                            : () => setState(() => _seedVisible = true),
                        child: _seedVisible
                            ? TextFormField(
                                controller: _seedController,
                                maxLines: 4,
                                autocorrect: false,
                                enableSuggestions: false,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: ZipherColors.text90,
                                  height: 1.5,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'word1 word2 word3 ...',
                                  hintStyle: TextStyle(
                                    fontSize: 15,
                                    color: ZipherColors.text40,
                                  ),
                                  filled: true,
                                  fillColor: ZipherColors.cardBg,
                                  contentPadding: const EdgeInsets.all(ZipherSpacing.md),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                        ZipherRadius.md),
                                    borderSide: BorderSide(
                                        color: ZipherColors.borderSubtle),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                        ZipherRadius.md),
                                    borderSide: BorderSide(
                                        color: ZipherColors.borderSubtle),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                        ZipherRadius.md),
                                    borderSide: BorderSide(
                                        color: ZipherColors.cyan
                                            .withValues(alpha: 0.4)),
                                  ),
                                  errorBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                        ZipherRadius.md),
                                    borderSide: BorderSide(
                                        color: ZipherColors.red
                                            .withValues(alpha: 0.5)),
                                  ),
                                  focusedErrorBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                        ZipherRadius.md),
                                    borderSide: BorderSide(
                                        color: ZipherColors.red
                                            .withValues(alpha: 0.5)),
                                  ),
                                  errorStyle: TextStyle(
                                    color: ZipherColors.red
                                        .withValues(alpha: 0.8),
                                    fontSize: 12,
                                  ),
                                ),
                                validator: _validateSeed,
                              )
                            : Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(ZipherSpacing.md),
                                constraints:
                                    const BoxConstraints(minHeight: 100),
                                decoration: BoxDecoration(
                                  color: ZipherColors.cardBg,
                                  borderRadius: BorderRadius.circular(
                                      ZipherRadius.md),
                                  border: Border.all(
                                      color: ZipherColors.borderSubtle),
                                ),
                                child: _seedController.text.isEmpty
                                    ? Text(
                                        'Tap to enter your seed phrase...',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: ZipherColors.text40,
                                        ),
                                      )
                                    : Text(
                                        _seedController.text
                                            .split(RegExp(r'\s+'))
                                            .map((_) => '••••')
                                            .join(' '),
                                        style: TextStyle(
                                          fontSize: 15,
                                          color: ZipherColors.text40,
                                          height: 1.5,
                                        ),
                                      ),
                              ),
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
                        color: ZipherColors.text40,
                      ),
                    ),

                    const Gap(24),

                    // Wallet birthday — year + month picker
                    GestureDetector(
                      onTap: () => setState(() {
                        _showDatePicker = !_showDatePicker;
                        if (!_showDatePicker) _expandedYear = null;
                      }),
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
                                        ? DateFormat.yMMM()
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
                                        color: ZipherColors.text40,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (_selectedDate != null)
                              GestureDetector(
                                onTap: () => setState(() {
                                  _selectedDate = null;
                                  _expandedYear = null;
                                }),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  color: ZipherColors.text20,
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

                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      child: _showDatePicker
                          ? Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: _buildYearMonthPicker(),
                            )
                          : const SizedBox.shrink(),
                    ),

                    const Gap(16),

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
                                ? 'Scanning from ${DateFormat.yMMM().format(_selectedDate!)}. '
                                  'Transactions before this date won\'t appear.'
                                : 'Full scan from chain activation. '
                                  'This is thorough but takes longer.',
                            style: TextStyle(
                              fontSize: 12,
                              color: ZipherColors.text40,
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

            // Restore button
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
                            ? 'Restore from ${DateFormat.yMMM().format(_selectedDate!)}'
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

  Widget _buildYearMonthPicker() {
    final now = DateTime.now();
    final startYear = _sapling.year + 1; // 2019
    final years = <int>[];
    for (int y = startYear; y <= now.year; y++) {
      years.add(y);
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'When was this wallet created?',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: ZipherColors.text40,
            ),
          ),
          const Gap(12),
          // Year grid
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: years.map((year) {
              final isSelected = _selectedDate?.year == year;
              final isExpanded = _expandedYear == year;
              return GestureDetector(
                onTap: () => setState(() {
                  if (_expandedYear == year) {
                    _expandedYear = null;
                  } else {
                    _expandedYear = year;
                  }
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isExpanded
                        ? ZipherColors.cyan.withValues(alpha: 0.12)
                        : isSelected
                            ? ZipherColors.cyan.withValues(alpha: 0.08)
                            : Colors.white.withValues(alpha: 0.02),
                    borderRadius: BorderRadius.circular(ZipherRadius.sm),
                    border: Border.all(
                      color: isExpanded
                          ? ZipherColors.cyan.withValues(alpha: 0.3)
                          : isSelected
                              ? ZipherColors.cyan.withValues(alpha: 0.2)
                              : ZipherColors.borderSubtle,
                    ),
                  ),
                  child: Text(
                    '$year',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isExpanded || isSelected
                          ? ZipherColors.cyan
                          : ZipherColors.text60,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          // Month grid for expanded year
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: _expandedYear != null
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _buildMonthGrid(_expandedYear!, now),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthGrid(int year, DateTime now) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 2.2,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: 12,
      itemBuilder: (context, i) {
        final monthDate = DateTime(year, i + 1);
        final isFuture = monthDate.isAfter(now);
        final isBeforeSapling = monthDate.isBefore(_sapling);
        final disabled = isFuture || isBeforeSapling;
        final isSelected = _selectedDate?.year == year &&
            _selectedDate?.month == i + 1;

        return GestureDetector(
          onTap: disabled
              ? null
              : () => setState(() {
                    _selectedDate = DateTime(year, i + 1);
                    _showDatePicker = false;
                    _expandedYear = null;
                  }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: isSelected
                  ? ZipherColors.cyan.withValues(alpha: 0.15)
                  : disabled
                      ? Colors.transparent
                      : Colors.white.withValues(alpha: 0.02),
              borderRadius: BorderRadius.circular(ZipherRadius.xs),
              border: Border.all(
                color: isSelected
                    ? ZipherColors.cyan.withValues(alpha: 0.4)
                    : disabled
                        ? Colors.transparent
                        : ZipherColors.borderSubtle,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              months[i],
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected
                    ? ZipherColors.cyan
                    : disabled
                        ? ZipherColors.text10
                        : ZipherColors.text60,
              ),
            ),
          ),
        );
      },
    );
  }

  String? _validateSeed(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your seed phrase';
    }
    final words = value.trim().split(RegExp(r'\s+'));
    if (![12, 15, 18, 21, 24].contains(words.length)) {
      return 'Seed phrase must be 12, 15, 18, 21, or 24 words';
    }
    return null;
  }

  Future<void> _restore() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      final seed = _seedController.text.trim();

      // Validate seed via Rust
      final isValid = await WalletService.instance.validateSeed(seed);
      if (!isValid) {
        setState(() {
          _error = 'Invalid seed phrase';
          _loading = false;
        });
        return;
      }

      // Estimate birthday height by anchoring to the actual chain tip.
      // Working backwards from "now" avoids drift from the 75s/block estimate
      // compounding over 7+ years since Sapling activation.
      const saplingHeight = 419200;
      int birthday = saplingHeight;
      if (_selectedDate != null) {
        try {
          final chainTip =
              await WalletService.instance.getLatestBlockHeight();
          final now = DateTime.now();
          final secondsAgo = now.difference(_selectedDate!).inSeconds;
          final blocksAgo = secondsAgo ~/ 75;
          birthday = chainTip - blocksAgo;
          if (birthday < saplingHeight) birthday = saplingHeight;
          print('[Restore] estimated birthday: chainTip=$chainTip - $blocksAgo blocks = $birthday');
        } catch (e) {
          // Fallback to the old forward-estimate if server is unreachable
          final saplingTime = DateTime(2018, 10, 29);
          final seconds = _selectedDate!.difference(saplingTime).inSeconds;
          birthday = saplingHeight + (seconds ~/ 75);
          print('[Restore] fallback birthday estimate: $birthday (server unreachable: $e)');
        }
      }

      final walletName = isTestnet ? 'Testnet Wallet' : 'Restored Wallet';
      print('[Restore] birthday=$birthday server=${WalletService.instance.serverUrl}');

      final ws = WalletService.instance;
      if (ws.isWalletOpen) {
        print('[Restore] pausing sync and closing current wallet...');
        syncStatus2.paused = true;
        await ws.closeWallet();
        print('[Restore] closed');
      }

      print('[Restore] calling restoreWallet...');
      await ws.restoreWallet(walletName, seed, birthday);
      print('[Restore] restoreWallet returned');

      aa = ActiveAccount2(
        coin: activeCoin.coin,
        id: 1,
        name: walletName,
        address: '',
        canPay: true,
      );

      final prefs = await SharedPreferences.getInstance();
      await aa.save(prefs);

      aa.reset(birthday);
      syncStatus2.resetForWalletSwitch();

      if (mounted) GoRouter.of(context).go('/account');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

