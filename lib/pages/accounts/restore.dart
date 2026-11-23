import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:screen_protector/screen_protector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../services/app_log.dart';
import '../../services/backup_status.dart';
import '../../services/wallet_service.dart';
import '../../services/restore_birthday.dart';
import '../../services/restore_checkpoints.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import 'bip39_wordlist.dart';

/// Seed phrase restore — per-word grid with privacy masking, smart paste,
/// BIP39 autocomplete, and optional wallet birthday.
class RestoreAccountPage extends StatefulWidget {
  RestoreAccountPage({super.key, @visibleForTesting this.initialStep = 0});

  /// Tests and screenshots can open the date step directly; the app always
  /// starts at the phrase, which must validate before the date step.
  final int initialStep;

  @override
  State<RestoreAccountPage> createState() => _RestoreAccountPageState();
}

class _RestoreAccountPageState extends State<RestoreAccountPage> {
  bool _loading = false;

  /// 0: recovery phrase, 1: when the wallet was first used.
  late int _step = widget.initialStep;
  String? _error;
  bool _seedVisible = false;
  int _wordCount = 24;

  late List<TextEditingController> _controllers;
  late List<FocusNode> _focusNodes;
  Set<int> _invalidWords = {};
  int? _activeSuggestionIndex;
  List<String> _suggestions = [];

  DateTime? _selectedDate;
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
            if (mounted &&
                _activeSuggestionIndex == i &&
                !_focusNodes[i].hasFocus) {
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
    final matches =
        bip39English.where((w) => w.startsWith(text)).take(5).toList();
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

    return PopScope(
      canPop: _step == 0 && !_loading,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step == 1 && !_loading) setState(() => _step = 0);
      },
      child: Scaffold(
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
                      const Gap(8),
                      IconButton(
                        tooltip: 'Back',
                        onPressed: _loading
                            ? null
                            : () => _step == 1
                                ? setState(() => _step = 0)
                                : GoRouter.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            color: ZipherColors.text90, size: 20),
                      ),
                      const Gap(12),
                      if (_step == 0) ..._phraseStep(showWords),
                      if (_step == 1) ..._dateStep(),
                      if (_error != null) ...[
                        const Gap(10),
                        Text(
                          _error!,
                          style: ZipherType.footnote
                              .copyWith(color: ZipherColors.negative),
                        ),
                      ],
                      const Gap(24),
                    ],
                  ),
                ),
              ),
              ZipherWidgets.bottomActions([
                _step == 0
                    ? ZipherButton(
                        label: 'Continue',
                        onPressed: _allFilled ? _continue : null,
                        loading: _loading,
                      )
                    : ZipherButton(
                        label: 'Restore',
                        onPressed: _restore,
                        loading: _loading,
                      ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _phraseStep(bool showWords) => [
        const Text('Enter your recovery phrase', style: ZipherType.largeTitle),
        const Gap(8),
        const Text('The 12 or 24 words you wrote down for this wallet.',
            style: ZipherType.subhead),
        const Gap(20),
        Row(
          children: [
            ZipherButton(
              label: 'Paste',
              icon: Icons.content_paste_rounded,
              kind: ZipherButtonKind.secondary,
              size: ZipherButtonSize.small,
              onPressed: _pasteFromClipboard,
            ),
            const Gap(8),
            ZipherButton(
              label: _seedVisible ? 'Hide' : 'Show',
              icon: _seedVisible
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              kind: ZipherButtonKind.plain,
              size: ZipherButtonSize.small,
              color: ZipherColors.text60,
              onPressed: () => setState(() => _seedVisible = !_seedVisible),
            ),
            const Spacer(),
            _buildWordCountToggle(),
          ],
        ),
        const Gap(12),
        _buildWordGrid(showWords),
      ];

  List<Widget> _dateStep() => [
        const Text('When did you start using it?',
            style: ZipherType.largeTitle),
        const Gap(8),
        const Text(
            'Roughly is fine; it only makes the first sync faster. If in doubt, pick an earlier year or Not sure.',
            style: ZipherType.subhead),
        const Gap(20),
        _buildBirthdaySection(),
      ];

  /// Check the phrase before asking about dates, so a typo is fixed here.
  Future<void> _continue() async {
    setState(() => _error = null);
    _validateAllWords();
    if (_invalidWords.isNotEmpty) {
      final nums = _invalidWords.map((i) => '#${i + 1}').join(', ');
      setState(() => _error = 'Check word $nums: it isn’t a recovery word.');
      return;
    }
    final words = _controllers
        .map((c) => c.text.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList();
    if (![12, 15, 18, 21, 24].contains(words.length)) {
      setState(() => _error = 'A recovery phrase has 12 or 24 words.');
      return;
    }
    setState(() => _loading = true);
    try {
      final valid = await WalletService.instance.validateSeed(words.join(' '));
      if (!mounted) return;
      setState(() {
        if (valid) {
          _step = 1;
          FocusScope.of(context).unfocus();
        } else {
          _error =
              'These words don’t form a valid recovery phrase. Check their order and spelling.';
        }
      });
    } catch (e) {
      AppLog.instance.event('restore', 'validate_failed', error: e);
      if (mounted) setState(() => _error = restoreErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Paste the whole phrase at once; the word count is detected.
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    final words = text.split(RegExp(r'[\s,]+'));
    if (words.length == 12 || words.length == 24) _setWordCount(words.length);
    _handlePaste(0, text);
    // Don't leave the phrase on the clipboard for other apps.
    await Clipboard.setData(const ClipboardData(text: ''));
  }

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// Where the scan will start, in words.
  String get _startSummary {
    final height = _blockHeightController.text.trim();
    if (height.isNotEmpty) {
      return 'Starts after block $height. Payments before it won’t be found.';
    }
    final date = _selectedDate;
    if (date == null ||
        isTestnet ||
        restoreAnchorForDate(date, testnet: isTestnet) == null) {
      return isTestnet && date != null
          ? 'On testnet, dates can’t shorten the scan, so it covers everything. Enter a block height to go faster.'
          : 'Scans everything since 2018. Slower, but finds every payment.';
    }
    var year = date.year;
    var month = date.month - 1;
    if (month == 0) {
      month = 12;
      year -= 1;
    }
    return 'Starts from ${_monthNames[month - 1]} $year, a month early to be safe.';
  } // ── Word count toggle (12 | 24) ──────────────────────────────────────

  Widget _buildWordCountToggle() {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.sm),
        border: Border.all(color: ZipherColors.borderSubtle, width: 0.5),
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
                  if (idx >= _wordCount)
                    return const Expanded(child: SizedBox());
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
          prefixIconConstraints:
              const BoxConstraints(minWidth: 28, maxWidth: 28),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

  // ── Step header ──────────────────────────────────────────────────────
  // Compact "1 · Wallet birthday" / "2 · Seed phrase" header so the two
  // import inputs read as a numbered checklist instead of a scroll soup.
  Widget _buildBirthdaySection() {
    final now = DateTime.now();
    final years = [
      for (int y = now.year; y >= _sapling.year; y--) y,
    ];
    final picking = _selectedDate != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _choiceChip(
              label: 'Not sure',
              selected: !picking && _blockHeightController.text.isEmpty,
              onTap: () => setState(() {
                _selectedDate = null;
                _expandedYear = null;
                _blockHeightController.clear();
                _showBlockInput = false;
              }),
            ),
            for (final year in years)
              _choiceChip(
                label: '$year',
                selected: _selectedDate?.year == year,
                onTap: () => setState(() {
                  // A year alone means January; the month row can narrow it.
                  _selectedDate = DateTime(year);
                  _expandedYear = year;
                  _blockHeightController.clear();
                  _showBlockInput = false;
                }),
              ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: _expandedYear != null
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Remember the month? (optional)',
                          style: ZipherType.footnote),
                      const Gap(8),
                      _buildMonthGrid(_expandedYear!, now),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const Gap(12),
        Text(_startSummary, style: ZipherType.footnote),
        const Gap(4),
        Wrap(spacing: 4, children: [
          ZipherButton(
            label: 'Pick an exact date',
            kind: ZipherButtonKind.plain,
            size: ZipherButtonSize.small,
            onPressed: _pickExactDate,
          ),
          ZipherButton(
            label: _showBlockInput ? 'Hide block height' : 'Use a block height',
            kind: ZipherButtonKind.plain,
            size: ZipherButtonSize.small,
            color: ZipherColors.text60,
            onPressed: () => setState(() {
              _showBlockInput = !_showBlockInput;
              if (!_showBlockInput) _blockHeightController.clear();
            }),
          ),
        ]),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: _showBlockInput
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _blockHeightController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (v) => setState(() {
                      if (v.isNotEmpty) {
                        _selectedDate = null;
                        _expandedYear = null;
                      }
                    }),
                    style: ZipherType.body,
                    decoration: const InputDecoration(
                      hintText: 'Block height, e.g. 2500000',
                      isDense: true,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Future<void> _pickExactDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: _sapling,
      lastDate: now,
      helpText: 'When did you start using this wallet?',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedDate = picked;
      _expandedYear = picked.year;
      _blockHeightController.clear();
      _showBlockInput = false;
    });
  }

  Widget _choiceChip(
          {required String label,
          required bool selected,
          required VoidCallback onTap}) =>
      Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? ZipherColors.cyan.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(ZipherRadius.full),
              border: Border.all(
                color: selected
                    ? ZipherColors.cyan.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.12),
                width: 0.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: selected ? ZipherColors.cyan : ZipherColors.text90,
              ),
            ),
          ),
        ),
      );

  Widget _buildMonthGrid(int year, DateTime now) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
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
                    _blockHeightController.clear();
                    _showBlockInput = false;
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
      setState(
          () => _error = 'Seed phrase must be 12, 15, 18, 21, or 24 words');
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

      final birthday = restoreBirthdayFromInput(
        blockHeight: _blockHeightController.text,
        selectedDate: _selectedDate,
        testnet: isTestnet,
      );

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
      // The user already had the phrase; no backup reminder for this wallet.
      await BackupStatus.instance.markBackedUp(ws.activeWalletId);

      aa = ActiveAccount2(
        coin: activeCoin.coin,
        id: 1,
        name: walletName,
        address: '',
        canPay: true,
        walletId: ws.activeWalletId ?? '',
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
      // Raw engine errors carry server metadata; keep them in the debug log.
      AppLog.instance.event('restore', 'failed', error: e);
      if (mounted) setState(() => _error = restoreErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

/// A sentence for the user when a restore can't start.
String restoreErrorMessage(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('invalid seed') || text.contains('mnemonic')) {
    return 'That recovery phrase isn’t valid. Check each word and try again.';
  }
  if (text.contains('tor')) {
    return 'Couldn’t connect over Tor. Try again, or turn Tor off in Wallet status.';
  }
  if (text.contains('get_tree_state') ||
      text.contains('get_block') ||
      text.contains('get_latest_block') ||
      text.contains('transport') ||
      text.contains('connect') ||
      text.contains('unavailable') ||
      text.contains('timed out')) {
    return 'Couldn’t get what’s needed from the Zcash server to start the restore. '
        'Try again, or choose another server in Preferences.';
  }
  return 'The restore didn’t start. Try again.';
}
