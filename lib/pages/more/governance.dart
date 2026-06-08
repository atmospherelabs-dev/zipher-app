import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import '../../zipher_theme.dart';
import '../../services/voting_service.dart';
import '../../services/wallet_service.dart';
import '../../src/rust/api/engine_api.dart' as rust_engine;

class GovernancePage extends StatefulWidget {
  const GovernancePage({super.key});

  @override
  State<GovernancePage> createState() => _GovernancePageState();
}

class _GovernancePageState extends State<GovernancePage> {
  bool _loading = true;
  String? _error;
  VoteConfig? _config;
  VotingEligibility? _eligibility;

  // Voting state
  final Map<int, int> _selections = {};
  bool _voting = false;
  bool _done = false;
  String _progressPhase = '';
  double _progressValue = 0.0;
  String? _voteError;
  String? _resultSummary;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  Future<void> _discover({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final voting = VotingService.instance;

      final config = await voting.discover(staging: true, force: force);
      if (config == null) {
        setState(() {
          _loading = false;
          _config = null;
        });
        return;
      }

      if (config.isExpired) {
        setState(() {
          _loading = false;
          _config = config;
          _error = 'This vote round has ended.';
        });
        return;
      }

      VotingEligibility? eligibility;
      if (config.isActive) {
        eligibility = await voting.checkEligibility(config.snapshotHeight);
      }

      setState(() {
        _loading = false;
        _config = config;
        _eligibility = eligibility;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Gap(topPad + 12),
              _buildHeader(),
              const Gap(24),
              if (_loading) _buildLoading(),
              if (!_loading && _config == null && _error == null) _buildNoRound(),
              if (!_loading && _error != null && _config == null) _buildError(),
              if (!_loading && _config != null && !_done && !_voting) ...[
                _buildRoundCard(),
                const Gap(16),
                if (_config!.isActive && _eligibility != null) ...[
                  if (_eligibility!.isEligible) ...[
                    _buildEligibilityCard(),
                    const Gap(20),
                    _buildProposalsSection(),
                    const Gap(16),
                    if (_voteError != null) ...[
                      _buildVoteError(),
                      const Gap(12),
                    ],
                    _buildVoteButton(),
                  ] else
                    _buildNotEligible(),
                ],
                if (!_config!.isActive) _buildRoundStatus(),
              ],
              if (_voting) _buildProgress(),
              if (_done) _buildDoneCard(),
              const Gap(40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: ZipherColors.cardBg,
              borderRadius: BorderRadius.circular(ZipherRadius.sm),
            ),
            child: Icon(Icons.arrow_back_rounded, size: 18, color: ZipherColors.text60),
          ),
        ),
        const Gap(12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Governance',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: ZipherColors.text90,
                ),
              ),
              const Gap(2),
              Text(
                'Zcash Coinholder Voting',
                style: TextStyle(fontSize: 12, color: ZipherColors.text40),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: ZipherColors.purple.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(ZipherRadius.xs),
          ),
          child: Text(
            'BETA',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: ZipherColors.purple.withValues(alpha: 0.8),
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoading() {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(ZipherColors.purple),
              ),
            ),
            const Gap(12),
            Text(
              'Checking for active votes...',
              style: TextStyle(fontSize: 13, color: ZipherColors.text40),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoRound() {
    return _infoCard(
      icon: Icons.how_to_vote_outlined,
      iconColor: ZipherColors.text20,
      title: 'No active vote',
      subtitle: 'There are no governance votes open right now. '
          'When a vote round is announced, it will appear here.',
      action: TextButton(
        onPressed: () => _discover(force: true),
        child: const Text('Refresh'),
      ),
    );
  }

  Widget _buildError() {
    return _infoCard(
      icon: Icons.error_outline_rounded,
      iconColor: ZipherColors.red,
      title: 'Connection error',
      subtitle: _error!,
      action: TextButton(
        onPressed: () => _discover(force: true),
        child: const Text('Retry'),
      ),
    );
  }

  Widget _buildRoundCard() {
    final config = _config!;
    final deadline = DateTime.fromMillisecondsSinceEpoch(config.voteEndTime * 1000);
    final remaining = deadline.difference(DateTime.now());
    final daysLeft = remaining.inDays;

    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                  _config!.statusLabel.toUpperCase(),
                  style: TextStyle(
                    color: _config!.isActive ? ZipherColors.green : ZipherColors.text40,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const Spacer(),
              if (daysLeft > 0)
                Text(
                  '$daysLeft day${daysLeft == 1 ? '' : 's'} left',
                  style: TextStyle(fontSize: 11, color: ZipherColors.text40),
                ),
            ],
          ),
          const Gap(12),
          Text(
            config.title,
            style: TextStyle(
              color: ZipherColors.text90,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (config.description.isNotEmpty) ...[
            const Gap(6),
            Text(
              config.description,
              style: TextStyle(
                color: ZipherColors.text40,
                fontSize: 13,
                height: 1.4,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Gap(12),
          Row(
            children: [
              _metaChip(Icons.layers_outlined, '${config.proposals.length} proposal${config.proposals.length == 1 ? '' : 's'}'),
              const Gap(8),
              _metaChip(Icons.height_rounded, 'Snapshot ${config.snapshotHeight}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ZipherColors.surfaceLight,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: ZipherColors.text40),
          const Gap(4),
          Text(label, style: TextStyle(fontSize: 11, color: ZipherColors.text40)),
        ],
      ),
    );
  }

  Widget _buildEligibilityCard() {
    final elig = _eligibility!;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            ZipherColors.purple.withValues(alpha: 0.08),
            ZipherColors.cyan.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.purple.withValues(alpha: 0.15)),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: ZipherColors.purple.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(ZipherRadius.sm),
            ),
            child: Icon(Icons.shield_outlined, size: 20, color: ZipherColors.purple),
          ),
          const Gap(12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your voting weight',
                  style: TextStyle(fontSize: 11, color: ZipherColors.text40),
                ),
                const Gap(2),
                Text(
                  '${elig.eligibleZec.toStringAsFixed(4)} ZEC',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: ZipherColors.text90,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${elig.noteCount} note${elig.noteCount == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 12, color: ZipherColors.text40),
          ),
        ],
      ),
    );
  }

  Widget _buildProposalsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Proposals',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: ZipherColors.text60,
          ),
        ),
        const Gap(12),
        ..._config!.proposals.map(_buildProposal),
      ],
    );
  }

  Widget _buildProposal(VoteProposal proposal) {
    final selected = _selections[proposal.id];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            proposal.title,
            style: TextStyle(
              color: ZipherColors.text90,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Gap(12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: proposal.options.map((option) {
              final isSelected = selected == option.index;
              return GestureDetector(
                onTap: () => setState(() => _selections[proposal.id] = option.index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? ZipherColors.purple.withValues(alpha: 0.2)
                        : ZipherColors.surfaceLight,
                    borderRadius: BorderRadius.circular(ZipherRadius.sm),
                    border: Border.all(
                      color: isSelected ? ZipherColors.purple : ZipherColors.borderSubtle,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    option.label,
                    style: TextStyle(
                      color: isSelected ? ZipherColors.purple : ZipherColors.text60,
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
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
    final allSelected = _selections.length == _config!.proposals.length;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: allSelected ? _submitVote : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: ZipherColors.purple,
          disabledBackgroundColor: ZipherColors.surfaceLight,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZipherRadius.md),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: Text(
          allSelected
              ? 'Cast Shielded Vote'
              : 'Select all proposals to vote',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildNotEligible() {
    return _infoCard(
      icon: Icons.info_outline_rounded,
      iconColor: ZipherColors.warm,
      title: 'Not eligible',
      subtitle: 'You don\'t have shielded Orchard notes at the snapshot height '
          '(${_config!.snapshotHeight}). Shield some ZEC before the snapshot cutoff '
          'to participate in future rounds.',
    );
  }

  Widget _buildRoundStatus() {
    return _infoCard(
      icon: Icons.schedule_rounded,
      iconColor: ZipherColors.text40,
      title: 'Round ${_config!.statusLabel.toLowerCase()}',
      subtitle: _config!.status == 2
          ? 'Votes are being tallied. Results will appear here once finalized.'
          : _config!.status == 3
              ? 'This round is finalized. Results are available.'
              : 'This round is pending. Voting hasn\'t started yet.',
      action: _config!.status == 3
          ? TextButton(onPressed: () {/* TODO: show results */}, child: const Text('View Results'))
          : null,
    );
  }

  Widget _buildVoteError() {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(color: ZipherColors.red.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: ZipherColors.red),
          const Gap(8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _voteError!,
                  style: TextStyle(fontSize: 12, color: ZipherColors.text60),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                const Gap(4),
                GestureDetector(
                  onTap: () => setState(() => _voteError = null),
                  child: Text(
                    'Dismiss',
                    style: TextStyle(fontSize: 12, color: ZipherColors.purple, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              value: _progressValue > 0 ? _progressValue : null,
              valueColor: AlwaysStoppedAnimation(ZipherColors.purple),
            ),
          ),
          const Gap(16),
          Text(
            _progressPhase,
            style: TextStyle(color: ZipherColors.text60, fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const Gap(4),
          Text(
            'Your vote is private. Funds never leave your wallet.',
            style: TextStyle(color: ZipherColors.text20, fontSize: 11),
          ),
          if (_progressValue > 0) ...[
            const Gap(12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progressValue,
                backgroundColor: ZipherColors.surfaceLight,
                valueColor: AlwaysStoppedAnimation(ZipherColors.purple),
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
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.green.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Icon(Icons.check_circle_rounded, color: ZipherColors.green, size: 36),
          const Gap(12),
          Text(
            'Vote recorded',
            style: TextStyle(
              color: ZipherColors.text90,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(4),
          Text(
            'Your shielded vote has been submitted on-chain with ZKP proofs.',
            textAlign: TextAlign.center,
            style: TextStyle(color: ZipherColors.text40, fontSize: 13),
          ),
          if (_resultSummary != null) ...[
            const Gap(12),
            Text(
              _resultSummary!,
              textAlign: TextAlign.center,
              style: TextStyle(color: ZipherColors.text60, fontSize: 12),
            ),
          ],
          const Gap(16),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Icon(icon, size: 36, color: iconColor),
          const Gap(12),
          Text(
            title,
            style: TextStyle(
              color: ZipherColors.text90,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: ZipherColors.text40, fontSize: 13, height: 1.4),
          ),
          if (action != null) ...[
            const Gap(8),
            action,
          ],
        ],
      ),
    );
  }

  // =========================================================================
  // Vote submission
  // =========================================================================

  Future<void> _submitVote() async {
    setState(() {
      _voting = true;
      _voteError = null;
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

      // Phase 1: Delegation (ZKP1)
      updateProgress('delegation', 0.0);
      final delegations = await VotingService.instance.performDelegation(
        seedPhrase: seedPhrase,
        onProgress: updateProgress,
      );

      // Phase 2: Submit delegations to chain
      final vanPositions = <int>[];
      for (int i = 0; i < delegations.length; i++) {
        updateProgress('submitting', i / delegations.length);
        final result = await VotingService.instance.submitDelegation(delegations[i]);
        if (result.vanPosition != null) {
          vanPositions.add(result.vanPosition!);
        } else {
          vanPositions.add(i);
        }
      }

      // Phase 3: Sync vote commitment tree + get VAN witnesses
      updateProgress('tree_sync', 0.0);
      final witnesses = await VotingService.instance.syncTreeAndWitness(vanPositions);
      if (witnesses.isEmpty) {
        throw Exception('Failed to generate VAN witnesses from commitment tree');
      }
      final witness = witnesses.first;

      // Phase 4: Vote commitment (ZKP2) + submission
      final votingSeed = await rust_engine.engineVoteDeriveSeedFromPhrase(
        seedPhrase: seedPhrase,
      );

      updateProgress('voting', 0.0);
      for (final entry in _selections.entries) {
        final proposal = _config!.proposals.firstWhere((p) => p.id == entry.key);
        await VotingService.instance.castVote(
          votingSeed: votingSeed.toList(),
          proposalId: entry.key,
          choice: entry.value,
          numOptions: proposal.options.length,
          vanCommRand: delegations.first.vanCommRand,
          totalValue: delegations.first.totalValue.toInt(),
          vanAuthPath: witness.authPath,
          vanPosition: witness.position,
          anchorHeight: witness.anchorHeight,
          onProgress: (phase, progress) => updateProgress('voting', progress),
        );
      }

      final summary = _selections.entries.map((e) {
        final proposal = _config!.proposals.firstWhere((p) => p.id == e.key);
        final option = proposal.options.firstWhere((o) => o.index == e.value);
        return '${proposal.title}: ${option.label}';
      }).join('\n');

      setState(() {
        _voting = false;
        _done = true;
        _resultSummary = summary;
      });
    } catch (e) {
      setState(() {
        _voting = false;
        _voteError = e.toString();
      });
    }
  }

  String _phaseLabel(String phase) {
    switch (phase) {
      case 'delegation': return 'Building delegation proof...';
      case 'submitting': return 'Submitting to chain...';
      case 'tree_sync': return 'Syncing vote commitment tree...';
      case 'voting': return 'Generating vote proofs...';
      case 'commitment': return 'Building vote commitment...';
      case 'signing': return 'Signing transaction...';
      case 'confirming': return 'Confirming on chain...';
      case 'complete': return 'Complete';
      default: return phase;
    }
  }
}
