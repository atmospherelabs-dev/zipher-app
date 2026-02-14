import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:mustache_template/mustache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../generated/intl/messages.dart';
import '../../zipher_theme.dart';
import '../../src/version.dart';
import '../../appsettings.dart';
import '../utils.dart';

class AboutPage extends StatelessWidget {
  final String contentTemplate;
  AboutPage(this.contentTemplate);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final template = Template(contentTemplate);
    var content = template.renderString({'APP': APP_NAME});
    final id = commitId.substring(0, 8);
    final versionString = "${s.version}: $packageVersion/$id";
    return Scaffold(
        backgroundColor: ZipherColors.bg,
        appBar: AppBar(
          backgroundColor: ZipherColors.surface,
          title: Text(s.about),
        ),
        body: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              children: [
                MarkdownBody(data: content),
                Padding(padding: EdgeInsets.symmetric(vertical: 8)),
                TextButton(
                    child: Text(versionString),
                    onPressed: () => openGithub(commitId)),
              ],
            ),
          ),
        ));
  }

  openGithub(String commitId) {
    launchUrl(Uri.parse("https://github.com/hhanh00/zwallet/commit/$commitId"));
  }
}

class DisclaimerPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _DisclaimerState();
}

class _DisclaimerState extends State<DisclaimerPage> {
  final List<bool> _accepted = [false, false, false];

  bool get _allAccepted => !_accepted.any((e) => !e);

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
              // Back button
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
                  color: ZipherColors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.security_outlined,
                    color: ZipherColors.orange, size: 28),
              ),
              const Gap(20),
              // Title
              const Text(
                'Self-Custody',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: ZipherColors.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const Gap(8),
              Text(
                'Before restoring your wallet, please acknowledge the following.',
                style: TextStyle(
                  fontSize: 15,
                  color: ZipherColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const Gap(32),
              // Disclaimer items
              _DisclaimerTile(
                accepted: _accepted[0],
                icon: Icons.vpn_key_outlined,
                text: s.disclaimer_1,
                onChanged: (v) => setState(() => _accepted[0] = v),
              ),
              const Gap(12),
              _DisclaimerTile(
                accepted: _accepted[1],
                icon: Icons.warning_amber_outlined,
                text: s.disclaimer_2,
                onChanged: (v) => setState(() => _accepted[1] = v),
              ),
              const Gap(12),
              _DisclaimerTile(
                accepted: _accepted[2],
                icon: Icons.visibility_outlined,
                text: s.disclaimer_3,
                onChanged: (v) => setState(() => _accepted[2] = v),
              ),
              const Spacer(),
              // Continue button
              SizedBox(
                width: double.infinity,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _allAccepted ? 1.0 : 0.35,
                  child: IgnorePointer(
                    ignoring: !_allAccepted,
                    child: ZipherWidgets.gradientButton(
                      label: 'Continue',
                      icon: Icons.arrow_forward,
                      onPressed: _accept,
                    ),
                  ),
                ),
              ),
              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  void _accept() async {
    appSettings.disclaimer = true;
    await appSettings.save(await SharedPreferences.getInstance());
    if (mounted) GoRouter.of(context).push('/restore');
  }
}

class _DisclaimerTile extends StatelessWidget {
  final bool accepted;
  final IconData icon;
  final String text;
  final ValueChanged<bool> onChanged;

  const _DisclaimerTile({
    required this.accepted,
    required this.icon,
    required this.text,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!accepted),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: accepted
              ? ZipherColors.green.withValues(alpha: 0.08)
              : ZipherColors.surface,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(
            color: accepted ? ZipherColors.green : ZipherColors.border,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: accepted
                    ? ZipherColors.green
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: accepted
                      ? ZipherColors.green
                      : ZipherColors.textMuted,
                  width: 1.5,
                ),
              ),
              child: accepted
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const Gap(14),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 14,
                  color: accepted
                      ? ZipherColors.textPrimary
                      : ZipherColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
