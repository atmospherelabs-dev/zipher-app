import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/warp_api.dart';

import '../generated/intl/messages.dart';
import '../zipher_theme.dart';
import 'utils.dart';

class ScanQRCodePage extends StatefulWidget {
  final bool Function(String code) onCode;
  final String? Function(String? code)? validator;
  ScanQRCodePage(ScanQRContext context)
      : onCode = context.onCode,
        validator = context.validator;
  @override
  State<StatefulWidget> createState() => _ScanQRCodeState();
}

class _ScanQRCodeState extends State<ScanQRCodePage> {
  final formKey = GlobalKey<FormBuilderState>();
  final controller = TextEditingController();
  var scanned = false;
  StreamSubscription<BarcodeCapture>? ss;

  @override
  void dispose() {
    ss?.cancel();
    ss = null;
    controller.dispose();
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
          'SCAN',
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
              onPressed: _open,
              icon: Icon(Icons.photo_library_outlined,
                  size: 20,
                  color: ZipherColors.text40),
              tooltip: 'Open from gallery',
            ),
          IconButton(
            onPressed: _ok,
            icon: Icon(Icons.check_rounded,
                size: 22,
                color: ZipherColors.cyan.withValues(alpha: 0.8)),
            tooltip: 'Confirm',
          ),
        ],
      ),
      body: FormBuilder(
        key: formKey,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  MobileScanner(
                    onDetect: _onScan,
                  ),
                  // Viewfinder overlay
                  Center(
                    child: Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: ZipherColors.cyan.withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Manual input area
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              decoration: BoxDecoration(
                color: ZipherColors.bg,
                border: Border(
                  top: BorderSide(
                    color: ZipherColors.borderSubtle,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Or paste manually',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: ZipherColors.text40,
                    ),
                  ),
                  const Gap(8),
                  Container(
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: FormBuilderTextField(
                      name: 'qr',
                      controller: controller,
                      validator: widget.validator,
                      style: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text90,
                      ),
                      decoration: InputDecoration(
                        hintText: s.qr,
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: ZipherColors.text20,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  _onScan(BarcodeCapture capture) {
    if (scanned) return;
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final text = barcode.rawValue;
      if (text != null) {
        controller.text = text;
        final form = formKey.currentState!;
        if (form.validate()) {
          scanned = true;
          if (widget.onCode(text)) GoRouter.of(context).pop();
          return;
        }
      }
    }
  }

  _open() async {
    final file = await pickFile();
    logger.d('open');
    if (file != null) {
      final path = file.files[0].path!;
      final c = MobileScannerController();
      c.analyzeImage(path);
      ss = c.barcodes.listen(_onScan);
    }
  }

  _ok() {
    if (formKey.currentState!.validate()) {
      if (widget.onCode(controller.text)) GoRouter.of(context).pop();
    }
  }
}

class MultiQRReader extends StatefulWidget {
  final void Function(String?)? onChanged;
  MultiQRReader({this.onChanged});
  @override
  State<StatefulWidget> createState() => _MultiQRReaderState();
}

class _MultiQRReaderState extends State<MultiQRReader> {
  final Set<String> fragments = {};
  double value = 0.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LinearProgressIndicator(
          value: value,
          minHeight: 4,
          backgroundColor: ZipherColors.cardBg,
          valueColor: AlwaysStoppedAnimation<Color>(ZipherColors.cyan),
        ),
        Expanded(
          child: MobileScanner(
            onDetect: _onScan,
          ),
        ),
      ],
    );
  }

  _onScan(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final text = barcode.rawValue;
      if (text == null) return;
      if (!fragments.contains(text)) {
        fragments.add(text);
        final res = WarpApi.mergeData(text);
        if (res.data?.isEmpty != false) {
          logger.d('${res.progress} ${res.total}');
          setState(() {
            value = res.progress / res.total;
          });
        } else {
          final decoded =
              utf8.decode(ZLibCodec().decode(base64Decode(res.data!)));
          widget.onChanged?.call(decoded);
        }
      }
    }
  }
}

Future<String> scanQRCode(
  BuildContext context, {
  bool multi = false,
  String? Function(String? code)? validator,
}) {
  final completer = Completer<String>();
  bool onCode(String c) {
    completer.complete(c);
    return true;
  }

  GoRouter.of(context)
      .push('/scan', extra: ScanQRContext(onCode, validator: validator));
  return completer.future;
}

class ScanQRContext {
  final bool Function(String) onCode;
  final String? Function(String? code)? validator;
  final bool multi;
  ScanQRContext(this.onCode, {this.validator, this.multi = false});
}
