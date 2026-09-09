import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/wallet_service.dart';
import '../../store2.dart';
import '../utils.dart';

/// The engine supports rescanning from the wallet's saved birthday. Do not
/// offer date/height selectors until those values can be honored by the SDK.
class RescanPage extends StatefulWidget {
  final Future<void> Function()? rescan;
  const RescanPage({super.key, this.rescan});

  @override
  State<RescanPage> createState() => _RescanState();
}

class _RescanState extends State<RescanPage> {
  bool _running = false;
  String? _error;

  Future<void> _recover() async {
    if (_running) return;
    final confirmed = await showConfirmDialog(context, 'Recover transactions',
        'Re-scan from this wallet’s saved birthday? This can take time. Your seed and addresses remain the same.');
    if (!confirmed || !mounted || _running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      if (widget.rescan != null) {
        await widget.rescan!();
      } else {
        if (!WalletService.instance.isWalletOpen) {
          throw StateError('Open a wallet before recovering transactions.');
        }
        await syncStatus2.triggerRescan();
        await syncStatus2.sync();
      }
      if (mounted) GoRouter.of(context).pop();
    } catch (_) {
      if (mounted)
        setState(() {
          _error =
              'Recovery could not start. Check your connection and try again.';
        });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Recover transactions')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                  'Re-scan your wallet’s transaction history from its saved birthday to refresh balances and transactions.'),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 16),
              ],
              FilledButton(
                onPressed: _running ? null : _recover,
                child: Text(
                    _running ? 'Starting recovery…' : 'Recover transactions'),
              ),
            ],
          ),
        ),
      );
}
