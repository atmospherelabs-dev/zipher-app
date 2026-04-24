import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';

import '../../../zipher_theme.dart';
import '../../../services/llm_service.dart';

class LlmSettingsSheet extends StatefulWidget {
  final LlmStatus initialStatus;
  final double downloadProgress;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onLoad;
  final VoidCallback onUnload;

  const LlmSettingsSheet({
    super.key,
    required this.initialStatus,
    required this.downloadProgress,
    required this.onDownload,
    required this.onDelete,
    required this.onLoad,
    required this.onUnload,
  });

  @override
  State<LlmSettingsSheet> createState() => _LlmSettingsSheetState();
}

class _LlmSettingsSheetState extends State<LlmSettingsSheet> {
  late LlmStatus status;
  StreamSubscription<LlmStatus>? _sub;

  @override
  void initState() {
    super.initState();
    status = widget.initialStatus;
    _sub = LlmService.instance.statusStream.listen((s) {
      if (mounted) setState(() => status = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: ZipherColors.text20, borderRadius: BorderRadius.circular(2))),
          const Gap(16),
          Text('On-Device AI', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ZipherColors.text90)),
          const Gap(8),
          Text('A small language model runs on your device for natural language understanding. No data leaves your phone.',
              style: TextStyle(fontSize: 12, color: ZipherColors.text40, height: 1.5), textAlign: TextAlign.center),
          const Gap(20),
          _statusRow(),
          const Gap(16),

          if (status == LlmStatus.notDownloaded || status == LlmStatus.error)
            _actionButton(label: 'Download Model (~1 GB)', icon: Icons.download_rounded, onTap: widget.onDownload, accent: true),

          if (status == LlmStatus.downloading) ...[
            ClipRRect(borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: widget.downloadProgress, backgroundColor: ZipherColors.cardBg,
                    valueColor: AlwaysStoppedAnimation(ZipherColors.cyan), minHeight: 6)),
            const Gap(8),
            Text('${(widget.downloadProgress * 100).toStringAsFixed(0)}%',
                style: TextStyle(fontSize: 12, color: ZipherColors.text40)),
          ],

          if (status == LlmStatus.ready)
            _actionButton(label: 'Load into Memory', icon: Icons.memory_rounded, onTap: widget.onLoad, accent: true),

          if (status == LlmStatus.loading)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: ZipherColors.cyan)),
              const Gap(10),
              Text('Loading model...', style: TextStyle(fontSize: 13, color: ZipherColors.text40)),
            ]),

          if (status == LlmStatus.loaded) ...[
            _actionButton(label: 'Unload from Memory', icon: Icons.memory_rounded, onTap: widget.onUnload),
            const Gap(8),
            _actionButton(label: 'Delete Model', icon: Icons.delete_outline_rounded, onTap: widget.onDelete, destructive: true),
          ],

          if (status == LlmStatus.ready) ...[
            const Gap(8),
            _actionButton(label: 'Delete Model', icon: Icons.delete_outline_rounded, onTap: widget.onDelete, destructive: true),
          ],
        ],
      ),
    );
  }

  Widget _statusRow() {
    final (icon, label, color) = switch (status) {
      LlmStatus.notDownloaded => (Icons.cloud_download_outlined, 'Not downloaded', ZipherColors.text20),
      LlmStatus.downloading => (Icons.downloading_rounded, 'Downloading...', ZipherColors.cyan),
      LlmStatus.ready => (Icons.check_circle_outline_rounded, 'Downloaded — not loaded', ZipherColors.text40),
      LlmStatus.loading => (Icons.hourglass_top_rounded, 'Loading...', ZipherColors.cyan),
      LlmStatus.loaded => (Icons.auto_awesome_rounded, 'Active — natural language enabled', ZipherColors.cyan),
      LlmStatus.error => (Icons.error_outline_rounded, 'Error — tap to retry', ZipherColors.orange),
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const Gap(8),
        Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: color)),
      ],
    );
  }

  Widget _actionButton({required String label, required IconData icon, required VoidCallback onTap,
      bool accent = false, bool destructive = false}) {
    final color = destructive ? ZipherColors.orange : accent ? ZipherColors.cyan : ZipherColors.text40;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: accent ? 0.12 : 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: color.withValues(alpha: 0.8)),
                const Gap(8),
                Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color.withValues(alpha: 0.9))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
