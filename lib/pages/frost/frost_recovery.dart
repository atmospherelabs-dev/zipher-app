import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../services/frost_service.dart';
import '../../zipher_theme.dart';

class FrostRecoveryPage extends StatefulWidget {
  final String walletId;
  const FrostRecoveryPage({super.key, required this.walletId});

  @override
  State<FrostRecoveryPage> createState() => _FrostRecoveryPageState();
}

class _FrostRecoveryPageState extends State<FrostRecoveryPage> {
  FrostWalletMetadata? _metadata;
  String? _share;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final meta = await FrostService.instance.loadMetadata(widget.walletId);
      final share = await FrostService.instance.getWalletShare(widget.walletId);
      if (!mounted) return;
      setState(() {
        _metadata = meta;
        _share = share;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = _metadata;
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: Text(
          'Shared wallet recovery',
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _loading
              ? Center(
                  child: CircularProgressIndicator(color: ZipherColors.cyan))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.health_and_safety_rounded,
                        size: 40, color: ZipherColors.cyan),
                    const Gap(22),
                    Text(
                      'Rotate or repair shares',
                      style: TextStyle(
                        color: ZipherColors.text90,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const Gap(8),
                    Text(
                      'Use this when a co-signer device is lost or you need to replace a share.',
                      style: TextStyle(
                        color: ZipherColors.text60,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    const Gap(24),
                    _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _row('Wallet', meta?.label ?? widget.walletId),
                          _row(
                            'Threshold',
                            meta == null
                                ? 'Unknown'
                                : '${meta.threshold} of ${meta.participants}',
                          ),
                          _row('Local share',
                              _share == null ? 'Missing' : 'Present'),
                          if (_error != null)
                            Text('Error: $_error',
                                style: TextStyle(color: ZipherColors.red)),
                        ],
                      ),
                    ),
                    const Gap(20),
                    _Warning(),
                    const Spacer(),
                    _DisabledButton(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: ZipherColors.text90,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: ZipherColors.warm, size: 20),
          const Gap(10),
          Expanded(
            child: Text(
              'Share repair is disabled until the app persists the full FROST repair transcript. This prevents accidentally creating shares that cannot spend the existing wallet.',
              style: TextStyle(
                color: ZipherColors.text60,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisabledButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ZipherColors.cardBgElevated,
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Text(
        'Repair shares unavailable',
        style: TextStyle(
          color: ZipherColors.text20,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: child,
    );
  }
}
