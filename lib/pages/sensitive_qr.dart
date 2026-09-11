import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Recovery information must not use the ordinary address QR export page.
/// Hide on every interruption; fresh authorization is required to show it again.
class SensitiveQrPage extends StatefulWidget {
  final String title;
  final String value;
  final Future<bool> Function() authorize;
  const SensitiveQrPage(
      {super.key,
      required this.title,
      required this.value,
      required this.authorize});

  @override
  State<SensitiveQrPage> createState() => _SensitiveQrState();
}

class _SensitiveQrState extends State<SensitiveQrPage>
    with WidgetsBindingObserver {
  bool _visible = true;
  bool _authorizing = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (state == AppLifecycleState.paused) _epoch++;
      setState(() => _visible = false);
    }
  }

  Future<void> _reveal() async {
    if (_authorizing) return;
    setState(() => _authorizing = true);
    final epoch = _epoch;
    try {
      final approved = await widget.authorize();
      if (mounted && epoch == _epoch) setState(() => _visible = approved);
    } finally {
      if (mounted) setState(() => _authorizing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
            child: _visible
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: QrImage(
                        data: widget.value, backgroundColor: Colors.white))
                : TextButton(
                    onPressed: _authorizing ? null : _reveal,
                    child: const Text('Authenticate to show recovery QR'))),
      );
}
