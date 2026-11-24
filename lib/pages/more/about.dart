import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../accounts.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_registry.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';

import '../../zipher_theme.dart';
import '../../src/version.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../utils.dart';

/// About Zipher: who makes it, which build this is, and where to read more.
/// Short on purpose; the detail lives behind the links.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const _repo = 'https://github.com/atmospherelabs-dev/zipher-app';

  /// '1.16.0+749' → ('1.16.0', '749').
  static (String, String?) get _version {
    final parts = packageVersion.split('+');
    return (parts.first, parts.length > 1 ? parts[1] : null);
  }

  @override
  Widget build(BuildContext context) {
    final (name, build) = _version;
    final commit = commitId.length > 7 ? commitId.substring(0, 7) : commitId;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Stack(
        children: [
          const ZipherTopGlow(height: 340),
          Column(
            children: [
              ZipherWidgets.pageHeader(context, 'About'),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      ZipherColors.pagePadding,
                      ZipherSpacing.sm,
                      ZipherColors.pagePadding,
                      MediaQuery.paddingOf(context).bottom + ZipherSpacing.lg),
                  children: [
                    // ── Identity ──
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.asset('assets/zipher_logo.png',
                            width: 76, height: 76, semanticLabel: 'Zipher'),
                      ),
                    ),
                    const Gap(ZipherSpacing.md),
                    const Text('Zipher',
                        textAlign: TextAlign.center,
                        style: ZipherType.largeTitle),
                    const Gap(ZipherSpacing.xs),
                    const Text('Private Zcash, for humans and agents.',
                        textAlign: TextAlign.center, style: ZipherType.subhead),
                    const Gap(ZipherSpacing.md),
                    Center(
                      child: _VersionPill(
                        label: build == null
                            ? 'Version $name · $commit'
                            : 'Version $name ($build) · $commit',
                        onTap: () => _open('$_repo/commit/$commitId'),
                      ),
                    ),
                    const Gap(ZipherSpacing.lg),

                    // ── What it stands for, one line each ──
                    ZipherWidgets.group([
                      for (final (icon, title, detail) in const [
                        (
                          Icons.visibility_off_rounded,
                          'No tracking',
                          'No accounts, no analytics, no servers of ours.'
                        ),
                        (
                          Icons.key_rounded,
                          'Your keys',
                          'Only your recovery phrase can restore this wallet.'
                        ),
                        (
                          Icons.code_rounded,
                          'Open source',
                          'Every line is public. Read it, build it, verify it.'
                        ),
                      ])
                        ZipherWidgets.row(
                          icon: icon,
                          iconColor: ZipherColors.cyan,
                          title: title,
                          subtitle: detail,
                        ),
                    ]),
                    const Gap(ZipherSpacing.lg),

                    // ── Links ──
                    ZipherWidgets.sectionLabel('Links'),
                    const Gap(ZipherSpacing.sm),
                    ZipherWidgets.group([
                      _link(Icons.language_rounded, 'Website', 'zipher.to',
                          () => _open('https://zipher.to')),
                      _link(Icons.code_rounded, 'Source code', 'GitHub',
                          () => _open(_repo)),
                      _link(
                          Icons.travel_explore_rounded,
                          'ZecBlock',
                          'Zcash explorer',
                          () => _open('https://zecblock.com')),
                      _link(
                          Icons.blur_on_rounded,
                          'Atmosphere Labs',
                          'atmospherelabs.dev',
                          () => _open('https://atmospherelabs.dev')),
                    ]),
                    const Gap(ZipherSpacing.lg),

                    ZipherWidgets.sectionLabel('Legal'),
                    const Gap(ZipherSpacing.sm),
                    ZipherWidgets.group([
                      _link(Icons.shield_outlined, 'Privacy policy', null,
                          () => _open('https://zipher.to/privacy')),
                      ZipherWidgets.row(
                        icon: Icons.description_outlined,
                        title: 'Terms of use',
                        onTap: () => showTermsSheet(context),
                      ),
                    ]),
                    const Gap(ZipherSpacing.lg),

                    // ── Disclaimer ──
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: ZipherSpacing.sm),
                      child: Text(
                        'Zipher is provided as is, without warranty of any '
                        'kind. Its authors are not liable for damages '
                        'arising from its use.',
                        textAlign: TextAlign.center,
                        style: ZipherType.caption,
                      ),
                    ),
                    const Gap(ZipherSpacing.sm),
                    Text(
                      '© ${DateTime.now().year} Atmosphere Labs',
                      textAlign: TextAlign.center,
                      style: ZipherType.caption
                          .copyWith(color: ZipherColors.text20),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static void _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// An outbound link: the arrow says it leaves the app.
  static Widget _link(
          IconData icon, String title, String? detail, VoidCallback onTap) =>
      ZipherWidgets.row(
        icon: icon,
        title: title,
        subtitle: detail,
        onTap: onTap,
        chevron: false,
        trailing: const Icon(Icons.north_east_rounded,
            size: 16, color: ZipherColors.text20),
      );
}

/// Build and commit in a frosted capsule; opens the commit on GitHub.
class _VersionPill extends StatelessWidget {
  const _VersionPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '$label. Opens the commit on GitHub',
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onTap,
          child: ZipherGlass.blur(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: ZipherSpacing.smMd, vertical: 6),
              decoration: ZipherGlass.decoration(),
              child: Text(label,
                  style:
                      ZipherType.caption.copyWith(color: ZipherColors.text60)),
            ),
          ),
        ),
      );
}

/// The terms, in a sheet. Shared by About and the first-run disclaimer.
void showTermsSheet(BuildContext context) {
  final s = S.of(context);
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: ZipherColors.surface,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            ZipherSpacing.lg, 0, ZipherSpacing.lg, ZipherSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Terms', style: ZipherType.title),
            const Gap(ZipherSpacing.md),
            for (final line in [
              s.disclaimer_1,
              s.disclaimer_2,
              s.disclaimer_3,
              'Zipher is open-source software provided as is, without warranty of any kind. Its authors are not liable for damages arising from its use.',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: ZipherSpacing.sm),
                child: Text(line, style: ZipherType.subhead),
              ),
          ],
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════
// DISCLAIMER PAGE (first run)
// ═══════════════════════════════════════════════════════════

class DisclaimerPage extends StatefulWidget {
  final String mode; // 'create' or 'restore'
  const DisclaimerPage({this.mode = 'restore'});
  @override
  State<StatefulWidget> createState() => _DisclaimerState();
}

class _DisclaimerState extends State<DisclaimerPage> {
  /// Three facts a newcomer needs, one line each; one tap to accept.
  static const _facts = [
    (Icons.key_rounded, 'Your recovery phrase is the only way back in.'),
    (
      Icons.visibility_off_rounded,
      'We never see it, and can’t restore it for you.'
    ),
    (Icons.shield_rounded, 'Payments are private by default.'),
  ];

  @override
  Widget build(BuildContext context) {
    final creating = widget.mode == 'create';
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  ZipherSpacing.sm, ZipherSpacing.sm, ZipherSpacing.sm, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => GoRouter.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: ZipherColors.text90, size: 20),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                    horizontal: ZipherColors.pagePadding),
                children: [
                  const Gap(ZipherSpacing.md),
                  Text(creating ? 'Your wallet, your keys' : 'Welcome back',
                      style: ZipherType.largeTitle),
                  const Gap(ZipherSpacing.sm),
                  Text(
                      creating
                          ? 'Three things to know before you start.'
                          : 'Three things to know before you restore.',
                      style: ZipherType.subhead),
                  const Gap(ZipherSpacing.lg),
                  ZipherWidgets.group([
                    for (final (icon, text) in _facts)
                      Padding(
                        padding: const EdgeInsets.all(ZipherSpacing.md),
                        child: Row(children: [
                          ZipherWidgets.iconTile(icon,
                              color: ZipherColors.cyan),
                          const Gap(ZipherSpacing.smMd),
                          Expanded(
                              child: Text(text, style: ZipherType.rowTitle)),
                        ]),
                      ),
                  ]),
                ],
              ),
            ),
            ZipherWidgets.bottomActions([
              ZipherButton(
                label: 'I understand',
                loading: _creating,
                onPressed: _accept,
              ),
              ZipherButton(
                label: 'Terms',
                kind: ZipherButtonKind.plain,
                size: ZipherButtonSize.small,
                color: ZipherColors.text60,
                onPressed: () => showTermsSheet(context),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  bool _creating = false;

  void _accept() async {
    if (_creating) return;
    final prefs = await SharedPreferences.getInstance();
    appSettings.disclaimer = true;
    await appSettings.save(prefs);

    if (widget.mode == 'create') {
      setState(() => _creating = true);
      try {
        final ws = WalletService.instance;
        logger.d('creating wallet');

        if (ws.isWalletOpen) {
          syncStatus2.paused = true;
          await ws.closeWallet();
        }

        await ws.createNewWallet('Main Wallet');

        final balance = await ws.getBalanceOrZero();
        final addrs = await ws.getAddresses();
        final profile =
            await WalletRegistry.instance.getById(ws.activeWalletId!);

        aa = ActiveAccount2.fromWallet(
          coin: activeCoin.coin,
          address: addrs.isNotEmpty ? addrs.first.address : '',
          balance: balance,
          walletName: profile?.name ?? 'Main Wallet',
          walletId: ws.activeWalletId ?? '',
        );
        await aa.save(prefs);

        aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
        syncStatus2.resetForWalletSwitch();
        if (mounted) {
          GoRouter.of(context).go('/account');
          Future.delayed(
              const Duration(milliseconds: 500), () => startAutoSync());
        }
      } catch (e) {
        logger.e('Create wallet error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating wallet: $e')),
          );
        }
      } finally {
        if (mounted) setState(() => _creating = false);
      }
    } else {
      if (mounted) GoRouter.of(context).push('/restore');
    }
  }
}
