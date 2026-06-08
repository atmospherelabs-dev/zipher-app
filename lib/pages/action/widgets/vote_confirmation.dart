import 'package:flutter/material.dart';
import 'package:gap/gap.dart';

import '../../../zipher_theme.dart';
import '../../../services/voting_service.dart';
import '../../../services/wallet_service.dart';
import '../../../src/rust/api/engine_api.dart' as rust_engine;

class VoteConfirmation extends StatefulWidget {
  final VoteConfig config;
  final VotingEligibility eligibility;
  final Function(String) onResult;

  const VoteConfirmation({
    super.key,
    required this.config,
    required this.eligibility,
    required this.onResult,
  });

  @override
  State<VoteConfirmation> createState() => _VoteConfirmationState();
}

class _VoteConfirmationState extends State<VoteConfirmation> {
  final Map<int, int> _selections = {};
  bool _delegating = false;
  bool _done = false;
  String _progressPhase = '';
  double _progressValue = 0.0;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    if (_done) return _buildDoneCard();
    if (_delegating) return _buildProgressCard();
    if (_errorMessage != null) return _buildErrorCard();
    return _buildVoteCard();
  }

  Widget _buildErrorCard() {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 20),
              const Gap(8),
              const Expanded(
                child: Text(
                  'Vote failed',
                  style: TextStyle(
                    color: ZipherColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const Gap(8),
          Text(
            _errorMessage!,
            style: const TextStyle(
              color: ZipherColors.textSecondary,
              fontSize: 12,
            ),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          const Gap(12),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () {
                setState(() => _errorMessage = null);
              },
              child: const Text('Try again'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoteCard() {
    final config = widget.config;
    final elig = widget.eligibility;

    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZipherColors.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ZipherColors.purple.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'GOVERNANCE',
                  style: TextStyle(
                    color: ZipherColors.purple,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '${elig.eligibleZec.toStringAsFixed(2)} ZEC',
                style: TextStyle(
                  color: ZipherColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const Gap(12),
          Text(
            config.title,
            style: const TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (config.description.isNotEmpty) ...[
            const Gap(4),
            Text(
              config.description,
              style: TextStyle(
                color: ZipherColors.textSecondary,
                fontSize: 13,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Gap(16),
          ...config.proposals.map(_buildProposalCard),
          const Gap(16),
          _buildVoteButton(),
        ],
      ),
    );
  }

  Widget _buildProposalCard(VoteProposal proposal) {
    final selected = _selections[proposal.id];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            proposal.title,
            style: const TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Gap(8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: proposal.options.map((option) {
              final isSelected = selected == option.index;
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _selections[proposal.id] = option.index;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? ZipherColors.purple.withValues(alpha: 0.2)
                        : ZipherColors.surfaceLight,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? ZipherColors.purple
                          : ZipherColors.border,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    option.label,
                    style: TextStyle(
                      color: isSelected
                          ? ZipherColors.purple
                          : ZipherColors.textSecondary,
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildVoteButton() {
    final allSelected =
        _selections.length == widget.config.proposals.length;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: allSelected ? _submitVote : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: ZipherColors.purple,
          disabledBackgroundColor: ZipherColors.surfaceLight,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: Text(
          allSelected
              ? 'Cast Vote (${widget.eligibility.eligibleZec.toStringAsFixed(2)} ZEC)'
              : 'Select all proposals to vote',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Future<void> _submitVote() async {
    setState(() {
      _delegating = true;
      _errorMessage = null;
      _progressPhase = 'Preparing...';
      _progressValue = 0.0;
    });

    try {
      final seedPhrase = await WalletService.instance.getSeedPhrase();
      if (seedPhrase == null) throw Exception('Seed phrase unavailable');

      void updateProgress(String phase, double progress) {
        if (mounted) {
          setState(() {
            _progressPhase = _phaseLabel(phase);
            _progressValue = progress;
          });
        }
      }

      // Phase 1: Delegation (PCZT → PIR → ZKP1 → submit)
      updateProgress('delegation', 0.0);
      final delegations = await VotingService.instance.performDelegation(
        seedPhrase: seedPhrase,
        onProgress: updateProgress,
      );

      // Phase 2: Submit each delegation to chain
      final vanPositions = <int>[];
      for (int i = 0; i < delegations.length; i++) {
        updateProgress('submitting', i / delegations.length);
        final result = await VotingService.instance.submitDelegation(delegations[i]);
        vanPositions.add(result.vanPosition ?? i);
      }

      // Phase 3: Sync vote commitment tree + get VAN witnesses
      updateProgress('tree_sync', 0.0);
      final witnesses = await VotingService.instance.syncTreeAndWitness(vanPositions);
      if (witnesses.isEmpty) {
        throw Exception('Failed to generate VAN witnesses');
      }
      final witness = witnesses.first;

      // Phase 4: Derive voting seed + build vote commitments
      final votingSeed = await rust_engine.engineVoteDeriveSeedFromPhrase(
        seedPhrase: seedPhrase,
      );
      updateProgress('voting', 0.0);
      for (final entry in _selections.entries) {
        final proposalId = entry.key;
        final choice = entry.value;
        final proposal = widget.config.proposals.firstWhere(
          (p) => p.id == proposalId,
        );

        await VotingService.instance.castVote(
          votingSeed: votingSeed.toList(),
          proposalId: proposalId,
          choice: choice,
          numOptions: proposal.options.length,
          vanCommRand: delegations.first.vanCommRand,
          totalValue: delegations.first.totalValue.toInt(),
          vanAuthPath: witness.authPath,
          vanPosition: witness.position,
          anchorHeight: witness.anchorHeight,
          onProgress: (phase, progress) {
            updateProgress('voting', progress);
          },
        );
      }

      setState(() {
        _delegating = false;
        _done = true;
      });

      final selections = _selections.entries.map((e) {
        final proposal =
            widget.config.proposals.firstWhere((p) => p.id == e.key);
        final option =
            proposal.options.firstWhere((o) => o.index == e.value);
        return '${proposal.title}: ${option.label}';
      }).join(', ');

      widget.onResult(
        'Vote cast on-chain with ZKP proofs. Selections: $selections',
      );
    } catch (e) {
      setState(() {
        _delegating = false;
        _errorMessage = e.toString();
      });
      widget.onResult('Vote failed: $e');
    }
  }

  String _phaseLabel(String phase) {
    switch (phase) {
      case 'delegation':
        return 'Building delegation proof...';
      case 'submitting':
        return 'Submitting to chain...';
      case 'tree_sync':
        return 'Syncing vote commitment tree...';
      case 'voting':
        return 'Generating vote proofs...';
      case 'commitment':
        return 'Building vote commitment...';
      case 'signing':
        return 'Signing transaction...';
      case 'confirming':
        return 'Confirming on chain...';
      case 'complete':
        return 'Complete';
      default:
        return phase;
    }
  }

  Widget _buildProgressCard() {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZipherColors.border),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: _progressValue > 0 ? _progressValue : null,
              valueColor: const AlwaysStoppedAnimation(ZipherColors.purple),
            ),
          ),
          const Gap(12),
          Text(
            _progressPhase,
            style: const TextStyle(
              color: ZipherColors.textSecondary,
              fontSize: 13,
            ),
          ),
          if (_progressValue > 0) ...[
            const Gap(8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progressValue,
                backgroundColor: ZipherColors.surfaceLight,
                valueColor:
                    const AlwaysStoppedAnimation(ZipherColors.purple),
                minHeight: 3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDoneCard() {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZipherColors.purple.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: ZipherColors.green, size: 20),
          const Gap(10),
          Expanded(
            child: Text(
              'Vote recorded',
              style: TextStyle(
                color: ZipherColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
