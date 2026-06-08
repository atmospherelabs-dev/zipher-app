import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/frost_service.dart';
import '../../services/wallet_service.dart';
import '../../zipher_theme.dart';
import '../scan.dart';
import 'frost_backup_share.dart';

enum FrostSetupUseCase { personalRecovery, sharedBusiness, agentWallet }

class FrostCreatePage extends StatefulWidget {
  const FrostCreatePage({super.key});

  @override
  State<FrostCreatePage> createState() => _FrostCreatePageState();
}

class _FrostCreatePageState extends State<FrostCreatePage> {
  FrostSetupUseCase _useCase = FrostSetupUseCase.personalRecovery;
  int _threshold = 2;
  int _participants = 3;
  bool _advancedRelay = false;
  final _relayController =
      TextEditingController(text: FrostService.defaultRelay);
  FrostInvite? _invite;
  FrostCoordinatorPending? _pendingCoordinator;
  final _joinResponseController = TextEditingController();
  bool _thresholdLocked = false;
  bool _creating = false;
  String? _createdAddress;
  String? _backupKeyPackage;
  bool _backupSaved = false;

  @override
  void dispose() {
    _joinResponseController.dispose();
    _relayController.dispose();
    super.dispose();
  }

  void _applyUseCaseDefaults(FrostSetupUseCase useCase) {
    _useCase = useCase;
    _invite = null;
    _thresholdLocked = false;
    _pendingCoordinator = null;
    _createdAddress = null;
    _backupKeyPackage = null;
    _backupSaved = false;
    switch (useCase) {
      case FrostSetupUseCase.personalRecovery:
      case FrostSetupUseCase.agentWallet:
        _threshold = 2;
        _participants = 3;
        break;
      case FrostSetupUseCase.sharedBusiness:
        _threshold = 2;
        _participants = 3;
        break;
    }
  }

  String get _relayUrl => _relayController.text.trim().isEmpty
      ? FrostService.defaultRelay
      : _relayController.text.trim();

  bool get _relayLooksSafe =>
      _relayUrl.startsWith('https://') ||
      _relayUrl.startsWith('http://127.0.0.1') ||
      _relayUrl.startsWith('http://localhost');

  List<_ParticipantRow> get _participantRows {
    switch (_useCase) {
      case FrostSetupUseCase.personalRecovery:
        return const [
          _ParticipantRow('This phone', 'Creator', true),
          _ParticipantRow('Recovery device', 'Co-signer', false),
          _ParticipantRow('Backup share', 'Backup', false),
        ];
      case FrostSetupUseCase.agentWallet:
        return const [
          _ParticipantRow('This phone', 'Approval', true),
          _ParticipantRow('Agent', 'Co-signer', false),
          _ParticipantRow('Backup share', 'Backup', false),
        ];
      case FrostSetupUseCase.sharedBusiness:
        return [
          const _ParticipantRow('You', 'Creator', true),
          for (var i = 2; i <= _participants; i++)
            _ParticipantRow('Signer $i', 'Pending', false),
        ];
    }
  }

  String get _label {
    switch (_useCase) {
      case FrostSetupUseCase.personalRecovery:
        return 'Personal recovery wallet';
      case FrostSetupUseCase.sharedBusiness:
        return 'Shared business wallet';
      case FrostSetupUseCase.agentWallet:
        return 'Agent approval wallet';
    }
  }

  Future<void> _createInvite() async {
    setState(() => _creating = true);
    try {
      final pending = await FrostService.instance.beginRelayCoordinator(
        label: _label,
        relay: _relayUrl,
      );
      if (!mounted) return;
      setState(() {
        _pendingCoordinator = pending;
        _invite = pending.invite;
        _creating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not create invite: $e',
              style: TextStyle(color: ZipherColors.text90)),
          backgroundColor: ZipherColors.surface,
        ),
      );
    }
  }

  Future<void> _scanJoinResponse() async {
    final code = await scanQRCode(context);
    if (code.isNotEmpty) {
      _joinResponseController.text = code;
    }
  }

  Future<void> _acceptJoinResponse() async {
    if (_creating || !_thresholdLocked) return;
    setState(() => _creating = true);
    try {
      int birthday = 0;
      try {
        birthday = await WalletService.instance.getLatestBlockHeight();
      } catch (_) {}
      final response = FrostJoinResponse.decode(_joinResponseController.text);
      final result = await FrostService.instance.coordinatorAcceptJoin(
        response: response,
        walletName: _label,
        birthday: birthday,
        chainType: WalletService.instance.isTestnetChain,
        importUfvk: (ufvk, birthday) => WalletService.instance
            .importFrostUfvkWallet(_label, ufvk, birthday),
      );
      if (!mounted) return;
      setState(() {
        _createdAddress = result.address;
        _backupKeyPackage = result.backupKeyPackage;
        _backupSaved = result.backupKeyPackage == null;
        _creating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not complete FROST setup: $e',
              style: TextStyle(color: ZipherColors.text90)),
          backgroundColor: ZipherColors.surface,
        ),
      );
    }
  }

  Future<void> _copyInvite() async {
    final invite = _invite;
    if (invite == null) return;
    await Clipboard.setData(ClipboardData(text: invite.encode()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Invite copied', style: TextStyle(color: ZipherColors.text90)),
        backgroundColor: ZipherColors.surface,
      ),
    );
  }

  Future<void> _completeLocalSetup() async {
    if (_creating || !_thresholdLocked) return;
    setState(() => _creating = true);
    try {
      int birthday = 0;
      try {
        birthday = await WalletService.instance.getLatestBlockHeight();
      } catch (_) {}
      final result = await WalletService.instance.createFrostWallet(
        _label,
        birthday,
      );
      if (!mounted) return;
      setState(() {
        _createdAddress = result.address;
        _backupKeyPackage = result.backupKeyPackage;
        _backupSaved = result.backupKeyPackage == null;
        _creating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('FROST setup failed: $e',
              style: TextStyle(color: ZipherColors.text90)),
          backgroundColor: ZipherColors.surface,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: Text(
          'Create shared wallet',
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
          children: [
            _Hero(),
            const Gap(24),
            _SectionTitle('1. Choose setup'),
            const Gap(10),
            _UseCasePicker(
              selected: _useCase,
              onChanged: (v) => setState(() => _applyUseCaseDefaults(v)),
            ),
            const Gap(22),
            _SectionTitle('2. Choose threshold'),
            const Gap(10),
            _ThresholdCard(
              threshold: _threshold,
              participants: _participants,
              locked: _thresholdLocked,
              useCase: _useCase,
              onChanged: (t, n) => setState(() {
                _threshold = t;
                _participants = n;
                _invite = null;
              }),
            ),
            const Gap(22),
            _SectionTitle(_useCase == FrostSetupUseCase.agentWallet
                ? '3. Pair agent'
                : '3. Invite co-signers'),
            const Gap(10),
            _AdvancedRelayCard(
              expanded: _advancedRelay,
              controller: _relayController,
              relayLooksSafe: _relayLooksSafe,
              onToggle: () => setState(() => _advancedRelay = !_advancedRelay),
              onChanged: (_) => setState(() {
                _invite = null;
                _pendingCoordinator = null;
                _thresholdLocked = false;
              }),
            ),
            const Gap(10),
            if (invite == null)
              _PrimaryButton(
                label: _creating ? 'Creating...' : 'Create relay invite',
                icon: Icons.qr_code_2_rounded,
                onTap: _creating || !_relayLooksSafe ? null : _createInvite,
              )
            else
              _InviteCard(invite: invite, onCopy: _copyInvite),
            const Gap(22),
            _SectionTitle('4. Accept co-signer response'),
            const Gap(10),
            if (_pendingCoordinator != null && _createdAddress == null) ...[
              _ExplainerCard(
                text:
                    'Ask the co-signer to scan your invite. They will show a join response. Scan or paste that response here before locking the threshold.',
              ),
              const Gap(10),
              _Field(
                label: 'Co-signer response',
                controller: _joinResponseController,
                hint: 'zipher:frost-join:v1:...',
                maxLines: 3,
              ),
              const Gap(10),
              Row(
                children: [
                  Expanded(
                    child: _SecondaryButton(
                      label: 'Scan response',
                      icon: Icons.qr_code_scanner_rounded,
                      onTap: _scanJoinResponse,
                    ),
                  ),
                  const Gap(10),
                  Expanded(
                    child: _SecondaryButton(
                      label: 'Clear',
                      icon: Icons.close_rounded,
                      onTap: () =>
                          setState(() => _joinResponseController.clear()),
                    ),
                  ),
                ],
              ),
              const Gap(10),
            ],
            _RosterCard(
              participants: _participantRows,
            ),
            const Gap(22),
            _SectionTitle('5. Lock threshold'),
            const Gap(10),
            _LockCard(
              threshold: _threshold,
              participants: _participants,
              locked: _thresholdLocked,
              enabled: invite != null,
              onLock: () => setState(() => _thresholdLocked = true),
            ),
            const Gap(22),
            _SectionTitle('6. Ceremony'),
            const Gap(10),
            _ProgressCard(
              locked: _thresholdLocked,
              creating: _creating,
              createdAddress: _createdAddress,
              onComplete: _pendingCoordinator != null
                  ? _acceptJoinResponse
                  : _completeLocalSetup,
              steps: const [
                'Participants',
                'Create shares',
                'Backup',
                'Birthday',
                'Ready',
              ],
            ),
            if (_createdAddress != null) ...[
              if (_backupKeyPackage != null && !_backupSaved) ...[
                const Gap(16),
                FrostBackupShareStep(
                  backupKeyPackage: _backupKeyPackage!,
                  onSaved: () => setState(() => _backupSaved = true),
                ),
              ],
              if (_backupSaved) ...[
                const Gap(16),
                _PrimaryButton(
                  label: 'Open wallet',
                  icon: Icons.arrow_forward_rounded,
                  onTap: () => GoRouter.of(context).go('/account'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.group_rounded, size: 22, color: ZipherColors.cyan),
        const Gap(18),
        Text(
          'Shared wallet',
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
          ),
        ),
        const Gap(8),
        Text(
          'Create a wallet where spending requires multiple approvals. No single device ever holds the full spending key.',
          style: TextStyle(
            color: ZipherColors.text60,
            fontSize: 14,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _UseCasePicker extends StatelessWidget {
  final FrostSetupUseCase selected;
  final ValueChanged<FrostSetupUseCase> onChanged;

  const _UseCasePicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ChoiceTile(
          title: 'Personal recovery',
          subtitle: 'Your phone, a backup share, and a recovery device.',
          selected: selected == FrostSetupUseCase.personalRecovery,
          onTap: () => onChanged(FrostSetupUseCase.personalRecovery),
        ),
        const Gap(8),
        _ChoiceTile(
          title: 'Shared business',
          subtitle: 'A treasury that requires multiple people to approve.',
          selected: selected == FrostSetupUseCase.sharedBusiness,
          onTap: () => onChanged(FrostSetupUseCase.sharedBusiness),
        ),
        const Gap(8),
        _ChoiceTile(
          title: 'Agent wallet',
          subtitle: 'Agent can propose, but your phone must co-sign.',
          selected: selected == FrostSetupUseCase.agentWallet,
          onTap: () => onChanged(FrostSetupUseCase.agentWallet),
        ),
      ],
    );
  }
}

class _ThresholdCard extends StatelessWidget {
  final int threshold;
  final int participants;
  final bool locked;
  final FrostSetupUseCase useCase;
  final void Function(int threshold, int participants) onChanged;

  const _ThresholdCard({
    required this.threshold,
    required this.participants,
    required this.locked,
    required this.useCase,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isAgent = useCase == FrostSetupUseCase.agentWallet;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAgent
                ? 'Recommended: 2 of 3. Agent can propose, but cannot spend without phone approval.'
                : 'Recommended: 2 of 3. You can change this before locking.',
            style: TextStyle(
                color: ZipherColors.text40, fontSize: 12, height: 1.35),
          ),
          const Gap(12),
          Row(
            children: [
              Expanded(
                child: _ThresholdChip(
                  label: '2 of 3',
                  selected: threshold == 2 && participants == 3,
                  locked: locked,
                  onTap: () => onChanged(2, 3),
                ),
              ),
              const Gap(8),
              Expanded(
                child: _ThresholdChip(
                  label: '2 of 2',
                  selected: threshold == 2 && participants == 2,
                  locked: locked || isAgent,
                  onTap: () => onChanged(2, 2),
                ),
              ),
              const Gap(8),
              Expanded(
                child: _ThresholdChip(
                  label: '3 of 5',
                  selected: threshold == 3 && participants == 5,
                  locked: locked || isAgent,
                  onTap: () => onChanged(3, 5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AdvancedRelayCard extends StatelessWidget {
  final bool expanded;
  final TextEditingController controller;
  final bool relayLooksSafe;
  final VoidCallback onToggle;
  final ValueChanged<String> onChanged;

  const _AdvancedRelayCard({
    required this.expanded,
    required this.controller,
    required this.relayLooksSafe,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onToggle,
            child: Row(
              children: [
                Icon(Icons.router_rounded,
                    size: 18, color: ZipherColors.text60),
                const Gap(8),
                Expanded(
                  child: Text(
                    'Relay',
                    style: TextStyle(
                      color: ZipherColors.text90,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  expanded ? 'Hide' : 'Advanced',
                  style: TextStyle(color: ZipherColors.cyan, fontSize: 12),
                ),
              ],
            ),
          ),
          const Gap(6),
          Text(
            controller.text.trim().isEmpty
                ? FrostService.defaultRelay
                : controller.text.trim(),
            style: TextStyle(
              color: ZipherColors.text40,
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (expanded) ...[
            const Gap(12),
            TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(color: ZipherColors.text90, fontSize: 13),
              decoration: InputDecoration(
                hintText: FrostService.defaultRelay,
                hintStyle: TextStyle(color: ZipherColors.text20),
                filled: true,
                fillColor: ZipherColors.cardBgElevated,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(ZipherRadius.md),
                  borderSide: BorderSide(color: ZipherColors.borderSubtle),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(ZipherRadius.md),
                  borderSide: BorderSide(color: ZipherColors.borderSubtle),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(ZipherRadius.md),
                  borderSide: BorderSide(
                      color: ZipherColors.cyan.withValues(alpha: 0.35)),
                ),
              ),
            ),
            const Gap(8),
            Text(
              relayLooksSafe
                  ? 'Use the default relay unless you run your own.'
                  : 'Use HTTPS for remote relays. HTTP is only allowed for localhost development.',
              style: TextStyle(
                color: relayLooksSafe ? ZipherColors.text40 : ZipherColors.red,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExplainerCard extends StatelessWidget {
  final String text;
  const _ExplainerCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: ZipherColors.cyan),
          const Gap(10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: ZipherColors.text60,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  final FrostInvite invite;
  final VoidCallback onCopy;

  const _InviteCard({required this.invite, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final encoded = invite.encode();
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(ZipherRadius.md),
            ),
            child: QrImage(
              data: encoded,
              version: QrVersions.auto,
              size: 210,
            ),
          ),
          const Gap(14),
          Text(
            invite.label,
            style: TextStyle(
              color: ZipherColors.text90,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Gap(4),
          Text(
            '${invite.threshold} of ${invite.participants} • ${invite.relay}',
            style: TextStyle(color: ZipherColors.text40, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
          const Gap(12),
          _SecondaryButton(
            label: 'Copy invite',
            icon: Icons.copy_rounded,
            onTap: onCopy,
          ),
        ],
      ),
    );
  }
}

class _RosterCard extends StatelessWidget {
  final List<_ParticipantRow> participants;
  const _RosterCard({required this.participants});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        children: [
          for (var i = 0; i < participants.length; i++) ...[
            participants[i],
            if (i != participants.length - 1)
              Divider(height: 22, color: ZipherColors.borderSubtle),
          ],
        ],
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  final String name;
  final String role;
  final bool active;

  const _ParticipantRow(this.name, this.role, this.active);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          active ? Icons.account_circle_rounded : Icons.hourglass_empty_rounded,
          size: 18,
          color: active ? ZipherColors.cyan : ZipherColors.text20,
        ),
        const Gap(10),
        Expanded(
          child: Text(
            name,
            style: TextStyle(color: ZipherColors.text90, fontSize: 14),
          ),
        ),
        Text(
          role,
          style: TextStyle(color: ZipherColors.text40, fontSize: 12),
        ),
      ],
    );
  }
}

class _LockCard extends StatelessWidget {
  final int threshold;
  final int participants;
  final bool locked;
  final bool enabled;
  final VoidCallback onLock;

  const _LockCard({
    required this.threshold,
    required this.participants,
    required this.locked,
    required this.enabled,
    required this.onLock,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            locked
                ? 'Threshold locked: $threshold of $participants'
                : 'Review participants before locking. After this, DKG starts and the roster cannot change.',
            style: TextStyle(
              color: locked ? ZipherColors.green : ZipherColors.text60,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const Gap(12),
          _PrimaryButton(
            label: locked ? 'Locked' : 'Lock threshold',
            icon: locked ? Icons.lock_rounded : Icons.lock_open_rounded,
            onTap: enabled && !locked ? onLock : null,
          ),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final bool locked;
  final bool creating;
  final String? createdAddress;
  final VoidCallback onComplete;
  final List<String> steps;

  const _ProgressCard({
    required this.locked,
    required this.creating,
    required this.createdAddress,
    required this.onComplete,
    required this.steps,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 12),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: locked && i == 0
                          ? ZipherColors.cyan.withValues(alpha: 0.12)
                          : ZipherColors.cardBgElevated,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      locked && i == 0
                          ? Icons.play_arrow_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 14,
                      color: locked && i == 0
                          ? ZipherColors.cyan
                          : ZipherColors.text20,
                    ),
                  ),
                  const Gap(10),
                  Text(
                    steps[i],
                    style: TextStyle(
                      color: locked && i == 0
                          ? ZipherColors.text90
                          : ZipherColors.text40,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          const Gap(14),
          if (createdAddress == null)
            _PrimaryButton(
              label: creating ? 'Creating wallet...' : 'Complete setup',
              icon: Icons.auto_awesome_rounded,
              onTap: locked && !creating ? onComplete : null,
            )
          else ...[
            Divider(color: ZipherColors.borderSubtle),
            const Gap(10),
            Text(
              'FROST wallet created',
              style: TextStyle(
                color: ZipherColors.green,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Gap(6),
            SelectableText(
              createdAddress!,
              style: TextStyle(
                color: ZipherColors.text60,
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
              ),
            ),
            const Gap(8),
            Text(
              'This device stores one FROST share. Spending requires another co-signer share.',
              style: TextStyle(color: ZipherColors.text40, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: _Card(
        selected: selected,
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              color: selected ? ZipherColors.cyan : ZipherColors.text20,
              size: 20,
            ),
            const Gap(12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: ZipherColors.text90,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Gap(3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: ZipherColors.text40,
                      fontSize: 12,
                      height: 1.35,
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
}

class _ThresholdChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  const _ThresholdChip({
    required this.label,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: locked ? null : onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? ZipherColors.cyan.withValues(alpha: 0.12)
              : ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.full),
          border: Border.all(
            color: selected
                ? ZipherColors.cyan.withValues(alpha: 0.25)
                : ZipherColors.borderSubtle,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? ZipherColors.cyan : ZipherColors.text60,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: ZipherColors.text40, fontSize: 13)),
        const Gap(8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: TextStyle(color: ZipherColors.text90, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: ZipherColors.text20),
            filled: true,
            fillColor: ZipherColors.cardBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              borderSide: BorderSide(color: ZipherColors.borderSubtle),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              borderSide: BorderSide(color: ZipherColors.borderSubtle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              borderSide:
                  BorderSide(color: ZipherColors.cyan.withValues(alpha: 0.35)),
            ),
          ),
        ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: onTap == null
              ? ZipherColors.cardBgElevated
              : ZipherColors.cyan.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(
            color: onTap == null
                ? ZipherColors.borderSubtle
                : ZipherColors.cyan.withValues(alpha: 0.28),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 18,
                color: onTap == null ? ZipherColors.text20 : ZipherColors.cyan),
            const Gap(8),
            Text(
              label,
              style: TextStyle(
                color: onTap == null ? ZipherColors.text20 : ZipherColors.cyan,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _SecondaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: ZipherColors.text60),
            const Gap(8),
            Text(
              label,
              style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: ZipherColors.text60,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final bool selected;

  const _Card({required this.child, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: selected
            ? ZipherColors.cyan.withValues(alpha: 0.06)
            : ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(
          color: selected
              ? ZipherColors.cyan.withValues(alpha: 0.18)
              : ZipherColors.borderSubtle,
        ),
      ),
      child: child,
    );
  }
}
