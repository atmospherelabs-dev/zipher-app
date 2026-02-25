import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/warp_api.dart';

import '../../appsettings.dart';
import '../../zipher_theme.dart';
import '../../accounts.dart';
import '../../generated/intl/messages.dart';
import '../utils.dart';
import '../widgets.dart';

class SweepPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _SweepState();
}

class _SweepState extends State<SweepPage>
    with WithLoadingAnimation<SweepPage> {
  late final s = S.of(context);
  final formKey = GlobalKey<FormBuilderState>();
  final seedController = TextEditingController();
  final privateKeyController = TextEditingController();
  final indexController = TextEditingController(text: '0');
  bool _useSeed = true;

  @override
  void dispose() {
    seedController.dispose();
    privateKeyController.dispose();
    indexController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'SWEEP',
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
      body: LoadingWrapper(
        loading,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: FormBuilder(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Info banner
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: ZipherColors.cyan.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: ZipherColors.cyan.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 16,
                          color: ZipherColors.cyan.withValues(alpha: 0.5)),
                      const Gap(10),
                      Expanded(
                        child: Text(
                          'Import transparent funds from a paper wallet or another seed into your shielded wallet. '
                          'Funds will be moved to your private (shielded) balance.',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                ZipherColors.cyan.withValues(alpha: 0.5),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const Gap(24),

                // Source toggle
                _sectionLabel('Import from'),
                const Gap(8),
                Row(
                  children: [
                    _sourceToggle('Seed Phrase', _useSeed,
                        () => setState(() => _useSeed = true)),
                    const Gap(8),
                    _sourceToggle('Private Key', !_useSeed,
                        () => setState(() => _useSeed = false)),
                  ],
                ),

                const Gap(16),

                // Seed input
                if (_useSeed) ...[
                  _sectionLabel('Seed Phrase'),
                  const Gap(8),
                  _inputBox(
                    name: 'seed',
                    controller: seedController,
                    hint: 'Enter the 24-word seed phrase...',
                    maxLines: 3,
                    validator: _validSeed,
                  ),
                  const Gap(12),
                  _sectionLabel('Account Index'),
                  const Gap(4),
                  Text(
                    'Which account to sweep from. Usually 0 (the first account).',
                    style: TextStyle(
                      fontSize: 11,
                      color: ZipherColors.text10,
                    ),
                  ),
                  const Gap(8),
                  SizedBox(
                    width: 100,
                    child: _inputBox(
                      name: 'index',
                      controller: indexController,
                      hint: '0',
                      keyboardType: TextInputType.number,
                      validator: FormBuilderValidators.compose([
                        FormBuilderValidators.required(),
                        FormBuilderValidators.integer(),
                      ]),
                    ),
                  ),
                ],

                // Private key input
                if (!_useSeed) ...[
                  _sectionLabel('Transparent Private Key'),
                  const Gap(8),
                  _inputBox(
                    name: 'sk',
                    controller: privateKeyController,
                    hint: 'Enter the transparent private key...',
                    maxLines: 2,
                    validator: _validTKey,
                  ),
                ],

                const Gap(32),

                // Sweep button
                InkWell(
                  onTap: _sweep,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: ZipherColors.cyan.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cleaning_services_outlined,
                            size: 18,
                            color: ZipherColors.cyan
                                .withValues(alpha: 0.8)),
                        const Gap(8),
                        Text(
                          'Sweep to Shielded Wallet',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: ZipherColors.cyan
                                .withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const Gap(40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: ZipherColors.text20,
      ),
    );
  }

  Widget _sourceToggle(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? ZipherColors.cyan.withValues(alpha: 0.12)
                : ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: selected
                ? Border.all(
                    color: ZipherColors.cyan.withValues(alpha: 0.2))
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? ZipherColors.cyan.withValues(alpha: 0.9)
                    : ZipherColors.text40,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputBox({
    required String name,
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.borderSubtle,
        borderRadius: BorderRadius.circular(14),
      ),
      child: FormBuilderTextField(
        name: name,
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator: validator,
        style: TextStyle(
          fontSize: 13,
          color: ZipherColors.text90,
          fontFamily: maxLines > 1 ? 'monospace' : null,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            fontSize: 13,
            color: ZipherColors.text10,
          ),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.all(16),
        ),
      ),
    );
  }

  void _sweep() async {
    final form = formKey.currentState!;
    if (!form.validate()) return;

    final seed = seedController.text;
    final sk = privateKeyController.text;

    if (_useSeed && seed.isEmpty) {
      form.fields['seed']!.invalidate(s.seedOrKeyRequired);
      return;
    }
    if (!_useSeed && sk.isEmpty) {
      form.fields['sk']!.invalidate(s.seedOrKeyRequired);
      return;
    }
    form.save();

    final latestHeight = await WarpApi.getLatestHeight(aa.coin);

    // Always sweep to shielded (pool 7 = best available shielded pool)
    const pool = 6; // Sapling + Orchard (shielded)

    if (_useSeed && seed.isNotEmpty) {
      load(() async {
        try {
          final txPlan = await WarpApi.sweepTransparentSeed(
              aa.coin,
              aa.id,
              latestHeight,
              seed,
              pool,
              '',
              int.parse(indexController.text),
              30,
              coinSettings.feeT);
          GoRouter.of(context)
              .push('/account/txplan?tab=more', extra: txPlan);
        } on String catch (e) {
          form.fields['seed']!.invalidate(e);
        }
      });
    }

    if (!_useSeed && sk.isNotEmpty) {
      await load(() async {
        try {
          final txPlan = await WarpApi.sweepTransparent(aa.coin, aa.id,
              latestHeight, sk, pool, '', coinSettings.feeT);
          GoRouter.of(context)
              .push('/account/txplan?tab=more', extra: txPlan);
        } on String catch (e) {
          form.fields['sk']!.invalidate(e);
        }
      });
    }
  }

  String? _validSeed(String? v) {
    if (v == null) return null;
    if (v.isNotEmpty && !WarpApi.validSeed(aa.coin, v)) return s.invalidKey;
    return null;
  }

  String? _validTKey(String? v) {
    if (v == null) return null;
    if (v.isNotEmpty && !WarpApi.isValidTransparentKey(v))
      return s.invalidKey;
    return null;
  }
}
