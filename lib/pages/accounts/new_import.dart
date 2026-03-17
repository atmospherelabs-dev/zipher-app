import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../store2.dart';
import '../../zipher_theme.dart';
import '../utils.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../services/wallet_service.dart';

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
  bool _loading = false;
  bool _seedVisible = false;
  String? _error;
  DateTime? _birthdayDate;
  bool _showDatePicker = false;
  static final _saplingActivation = DateTime(2018, 10, 29);

  /// Whether we're creating a new wallet or importing from seed.
  bool get _isImport =>
      widget.seedInfo != null || _keyController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (widget.first) {
      _nameController.text = 'Main';
    }
    final si = widget.seedInfo;
    if (si != null) {
      _keyController.text = si.seed;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return wrapWithLoading(Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          widget.first ? 'CREATE ACCOUNT' : 'ADD ACCOUNT',
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
                  color: ZipherColors.cyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(ZipherRadius.xl),
                  border: Border.all(
                    color: ZipherColors.cyan.withValues(alpha: 0.08),
                  ),
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: 28,
                  color: ZipherColors.cyan.withValues(alpha: 0.6),
                ),
              ),
            ),
            const Gap(16),

            Center(
              child: Text(
                'Create a new account with a fresh seed phrase',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: ZipherColors.text40,
                ),
              ),
            ),
            const Gap(28),

            // Account name
            _label('Account Name'),
            const Gap(8),
            _inputField(
              controller: _nameController,
              hint: 'e.g. Main, Savings, Trading...',
              icon: Icons.person_outline_rounded,
            ),
            const Gap(20),

            // Error
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: ZipherColors.red.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(ZipherRadius.md),
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
                    color: ZipherColors.cyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(ZipherRadius.lg),
                    border: Border.all(
                      color: ZipherColors.cyan.withValues(alpha: 0.10),
                    ),
                  ),
                  child: Center(
                    child: _loading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: ZipherColors.cyan,
                            ),
                          )
                        : Text(
                            'Create Account',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: ZipherColors.cyan,
                            ),
                          ),
                  ),
                ),
              ),
            ),

            const Gap(40),
          ],
        ),
      ),
    ));
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
          borderRadius: BorderRadius.circular(ZipherRadius.md),
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
              color: ZipherColors.text40,
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

  void _onSubmit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter an account name');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    await load(() async {
      final wallet = WalletService.instance;

      // Close any open wallet first (when adding a new account)
      if (!widget.first && wallet.isWalletOpen) {
        await wallet.closeWallet();
      }

      await wallet.createNewWallet(name);

      aa = ActiveAccount2(
        coin: activeCoin.coin,
        id: 1,
        name: name,
        address: '',
        canPay: true,
      );

      final prefs = await SharedPreferences.getInstance();
      await aa.save(prefs);
      await aa.updateAddress();

      aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
      syncStatus2.resetForWalletSwitch();

      if (widget.first) {
        GoRouter.of(context).go('/account');
      } else {
        GoRouter.of(context).pop();
      }
    });

    if (mounted) setState(() => _loading = false);
  }
}
