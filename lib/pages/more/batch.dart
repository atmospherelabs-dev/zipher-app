import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';

import '../../generated/intl/messages.dart';
import '../../zipher_theme.dart';
import '../utils.dart';

class BatchBackupPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _BatchBackupState();
}

class _BatchBackupState extends State<BatchBackupPage> {
  final _backupKeyController = TextEditingController();
  final _restoreKeyController = TextEditingController();

  @override
  void dispose() {
    _backupKeyController.dispose();
    _restoreKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'APP DATA',
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
        actions: [
          IconButton(
            onPressed: _generateKey,
            icon: Icon(Icons.key_rounded,
                size: 20,
                color: ZipherColors.text40),
            tooltip: 'Generate encryption key',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Info
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ZipherColors.cyan.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(ZipherRadius.lg),
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
                      'Backup all accounts to an encrypted file, or restore from a previous backup. Use the key icon to generate an encryption key pair.',
                      style: TextStyle(
                        fontSize: 12,
                        color: ZipherColors.cyan.withValues(alpha: 0.5),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Gap(28),

            // ── BACKUP ──
            _sectionLabel('Backup'),
            const Gap(8),
            Container(
              padding: const EdgeInsets.all(ZipherSpacing.md),
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(ZipherRadius.lg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Encryption public key',
                    style: TextStyle(
                      fontSize: 12,
                      color: ZipherColors.text40,
                    ),
                  ),
                  const Gap(8),
                  Container(
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(ZipherRadius.md),
                    ),
                    child: TextField(
                      controller: _backupKeyController,
                      style: TextStyle(
                        fontSize: 13,
                        color: ZipherColors.text90,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        hintText: 'Paste public key...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: ZipherColors.text40,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(14),
                      ),
                    ),
                  ),
                  const Gap(14),
                  InkWell(
                    onTap: _save,
                    borderRadius: BorderRadius.circular(ZipherRadius.md),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: ZipherColors.cyan.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(ZipherRadius.md),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.cloud_upload_outlined,
                              size: 16,
                              color: ZipherColors.cyan.withValues(alpha: 0.7)),
                          const Gap(8),
                          Text(
                            s.fullBackup,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: ZipherColors.cyan.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Gap(24),

            // ── RESTORE ──
            _sectionLabel('Restore'),
            const Gap(8),
            Container(
              padding: const EdgeInsets.all(ZipherSpacing.md),
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                borderRadius: BorderRadius.circular(ZipherRadius.lg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Decryption secret key',
                    style: TextStyle(
                      fontSize: 12,
                      color: ZipherColors.text40,
                    ),
                  ),
                  const Gap(8),
                  Container(
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(ZipherRadius.md),
                    ),
                    child: TextField(
                      controller: _restoreKeyController,
                      style: TextStyle(
                        fontSize: 13,
                        color: ZipherColors.text90,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        hintText: 'Paste secret key...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: ZipherColors.text40,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(14),
                      ),
                    ),
                  ),
                  const Gap(14),
                  InkWell(
                    onTap: _restore,
                    borderRadius: BorderRadius.circular(ZipherRadius.md),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: ZipherColors.purple.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(ZipherRadius.md),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.cloud_download_outlined,
                              size: 16,
                              color: ZipherColors.purple.withValues(alpha: 0.85)),
                          const Gap(8),
                          Text(
                            s.fullRestore,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: ZipherColors.purple,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Gap(40),
          ],
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
        color: ZipherColors.text40,
      ),
    );
  }

  void _generateKey() async {
    final keys =
        await GoRouter.of(context).push<_Agekeys>('/more/backup/keygen');
    if (keys != null) {
      _backupKeyController.text = keys.pk ?? '';
    }
  }

  void _save() async {
    final s = S.of(context);
    final tempDir = await getTemporaryDirectory();
    final savePath = await getTemporaryPath('Zipher.age');
    try {
      // TODO: migrate to WalletService - zipBackup not yet available
      await showMessageBox2(context, s.error, 'Backup not yet supported');
    } on String catch (e) {
      await showMessageBox2(context, s.error, e);
    }
  }

  void _restore() async {
    final s = S.of(context);
    final r = await FilePicker.platform.pickFiles(dialogTitle: s.fullRestore);
    if (r != null) {
      try {
        // TODO: migrate to WalletService - decryptBackup not yet available
        await showMessageBox2(context, s.error, 'Restore not yet supported');
      } on String catch (e) {
        await showMessageBox2(context, s.error, e);
      }
    }
  }
}

Future<String> getTemporaryPath(String filename) async {
  final dir = await getTemporaryDirectory();
  return path.join(dir.path, filename);
}

Future<void> shareFile(BuildContext context, String filePath,
    {String? title}) async {
  Size size = MediaQuery.of(context).size;
  final xfile = XFile(filePath);
  await Share.shareXFiles([xfile],
      subject: title,
      sharePositionOrigin: Rect.fromLTWH(0, 0, size.width, size.height / 2));
}

// Keep KeygenPage for router compatibility
class KeygenPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _KeygenState();
}

/// Local age keys type (replaces warp_api Agekeys).
class _Agekeys {
  final String? pk;
  final String? sk;
  _Agekeys({this.pk, this.sk});
}

class _KeygenState extends State<KeygenPage> with WithLoadingAnimation {
  late final s = S.of(context);
  _Agekeys? _keys;

  @override
  void initState() {
    super.initState();
    Future(_keygen);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'KEY GENERATOR',
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
        actions: [
          IconButton(
            onPressed: _keygen,
            icon: Icon(Icons.refresh_rounded,
                size: 20,
                color: ZipherColors.text40),
          ),
          IconButton(
            onPressed: _ok,
            icon: Icon(Icons.check_rounded,
                size: 22,
                color: ZipherColors.cyan.withValues(alpha: 0.8)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Help
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ZipherColors.cyan.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(ZipherRadius.lg),
              ),
              child: Text(
                s.keygenHelp,
                style: TextStyle(
                  fontSize: 12,
                  color: ZipherColors.cyan.withValues(alpha: 0.7),
                  height: 1.4,
                ),
              ),
            ),
            const Gap(24),

            // Public key
            _sectionLabel(s.encryptionKey),
            const Gap(8),
            _keyBox(_keys?.pk),
            const Gap(20),

            // Secret key
            _sectionLabel(s.secretKey),
            const Gap(8),
            _keyBox(_keys?.sk),
          ],
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
        color: ZipherColors.text40,
      ),
    );
  }

  Widget _keyBox(String? value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
      ),
      child: value == null
          ? Text('Generating...',
              style: TextStyle(
                  fontSize: 12,
                  color: ZipherColors.text40))
          : SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                color: ZipherColors.text60,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
    );
  }

  void _keygen() async {
    // TODO: migrate to WalletService - generateKey not yet available
    setState(() => _keys = _Agekeys(pk: 'stub_pk', sk: 'stub_sk'));
  }

  void _ok() async {
    final confirm =
        await showConfirmDialog(context, s.keygen, s.confirmSaveKeys);
    if (confirm) GoRouter.of(context).pop(_keys);
  }
}
