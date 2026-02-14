import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../zipher_theme.dart';
import '../../generated/intl/messages.dart';

class BackupPage extends StatefulWidget {
  late final Backup backup;
  late final String primary;

  BackupPage() {
    backup = WarpApi.getBackup(aa.coin, aa.id);
    if (backup.seed != null)
      primary = backup.seed!;
    else if (backup.sk != null)
      primary = backup.sk!;
    else if (backup.uvk != null)
      primary = backup.uvk!;
    else if (backup.fvk != null)
      primary = backup.fvk!;
    else
      throw 'Account has no key';
  }

  @override
  State<StatefulWidget> createState() => _BackupState();
}

class _BackupState extends State<BackupPage> {
  bool showSubKeys = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = Theme.of(context);
    final name = widget.backup.name!;
    final small = t.textTheme.bodySmall!;

    List<Widget> cards = [];
    TextStyle? style;
    if (widget.backup.seed != null) {
      var seed = widget.backup.seed!;
      if (widget.backup.index != 0) seed += ' [${widget.backup.index}]';
      cards.add(BackupPanel(name, s.seed, seed, Icon(Icons.save)));
      style = small;
    }
    if (widget.backup.sk != null) {
      cards.add(BackupPanel(
          name, s.secretKey, widget.backup.sk!, Icon(Icons.vpn_key),
          style: style));
      style = small;
    }
    if (widget.backup.uvk != null) {
      cards.add(BackupPanel(
          name, s.unifiedViewingKey, widget.backup.uvk!, Icon(Icons.visibility),
          style: style));
      style = small;
    }
    if (widget.backup.fvk != null) {
      cards.add(BackupPanel(name, s.viewingKey, widget.backup.fvk!,
          Icon(Icons.visibility_outlined),
          style: style));
      style = small;
    }
    if (widget.backup.tsk != null) {
      cards.add(BackupPanel(
          name, s.transparentKey, widget.backup.tsk!, Icon(Icons.key),
          style: style));
      style = small;
    }
    final subKeys = cards.sublist(1);

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.surface,
        title: Text(s.backup),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(children: [
            cards[0],
            FormBuilderSwitch(
              name: 'subkeys',
              title: Text(s.showSubKeys),
              initialValue: showSubKeys,
              onChanged: (v) => setState(() => showSubKeys = v!),
            ),
            if (showSubKeys) ...subKeys,
            Gap(8),
            FormBuilderSwitch(
                name: 'remind',
                title: Text(s.noRemindBackup),
                initialValue: aa.saved,
                onChanged: _remind)
          ]),
        ),
      ),
    );
  }

  _remind(bool? v) {
    WarpApi.setBackupReminder(aa.coin, aa.id, v!);
    setActiveAccount(aa.coin, aa.id); // reload
  }
}

class BackupPanel extends StatelessWidget {
  final String name;
  final String label;
  final String value;
  final Icon icon;
  final TextStyle? style;

  BackupPanel(this.name, this.label, this.value, this.icon, {this.style});
  @override
  Widget build(BuildContext context) {
    final qrLabel = '$label of $name';
    return GestureDetector(
        onTap: () => showQR(context, value, qrLabel),
        child: Container(
          padding: EdgeInsets.all(ZipherSpacing.sm),
          decoration: BoxDecoration(
            color: ZipherColors.surface,
            borderRadius: BorderRadius.circular(ZipherRadius.md),
            border: Border.all(color: ZipherColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon.icon, color: ZipherColors.textSecondary, size: icon.size ?? 24),
                  SizedBox(width: ZipherSpacing.sm),
                  Text(
                    label,
                    style: TextStyle(
                      color: ZipherColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              SizedBox(height: ZipherSpacing.xs),
              Text(
                value,
                style: style ?? TextStyle(
                  color: ZipherColors.textPrimary,
                  fontSize: 14,
                ),
                maxLines: 6,
              ),
            ],
          ),
        ));
  }

  showQR(BuildContext context, String value, String title) {
    GoRouter.of(context).push('/showqr?title=$title', extra: value);
  }
}
