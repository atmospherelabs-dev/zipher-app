import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../services/secure_key_store.dart';
import '../../store2.dart';
import '../../zipher_theme.dart';
import '../utils.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../pages/widgets.dart';

// Mode for the add account page
enum _Mode { create, import_, derive }

class NewImportAccountPage extends StatefulWidget {
  final bool first;
  final SeedInfo? seedInfo;
  NewImportAccountPage({required this.first, this.seedInfo});

  @override
  State<StatefulWidget> createState() => _NewImportAccountState();
}

class _NewImportAccountState extends State<NewImportAccountPage>
    with WithLoadingAnimation {
  late final s = S.of(context);
  int coin = activeCoin.coin;
  final _nameController = TextEditingController();
  final _keyController = TextEditingController();
  final _indexController = TextEditingController(text: '0');
  _Mode _mode = _Mode.create;
  bool _loading = false;
  String? _error;
  DateTime? _birthdayDate;
  bool _showDatePicker = false;
  static final _saplingActivation = DateTime(2018, 10, 29);

  // For derive mode
  String? _parentSeed;
  int _nextIndex = 1;
  String? _parentName;

  @override
  void initState() {
    super.initState();
    if (widget.first) {
      _nameController.text = 'Main';
    }
    final si = widget.seedInfo;
    if (si != null) {
      _mode = _Mode.import_;
      _keyController.text = si.seed;
      _indexController.text = si.index.toString();
    }
    _loadParentSeed();
  }

  void _loadParentSeed() async {
    try {
      final backup = WarpApi.getBackup(aa.coin, aa.id);
      // Check Keychain first, then DB fallback
      final kcSeed = await SecureKeyStore.getSeed(aa.coin, aa.id);
      final seedValue = kcSeed ?? backup.seed;
      if (seedValue != null && seedValue.isNotEmpty) {
        _parentSeed = seedValue;
        _parentName = backup.name ?? 'Main';
        // Find the next available index
        final accounts = getAllAccounts();
        int maxIdx = 0;
        for (final a in accounts) {
          try {
            final b = WarpApi.getBackup(a.coin, a.id);
            final aSeed = await SecureKeyStore.getSeed(a.coin, a.id) ?? b.seed;
            if (aSeed == _parentSeed && b.index >= maxIdx) {
              maxIdx = b.index + 1;
            }
          } catch (_) {}
        }
        _nextIndex = maxIdx;
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameController.dispose();
    _keyController.dispose();
    _indexController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canDerive = _parentSeed != null && !widget.first;

    return wrapWithLoading(Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          widget.first ? 'CREATE WALLET' : 'ADD ACCOUNT',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
        leading: widget.first
            ? null
            : IconButton(
                icon: Icon(Icons.arrow_back_rounded,
                    color: ZipherColors.text60),
                onPressed: () => Navigator.of(context).pop(),
              ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Gap(12),

            // Hero icon
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: _modeColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _modeColor.withValues(alpha: 0.08),
                  ),
                ),
                child: Icon(
                  _modeIcon,
                  size: 28,
                  color: _modeColor.withValues(alpha: 0.6),
                ),
              ),
            ),
            const Gap(16),

            Center(
              child: Text(
                _modeSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: ZipherColors.text40,
                ),
              ),
            ),
            const Gap(28),

            // Mode toggle
            if (!widget.first) ...[
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: ZipherColors.borderSubtle,
                  ),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    _buildTab('New', _mode == _Mode.create, () {
                      setState(() {
                        _mode = _Mode.create;
                        _error = null;
                      });
                    }),
                    _buildTab('Import', _mode == _Mode.import_, () {
                      setState(() {
                        _mode = _Mode.import_;
                        _error = null;
                      });
                    }),
                    if (canDerive)
                      _buildTab('Derive', _mode == _Mode.derive, () {
                        setState(() {
                          _mode = _Mode.derive;
                          _error = null;
                          _nameController.text = 'Account $_nextIndex';
                        });
                      }),
                  ],
                ),
              ),
              const Gap(24),
            ],

            // ── Account name (all modes) ──
            _label('Account Name'),
            const Gap(8),
            _inputField(
              controller: _nameController,
              hint: 'e.g. Main, Savings, Trading...',
              icon: Icons.person_outline_rounded,
            ),
            const Gap(20),

            // ── Import fields ──
            if (_mode == _Mode.import_) ...[
              _label('Seed Phrase'),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: ZipherColors.borderSubtle,
                  ),
                ),
                child: TextField(
                  controller: _keyController,
                  maxLines: 4,
                  style: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text90,
                    height: 1.5,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter your 24-word seed phrase...',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: ZipherColors.text20,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.all(14),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 4, top: 4),
                      child: Align(
                        alignment: Alignment.topRight,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: IconButton(
                          icon: Icon(
                            Icons.qr_code_scanner_rounded,
                            size: 20,
                            color: ZipherColors.text20,
                          ),
                          onPressed: () async {
                            final result = await GoRouter.of(context)
                                .push<String>('/account/scan');
                            if (result != null) {
                              setState(() => _keyController.text = result);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const Gap(16),

              // Account index
              _label('Account Index'),
              const Gap(4),
              Text(
                'Usually 0. Only change if you know what this is.',
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text20,
                ),
              ),
              const Gap(8),
              _inputField(
                controller: _indexController,
                hint: '0',
                icon: Icons.tag_rounded,
                keyboardType: TextInputType.number,
                width: 120,
              ),
              const Gap(20),

              // Wallet birthday
              _label('Wallet Birthday'),
              const Gap(4),
              Text(
                'When was this wallet created? Helps speed up the scan.',
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text20,
                ),
              ),
              const Gap(8),
              _buildBirthdayPicker(),
              const Gap(20),
            ],

            // ── Derive info ──
            if (_mode == _Mode.derive) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: ZipherColors.purple.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: ZipherColors.purple.withValues(alpha: 0.08),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.account_tree_rounded,
                            size: 15,
                            color: ZipherColors.purple
                                .withValues(alpha: 0.5)),
                        const Gap(8),
                        Text(
                          'Deriving from "$_parentName"',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: ZipherColors.text60,
                          ),
                        ),
                      ],
                    ),
                    const Gap(8),
                    Text(
                      'This creates a new account using the same seed phrase '
                      'at index $_nextIndex. It will have its own addresses '
                      'and balance, but shares the same recovery phrase.',
                      style: TextStyle(
                        fontSize: 11,
                        color: ZipherColors.text20,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(20),
            ],

            // Error
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: ZipherColors.red.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: ZipherColors.red.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 16,
                        color: ZipherColors.red.withValues(alpha: 0.6)),
                    const Gap(10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: ZipherColors.red.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(16),
            ],

            // Submit button
            const Gap(8),
            SizedBox(
              width: double.infinity,
              child: GestureDetector(
                onTap: _loading ? null : _onSubmit,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: _modeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _modeColor.withValues(alpha: 0.10),
                    ),
                  ),
                  child: Center(
                    child: _loading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _modeColor,
                            ),
                          )
                        : Text(
                            _buttonLabel,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: _modeColor,
                            ),
                          ),
                  ),
                ),
              ),
            ),

            if (_mode == _Mode.import_) ...[
              const Gap(12),
              Center(
                child: Text(
                  _birthdayDate != null
                      ? 'Will scan from ${DateFormat('MMM y').format(_birthdayDate!)}'
                      : 'Will do a full scan from 2018 (slower)',
                  style: TextStyle(
                    fontSize: 11,
                    color: ZipherColors.text20,
                  ),
                ),
              ),
            ],

            const Gap(40),
          ],
        ),
      ),
    ));
  }

  // ── Mode helpers ──

  Color get _modeColor {
    switch (_mode) {
      case _Mode.create:
        return ZipherColors.cyan;
      case _Mode.import_:
        return ZipherColors.cyan;
      case _Mode.derive:
        return ZipherColors.purple;
    }
  }

  IconData get _modeIcon {
    switch (_mode) {
      case _Mode.create:
        return Icons.add_rounded;
      case _Mode.import_:
        return Icons.download_rounded;
      case _Mode.derive:
        return Icons.account_tree_rounded;
    }
  }

  String get _modeSubtitle {
    switch (_mode) {
      case _Mode.create:
        return 'Create a new wallet with a fresh seed phrase';
      case _Mode.import_:
        return 'Import an existing wallet with your seed phrase';
      case _Mode.derive:
        return 'Derive a new account from your current seed';
    }
  }

  String get _buttonLabel {
    switch (_mode) {
      case _Mode.create:
        return 'Create Wallet';
      case _Mode.import_:
        return 'Import & Scan';
      case _Mode.derive:
        return 'Derive Account';
    }
  }

  // ── Widgets ──

  Widget _buildTab(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active
                ? ZipherColors.cardBgElevated
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active
                    ? ZipherColors.text90
                    : ZipherColors.text40,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: ZipherColors.text40,
      ),
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    double? width,
  }) {
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: ZipherColors.borderSubtle,
          ),
        ),
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          style: TextStyle(
            fontSize: 14,
            color: ZipherColors.text90,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 13,
              color: ZipherColors.text20,
            ),
            prefixIcon: Icon(
              icon,
              size: 18,
              color: ZipherColors.text20,
            ),
            filled: false,
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildBirthdayPicker() {
    return Column(
      children: [
        GestureDetector(
          onTap: () => setState(() => _showDatePicker = !_showDatePicker),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: ZipherColors.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: ZipherColors.borderSubtle,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today_rounded,
                    size: 16,
                    color: ZipherColors.text20),
                const Gap(10),
                Text(
                  _birthdayDate != null
                      ? DateFormat('MMMM d, y').format(_birthdayDate!)
                      : "I don't know (full scan)",
                  style: TextStyle(
                    fontSize: 13,
                    color: _birthdayDate != null
                        ? ZipherColors.text90
                        : ZipherColors.text20,
                  ),
                ),
                const Spacer(),
                if (_birthdayDate != null)
                  GestureDetector(
                    onTap: () => setState(() => _birthdayDate = null),
                    child: Icon(Icons.close_rounded,
                        size: 16,
                        color: ZipherColors.text20),
                  )
                else
                  Icon(
                    _showDatePicker
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: ZipherColors.text20,
                  ),
              ],
            ),
          ),
        ),
        if (_showDatePicker) ...[
          const Gap(8),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (int y = 2018; y <= DateTime.now().year; y++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _birthdayDate = DateTime(y, 1, 1)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: _birthdayDate?.year == y
                              ? ZipherColors.cyan.withValues(alpha: 0.12)
                              : ZipherColors.cardBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _birthdayDate?.year == y
                                ? ZipherColors.cyan
                                    .withValues(alpha: 0.10)
                                : ZipherColors.borderSubtle,
                          ),
                        ),
                        child: Text(
                          '$y',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _birthdayDate?.year == y
                                ? ZipherColors.cyan
                                : ZipherColors.text40,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Gap(8),
          Container(
            decoration: BoxDecoration(
              color: ZipherColors.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: ZipherColors.cardBg,
              ),
            ),
            child: Theme(
              data: ThemeData.dark().copyWith(
                colorScheme: ColorScheme.dark(
                  primary: ZipherColors.cyan,
                  onPrimary: Colors.white,
                  surface: ZipherColors.surface,
                  onSurface: ZipherColors.text90,
                ),
              ),
              child: CalendarDatePicker(
                initialDate: _birthdayDate ??
                    DateTime.now().subtract(const Duration(days: 30)),
                firstDate: _saplingActivation,
                lastDate: DateTime.now(),
                onDateChanged: (d) => setState(() => _birthdayDate = d),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Submit ──

  void _onSubmit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter an account name');
      return;
    }

    if (_mode == _Mode.import_) {
      final key = _keyController.text.trim();
      if (key.isEmpty) {
        setState(() => _error = 'Please enter your seed phrase');
        return;
      }
      if (WarpApi.isValidTransparentKey(key)) {
        setState(() => _error = s.cannotUseTKey);
        return;
      }
      final keyType = WarpApi.validKey(coin, key);
      if (keyType < 0) {
        setState(() => _error = s.invalidKey);
        return;
      }
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    await load(() async {
      String key = '';
      int index = 0;

      switch (_mode) {
        case _Mode.create:
          key = '';
          index = 0;
          break;
        case _Mode.import_:
          key = _keyController.text.trim();
          index = int.tryParse(_indexController.text) ?? 0;
          break;
        case _Mode.derive:
          key = _parentSeed!;
          index = _nextIndex;
          break;
      }

      final account = await WarpApi.newAccount(coin, name, key, index);

      if (account < 0) {
        setState(() {
          _error = s.thisAccountAlreadyExists;
          _loading = false;
        });
        return;
      }

      // Move seed from DB to Keychain (only if it has one)
      final backup = WarpApi.getBackup(coin, account);
      if (backup.seed != null) {
        await SecureKeyStore.storeSeed(
            coin, account, backup.seed!, backup.index);
        WarpApi.loadKeysFromSeed(
            coin, account, backup.seed!, backup.index);
        WarpApi.clearAccountSecrets(coin, account);
      }
      setActiveAccount(coin, account,
          canPayOverride: backup.seed != null ? true : null);
      final prefs = await SharedPreferences.getInstance();
      await aa.save(prefs);
      final count = WarpApi.countAccounts(coin);

      if (count == 1) {
        await WarpApi.skipToLastHeight(coin);
      }

      // Save wallet birthday
      if (_mode == _Mode.create || _mode == _Mode.derive) {
        // For new/derive: birthday is now (current block height)
        try {
          final h = WarpApi.getDbHeight(coin);
          await prefs.setInt('birthday_${coin}_$account', h.height);
        } catch (_) {}
      } else if (_mode == _Mode.import_) {
        // For import: determine scan height from birthday
        int scanHeight;
        if (_birthdayDate != null) {
          scanHeight =
              await WarpApi.getBlockHeightByTime(coin, _birthdayDate!);
          await prefs.setInt('birthday_${coin}_$account', scanHeight);
        } else {
          scanHeight = 419200;
          await prefs.setInt('birthday_${coin}_$account', scanHeight);
        }
        aa.reset(scanHeight);
        Future(() => syncStatus2.rescan(scanHeight));
      }

      if (widget.first) {
        GoRouter.of(context).go('/account');
      } else {
        GoRouter.of(context).pop();
      }
    });

    if (mounted) setState(() => _loading = false);
  }
}
