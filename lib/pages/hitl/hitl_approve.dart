import 'package:flutter/material.dart';

import '../../services/hitl_watch_service.dart';

/// Full-screen approval page shown when a remote agent requests
/// approval for a transaction that exceeds spending policy.
class HitlApprovePage extends StatefulWidget {
  final HitlApprovalRequest request;

  const HitlApprovePage({super.key, required this.request});

  @override
  State<HitlApprovePage> createState() => _HitlApprovePageState();
}

class _HitlApprovePageState extends State<HitlApprovePage> {
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final req = widget.request;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        title: const Text('Agent Approval'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.security_rounded,
                      size: 48,
                      color: Color(0xFF5B9CF6),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Approval Required',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'An AI agent wants to send:',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _InfoRow(label: 'Amount', value: '${req.amountZec.toStringAsFixed(4)} ZEC'),
                    const SizedBox(height: 12),
                    _InfoRow(
                      label: 'To',
                      value: req.address.length > 20
                          ? '${req.address.substring(0, 10)}...${req.address.substring(req.address.length - 10)}'
                          : req.address,
                    ),
                    if (req.toolName.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _InfoRow(label: 'Tool', value: req.toolName),
                    ],
                    if (req.contextId != null) ...[
                      const SizedBox(height: 12),
                      _InfoRow(label: 'Context', value: req.contextId!),
                    ],
                    if (req.memoPreview != null) ...[
                      const SizedBox(height: 12),
                      _InfoRow(label: 'Memo', value: req.memoPreview!),
                    ],
                    const SizedBox(height: 12),
                    _InfoRow(
                      label: 'Expires',
                      value: '${req.remainingSecs}s',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              if (!_submitting) ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: () => _decide(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF56D4C8),
                      foregroundColor: const Color(0xFF0A0E1A),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Approve',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton(
                    onPressed: () => _decide(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Reject',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ] else
                const CircularProgressIndicator(color: Color(0xFF5B9CF6)),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _decide(bool approved) async {
    setState(() => _submitting = true);
    final success = await HitlWatchService.instance.submitDecision(
      widget.request.approvalId,
      approved: approved,
    );
    if (mounted) {
      if (success) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approved ? 'Approved' : 'Rejected'),
            backgroundColor: approved ? const Color(0xFF56D4C8) : Colors.redAccent,
          ),
        );
      } else {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to submit decision. Try again.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
