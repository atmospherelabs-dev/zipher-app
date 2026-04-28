import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'bip39_wordlist.dart';

/// Seed phrase restore — per-word grid with privacy masking, smart paste,
/// BIP39 autocomplete, and optional wallet birthday.
class RestoreAccountPage extends StatefulWidget {
  @override
  State<RestoreAccountPage> createState() => _RestoreAccountPageState();
}

class _RestoreAccountPageState extends State<RestoreAccountPage> {
  bool _loading = false;
  String? _error;
  bool _seedVisible = false;
  int _wordCount = 24;

  late List<TextEditingController> _controllers;
  late List<FocusNode> _focusNodes;
  Set<int> _invalidWords = {};
  int? _activeSuggestionIndex;
  List<String> _suggestions = [];

  DateTime? _selectedDate;
  bool _showDatePicker = false;
  int? _expandedYear;
  bool _showBlockInput = false;
  final _blockHeightController = TextEditingController();

  static final _sapling = activationDate;

  @override
  void initState() {
    super.initState();
    ScreenProtector.protectDataLeakageOn();
    _initControllers(_wordCount);
  }

  void _initControllers(int count) {
    _controllers = List.generate(count, (_) => TextEditingController());
    _focusNodes = List.generate(count, (_) => FocusNode());
    for (int i = 0; i < count; i++) {
      _focusNodes[i].addListener(() {
        if (_focusNodes[i].hasFocus) {
          _updateSuggestions(i);
        } else if (_activeSuggestionIndex == i) {
          // Delay clearing so tap on suggestion registers first
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted && _activeSuggestionIndex == i && !_focusNodes[i].hasFocus) {
              setState(() {
                _activeSuggestionIndex = null;
                _suggestions = [];
              });
            }
          });
        }
      });
    }
  }

  @override
  void dispose() {
    ScreenProtector.protectDataLeakageOff();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    _blockHeightController.dispose();
    super.dispose();
  }

  int get _filledCount =>
      _controllers.where((c) => c.text.trim().isNotEmpty).length;

  bool get _allFilled => _filledCount >= _wordCount;

  void _setWordCount(int count) {
    if (count == _wordCount) return;
    final oldWords = _controllers.map((c) => c.text).toList();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    _wordCount = count;
    _initControllers(count);
    for (int i = 0; i < count && i < oldWords.length; i++) {
      _controllers[i].text = oldWords[i];
    }
    _invalidWords = {};
    setState(() {});
  }

  void _handlePaste(int index, String value) {
    final words = value.trim().split(RegExp(r'[\s,]+'));
    if (words.length > 1) {
      // Multi-word paste: distribute across boxes
      if (words.length > _wordCount) {
        // Auto-detect word count from paste
        final validCounts = [12, 15, 18, 21, 24];
        final best = validCounts.firstWhere(
          (c) => c >= words.length,
          orElse: () => 24,
        );
        if (best != _wordCount) _setWordCount(best);
      }
      for (int i = 0; i < words.length && (index + i) < _wordCount; i++) {
        _controllers[index + i].text = words[i].toLowerCase();
      }
      // Focus the box after the last pasted word
      final nextFocus = (index + words.length).clamp(0, _wordCount - 1);
      _focusNodes[nextFocus].requestFocus();
      _validateAllWords();
      setState(() {});
    }
  }

  void _onWordChanged(int index, String value) {
    // Check for pasted multi-word content
    if (value.contains(' ') || value.contains(',')) {
      _handlePaste(index, value);
      return;
    }

    _updateSuggestions(index);

    // Clear invalid marker on edit
    if (_invalidWords.contains(index)) {
      setState(() => _invalidWords.remove(index));
    }
  }

  void _updateSuggestions(int index) {
    final text = _controllers[index].text.trim().toLowerCase();
    if (text.length < 2) {
      setState(() {
        _activeSuggestionIndex = index;
        _suggestions = [];
      });
      return;
    }
    final matches = bip39English
        .where((w) => w.startsWith(text))
        .take(5)
        .toList();
    // Don't show suggestions if the word already matches exactly
    if (matches.length == 1 && matches[0] == text) {
      setState(() {
        _activeSuggestionIndex = index;
        _suggestions = [];
      });
      return;
    }
    setState(() {
      _activeSuggestionIndex = index;
      _suggestions = matches;
    });
  }

  void _selectSuggestion(String word) {
    if (_activeSuggestionIndex == null) return;
    final idx = _activeSuggestionIndex!;
    _controllers[idx].text = word;
    _controllers[idx].selection = TextSelection.collapsed(offset: word.length);
    setState(() {
      _suggestions = [];
      _invalidWords.remove(idx);
    });
    // Auto-advance to next empty box
    for (int next = idx + 1; next < _wordCount; next++) {
      if (_controllers[next].text.trim().isEmpty) {
        _focusNodes[next].requestFocus();
        return;
      }
    }
    // All filled, unfocus
    FocusScope.of(context).unfocus();
  }

  void _validateAllWords() {
    final invalid = <int>{};
    for (int i = 0; i < _wordCount; i++) {
      final w = _controllers[i].text.trim().toLowerCase();
      if (w.isNotEmpty && !bip39English.contains(w)) {
        invalid.add(i);
      }
    }
    setState(() => _invalidWords = invalid);
  }

  @override
  Widget build(BuildContext context) {
    final showWords = _seedVisible && !_loading;

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
                          color: ZipherColors.text60, size: 22),
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
                    const Gap(24),

                    // Header row: Show/Hide + word count toggle
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => setState(() => _seedVisible = !_seedVisible),
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
                                _seedVisible ? 'Hide All' : 'Show All',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: ZipherColors.text40,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        _buildWordCountToggle(),
                      ],
                    ),
                    const Gap(12),

                    // Word grid
                    _buildWordGrid(showWords),

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

                    const Gap(20),

                    // Birthday section (unchanged year/month picker)
                    _buildBirthdaySection(),

                    const Gap(16),

                    // Info text
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(Icons.info_outline_rounded,
                              size: 14, color: ZipherColors.text20),
                        ),
                        const Gap(8),
                        Expanded(
                          child: Text(
                            _birthdayInfoText,
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
                        label: _restoreButtonLabel,
                        icon: Icons.download_done_rounded,
                        onPressed: _restore,
                        enabled: _allFilled,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _restoreButtonLabel {
    if (_blockHeightController.text.trim().isNotEmpty) {
      return 'Restore from block ${_blockHeightController.text.trim()}';
    }
    if (_selectedDate != null) {
      return 'Restore from ${DateFormat.yMMM().format(_selectedDate!)}';
    }
    return 'Restore (full scan)';
  }

  String get _birthdayInfoText {
    if (_blockHeightController.text.trim().isNotEmpty) {
      return 'Scanning from block ${_blockHeightController.text.trim()}. '
          'Transactions before this height won\'t appear.';
    }
    if (_selectedDate != null) {
      return 'Scanning from ${DateFormat.yMMM().format(_selectedDate!)}. '
          'Transactions before this date won\'t appear.';
    }
    return 'Full scan from chain activation. '
        'This is thorough but takes longer.';
  }

  // ── Word count toggle (12 | 24) ──────────────────────────────────────

  Widget _buildWordCountToggle() {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.sm),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _wordCountChip(12),
          _wordCountChip(24),
        ],
      ),
    );
  }

  Widget _wordCountChip(int count) {
    final selected = _wordCount == count;
    return GestureDetector(
      onTap: () => _setWordCount(count),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? ZipherColors.cyan.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(ZipherRadius.sm),
        ),
        child: Text(
          '$count',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? ZipherColors.cyan : ZipherColors.text40,
          ),
        ),
      ),
    );
  }

  // ── Word grid ────────────────────────────────────────────────────────

  Widget _buildWordGrid(bool showWords) {
    final rows = (_wordCount / 3).ceil();
    return Column(
      children: List.generate(rows, (row) {
        return Padding(
          padding: EdgeInsets.only(bottom: row < rows - 1 ? 8 : 0),
          child: Column(
            children: [
              Row(
                children: List.generate(3, (col) {
                  final idx = row * 3 + col;
                  if (idx >= _wordCount) return const Expanded(child: SizedBox());
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: col > 0 ? 6 : 0,
                        right: col < 2 ? 0 : 0,
                      ),
                      child: _buildWordBox(idx, showWords),
                    ),
                  );
                }),
              ),
              // Suggestion row: show below the row that contains the active box
              if (_activeSuggestionIndex != null &&
                  _activeSuggestionIndex! ~/ 3 == row &&
                  _suggestions.isNotEmpty)
                _buildSuggestionRow(),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildWordBox(int index, bool showWords) {
    final controller = _controllers[index];
    final focusNode = _focusNodes[index];
    final isInvalid = _invalidWords.contains(index);
    final hasText = controller.text.trim().isNotEmpty;

    return SizedBox(
      height: 42,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: !showWords && hasText,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: index < _wordCount - 1
            ? TextInputAction.next
            : TextInputAction.done,
        onChanged: (v) => _onWordChanged(index, v),
        onSubmitted: (_) {
          if (index < _wordCount - 1) {
            _focusNodes[index + 1].requestFocus();
          } else {
            FocusScope.of(context).unfocus();
            _validateAllWords();
          }
        },
        style: TextStyle(
          fontSize: 13,
          color: ZipherColors.text90,
          fontFamily: 'JetBrainsMono',
          letterSpacing: showWords ? 0 : 2,
        ),
        decoration: InputDecoration(
          prefixIcon: SizedBox(
            width: 28,
            child: Center(
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: ZipherColors.text20,
                ),
              ),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 28, maxWidth: 28),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          filled: true,
          fillColor: isInvalid
              ? ZipherColors.red.withValues(alpha: 0.06)
              : ZipherColors.cardBg,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ZipherRadius.sm),
            borderSide: BorderSide(
              color: isInvalid
                  ? ZipherColors.red.withValues(alpha: 0.4)
                  : ZipherColors.borderSubtle,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ZipherRadius.sm),
            borderSide: BorderSide(
              color: isInvalid
                  ? ZipherColors.red.withValues(alpha: 0.4)
                  : ZipherColors.borderSubtle,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ZipherRadius.sm),
            borderSide: BorderSide(
              color: isInvalid
                  ? ZipherColors.red.withValues(alpha: 0.5)
                  : ZipherColors.cyan.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestionRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _suggestions.map((word) {
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => _selectSuggestion(word),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: ZipherColors.cyan.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(ZipherRadius.sm),
                    border: Border.all(
                      color: ZipherColors.cyan.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Text(
                    word,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: ZipherColors.cyan,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ── Birthday section ─────────────────────────────────────────────────

  Widget _buildBirthdaySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date picker header
        GestureDetector(
          onTap: () => setState(() {
            _showDatePicker = !_showDatePicker;
            if (!_showDatePicker) _expandedYear = null;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: _selectedDate != null
                  ? ZipherColors.cyan.withValues(alpha: 0.04)
                  : ZipherColors.cardBg,
              borderRadius: BorderRadius.circular(ZipherRadius.md),
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
                            ? DateFormat.yMMM().format(_selectedDate!)
                            : 'Wallet birthday',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _selectedDate != null
                              ? ZipherColors.text90
                              : ZipherColors.text60,
                        ),
                      ),
                      if (_selectedDate == null &&
                          _blockHeightController.text.trim().isEmpty) ...[
                        const Gap(2),
                        Text(
                          'Optional \u2014 speeds up scanning',
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

        // Year/month grid
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

        const Gap(10),

        // "Or enter block height" toggle
        GestureDetector(
          onTap: () => setState(() {
            _showBlockInput = !_showBlockInput;
            if (!_showBlockInput) {
              _blockHeightController.clear();
            }
          }),
          child: Row(
            children: [
              Icon(
                Icons.tag_rounded,
                size: 14,
                color: _showBlockInput
                    ? ZipherColors.cyan.withValues(alpha: 0.6)
                    : ZipherColors.text20,
              ),
              const Gap(6),
              Text(
                'Or enter block height',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: _showBlockInput
                      ? ZipherColors.cyan.withValues(alpha: 0.7)
                      : ZipherColors.text40,
                ),
              ),
              const Gap(4),
              Icon(
                _showBlockInput
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: 16,
                color: ZipherColors.text20,
              ),
            ],
          ),
        ),

        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: _showBlockInput
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    height: 42,
                    child: TextField(
                      controller: _blockHeightController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      onChanged: (v) {
                        if (v.isNotEmpty && _selectedDate != null) {
                          setState(() {
                            _selectedDate = null;
                            _showDatePicker = false;
                            _expandedYear = null;
                          });
                        } else {
                          setState(() {});
                        }
                      },
                      style: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text90,
                        fontFamily: 'JetBrainsMono',
                      ),
                      decoration: InputDecoration(
                        hintText: 'e.g. 2500000',
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: ZipherColors.text20,
                        ),
                        filled: true,
                        fillColor: ZipherColors.cardBg,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(ZipherRadius.sm),
                          borderSide:
                              BorderSide(color: ZipherColors.borderSubtle),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(ZipherRadius.sm),
                          borderSide:
                              BorderSide(color: ZipherColors.borderSubtle),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(ZipherRadius.sm),
                          borderSide: BorderSide(
                            color: ZipherColors.cyan.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildYearMonthPicker() {
    final now = DateTime.now();
    final startYear = _sapling.year + 1;
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
        final isSelected =
            _selectedDate?.year == year && _selectedDate?.month == i + 1;

        return GestureDetector(
          onTap: disabled
              ? null
              : () => setState(() {
                    _selectedDate = DateTime(year, i + 1);
                    _showDatePicker = false;
                    _expandedYear = null;
                    // Clear block height if user picks a date
                    _blockHeightController.clear();
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

  // ── Restore action ───────────────────────────────────────────────────

  Future<void> _restore() async {
    setState(() => _error = null);

    // Validate all words against BIP39
    _validateAllWords();
    if (_invalidWords.isNotEmpty) {
      final nums = _invalidWords.map((i) => '#${i + 1}').join(', ');
      setState(() => _error = 'Invalid seed words: $nums');
      return;
    }

    final filledWords = _controllers
        .map((c) => c.text.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList();
    if (![12, 15, 18, 21, 24].contains(filledWords.length)) {
      setState(() =>
          _error = 'Seed phrase must be 12, 15, 18, 21, or 24 words');
      return;
    }

    setState(() => _loading = true);
    try {
      final seed = filledWords.join(' ');

      final isValid = await WalletService.instance.validateSeed(seed);
      if (!isValid) {
        setState(() {
          _error = 'Invalid seed phrase';
          _loading = false;
        });
        return;
      }

      const saplingHeight = 419200;
      int birthday = saplingHeight;

      // Block height takes priority over date
      final blockText = _blockHeightController.text.trim();
      if (blockText.isNotEmpty) {
        final parsed = int.tryParse(blockText);
        if (parsed != null && parsed >= saplingHeight) {
          birthday = parsed;
        } else if (parsed != null) {
          birthday = saplingHeight;
        }
        print('[Restore] using block height: $birthday');
      } else if (_selectedDate != null) {
        try {
          final chainTip =
              await WalletService.instance.getLatestBlockHeight();
          final now = DateTime.now();
          final secondsAgo = now.difference(_selectedDate!).inSeconds;
          final blocksAgo = secondsAgo ~/ 75;
          birthday = chainTip - blocksAgo;
          if (birthday < saplingHeight) birthday = saplingHeight;
          print(
              '[Restore] estimated birthday: chainTip=$chainTip - $blocksAgo blocks = $birthday');
        } catch (e) {
          final saplingTime = DateTime(2018, 10, 29);
          final seconds = _selectedDate!.difference(saplingTime).inSeconds;
          birthday = saplingHeight + (seconds ~/ 75);
          print(
              '[Restore] fallback birthday estimate: $birthday (server unreachable: $e)');
        }
      }

      final walletName = isTestnet ? 'Testnet Wallet' : 'Restored Wallet';
      print(
          '[Restore] birthday=$birthday server=${WalletService.instance.serverUrl}');

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

      if (mounted) {
        GoRouter.of(context).go('/account');
        Future.delayed(
            const Duration(milliseconds: 500), () => startAutoSync());
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
