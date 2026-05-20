import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../services/agent_policy.dart';
import '../../zipher_theme.dart';

/// Agent Wallet hub.
///
/// V1 ships a *draft* policy editor — the policy lives in mobile prefs and
/// can be exported as TOML for the user to drop into their CLI host. Pairing
/// and remote approvals arrive in V2 (relay or APNS push).
///
/// Why this is shipped before pairing exists: the most common question is
/// "what *can* the agent do with my money?" — the editor lets the user
/// answer that decisively on the device they already trust, and creates a
/// reviewable artifact to copy onto the server.
class AgentWalletPage extends StatefulWidget {
  const AgentWalletPage({super.key});

  @override
  State<AgentWalletPage> createState() => _AgentWalletPageState();
}

class _AgentWalletPageState extends State<AgentWalletPage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AgentPolicyStore.instance.load();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        title: Text('Agent Wallet',
            style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              color: ZipherColors.text60, size: 18),
          onPressed: () => GoRouter.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: ZipherColors.pagePadding,
                  vertical: ZipherSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Hero(),
                    const Gap(ZipherSpacing.lg),
                    _SectionLabel('Paired agents'),
                    const Gap(ZipherSpacing.sm),
                    _PairedAgentsCard(),
                    const Gap(ZipherSpacing.lg),
                    _SectionLabel('Spending policy'),
                    const Gap(ZipherSpacing.sm),
                    _PolicyCard(
                      onChanged: () => setState(() {}),
                    ),
                    const Gap(ZipherSpacing.md),
                    _ExportButton(),
                    const Gap(ZipherSpacing.lg),
                    _SectionLabel('Get started'),
                    const Gap(ZipherSpacing.sm),
                    _GetStartedCard(),
                    const Gap(ZipherSpacing.lg),
                    Text(
                      'Pairing the agent to your phone — including remote approvals for high-value transactions — lands in the next release.',
                      style: TextStyle(
                        color: ZipherColors.text40,
                        fontSize: 11,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const Gap(ZipherSpacing.md),
                  ],
                ),
              ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ZipherSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            ZipherColors.cyan.withValues(alpha: 0.10),
            ZipherColors.warm.withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: ZipherColors.primaryGradient,
                  borderRadius: BorderRadius.circular(ZipherRadius.sm),
                ),
                child: Icon(Icons.smart_toy_outlined,
                    color: ZipherColors.bg, size: 20),
              ),
              const Gap(ZipherSpacing.smMd),
              Expanded(
                child: Text(
                  'Your AI agent. Your rules.',
                  style: TextStyle(
                    color: ZipherColors.text90,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const Gap(ZipherSpacing.smMd),
          Text(
            'Run a Zipher agent on your laptop or server. It transacts on your behalf — sweeping balances, paying invoices, placing bets — within the spending limits you set here.',
            style: TextStyle(
              color: ZipherColors.text60,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: ZipherColors.text40,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _PairedAgentsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ZipherSpacing.md),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: ZipherColors.cardBgElevated,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.link_off_rounded,
                color: ZipherColors.text40, size: 20),
          ),
          const Gap(ZipherSpacing.smMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('No agents paired yet',
                    style: TextStyle(
                      color: ZipherColors.text90,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    )),
                const Gap(2),
                Text(
                  'Draft your policy below — pairing arrives in V2.',
                  style: TextStyle(
                      color: ZipherColors.text60,
                      fontSize: 12,
                      height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicyCard extends StatefulWidget {
  final VoidCallback onChanged;
  const _PolicyCard({required this.onChanged});

  @override
  State<_PolicyCard> createState() => _PolicyCardState();
}

class _PolicyCardState extends State<_PolicyCard> {
  late AgentPolicy _draft;

  @override
  void initState() {
    super.initState();
    _draft = AgentPolicyStore.instance.policy;
  }

  Future<void> _commit(AgentPolicy next) async {
    setState(() => _draft = next);
    await AgentPolicyStore.instance.save(next);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        children: [
          _AmountRow(
            label: 'Per-transaction cap',
            sublabel: 'Largest single payment the agent can sign',
            valueZat: _draft.maxPerTxZat,
            onChanged: (zat) => _commit(_draft.copyWith(maxPerTxZat: zat)),
          ),
          _divider(),
          _AmountRow(
            label: 'Daily limit',
            sublabel: 'Total it can spend in any 24h window',
            valueZat: _draft.dailyLimitZat,
            onChanged: (zat) => _commit(_draft.copyWith(dailyLimitZat: zat)),
          ),
          _divider(),
          _AmountRow(
            label: 'Ask for approval above',
            sublabel: 'Anything larger needs your tap',
            valueZat: _draft.approvalThresholdZat,
            onChanged: (zat) =>
                _commit(_draft.copyWith(approvalThresholdZat: zat)),
          ),
          _divider(),
          _SwitchRow(
            label: 'Require context tag',
            sublabel: 'Each spend must carry a labelled reason',
            value: _draft.requireContextId,
            onChanged: (v) => _commit(_draft.copyWith(requireContextId: v)),
          ),
          _divider(),
          _AllowlistRow(
            count: _draft.allowlist.length,
            onTap: () async {
              final updated = await showModalBottomSheet<List<String>>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) =>
                    _AllowlistSheet(initial: _draft.allowlist),
              );
              if (updated != null) {
                _commit(_draft.copyWith(allowlist: updated));
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _divider() => Divider(
        height: 1,
        thickness: 0.5,
        color: ZipherColors.borderSubtle,
        indent: ZipherSpacing.md,
        endIndent: ZipherSpacing.md,
      );
}

class _AmountRow extends StatelessWidget {
  final String label;
  final String sublabel;
  final int valueZat;
  final ValueChanged<int> onChanged;

  const _AmountRow({
    required this.label,
    required this.sublabel,
    required this.valueZat,
    required this.onChanged,
  });

  String _formatZec() {
    if (valueZat == 0) return '∞';
    final zec = valueZat / 100000000;
    if (zec >= 1) return zec.toStringAsFixed(zec.truncateToDouble() == zec ? 0 : 4);
    return zec.toStringAsFixed(8);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: ZipherSpacing.md, vertical: ZipherSpacing.sm),
      title: Text(label,
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          )),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(sublabel,
            style: TextStyle(
                color: ZipherColors.text40, fontSize: 12, height: 1.3)),
      ),
      trailing: GestureDetector(
        onTap: () async {
          final next = await _showAmountSheet(context, label, valueZat);
          if (next != null) onChanged(next);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: ZipherColors.cardBgElevated,
            borderRadius: BorderRadius.circular(ZipherRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_formatZec()} ZEC',
                style: TextStyle(
                  color: ZipherColors.text90,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
              const Gap(4),
              Icon(Icons.chevron_right_rounded,
                  color: ZipherColors.text40, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

Future<int?> _showAmountSheet(
    BuildContext context, String label, int currentZat) async {
  final controller = TextEditingController(
    text: currentZat == 0 ? '' : (currentZat / 100000000).toString(),
  );
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        ),
        child: Container(
          padding: const EdgeInsets.all(ZipherSpacing.lg),
          decoration: BoxDecoration(
            color: ZipherColors.surface,
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label,
                  style: TextStyle(
                      color: ZipherColors.text90,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const Gap(ZipherSpacing.sm),
              Text('Amount in ZEC. Leave blank for unlimited.',
                  style: TextStyle(
                      color: ZipherColors.text60, fontSize: 13)),
              const Gap(ZipherSpacing.md),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                style: TextStyle(
                  color: ZipherColors.text90,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'JetBrainsMono',
                ),
                decoration: InputDecoration(
                  suffixText: 'ZEC',
                  suffixStyle: TextStyle(
                    color: ZipherColors.text40,
                    fontSize: 14,
                  ),
                  hintText: '0',
                  hintStyle: TextStyle(
                      color: ZipherColors.text20, fontSize: 24),
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.md),
                    borderSide:
                        BorderSide(color: ZipherColors.borderSubtle),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.md),
                    borderSide:
                        BorderSide(color: ZipherColors.borderSubtle),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.md),
                    borderSide:
                        BorderSide(color: ZipherColors.cyan, width: 1),
                  ),
                ),
              ),
              const Gap(ZipherSpacing.lg),
              GestureDetector(
                onTap: () {
                  final raw = controller.text.trim();
                  if (raw.isEmpty) {
                    Navigator.of(sheetCtx).pop(0);
                    return;
                  }
                  final zec = double.tryParse(raw);
                  if (zec == null || zec < 0) {
                    Navigator.of(sheetCtx).pop();
                    return;
                  }
                  Navigator.of(sheetCtx).pop((zec * 100000000).round());
                },
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: ZipherColors.primaryGradient,
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.md),
                  ),
                  alignment: Alignment.center,
                  child: Text('Save',
                      style: TextStyle(
                          color: ZipherColors.bg,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              const Gap(ZipherSpacing.sm),
            ],
          ),
        ),
      );
    },
  );
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: ZipherSpacing.md, vertical: ZipherSpacing.sm),
      title: Text(label,
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          )),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(sublabel,
            style: TextStyle(
                color: ZipherColors.text40, fontSize: 12, height: 1.3)),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: ZipherColors.cyan,
      ),
    );
  }
}

class _AllowlistRow extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _AllowlistRow({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: ZipherSpacing.md, vertical: ZipherSpacing.sm),
      title: Text('Destination allowlist',
          style: TextStyle(
            color: ZipherColors.text90,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          )),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          count == 0
              ? 'Any address — tap to restrict'
              : '$count address${count == 1 ? '' : 'es'}',
          style: TextStyle(
              color: ZipherColors.text40, fontSize: 12, height: 1.3),
        ),
      ),
      trailing: Icon(Icons.chevron_right_rounded,
          color: ZipherColors.text40, size: 18),
    );
  }
}

class _AllowlistSheet extends StatefulWidget {
  final List<String> initial;
  const _AllowlistSheet({required this.initial});

  @override
  State<_AllowlistSheet> createState() => _AllowlistSheetState();
}

class _AllowlistSheetState extends State<_AllowlistSheet> {
  late List<String> _entries;
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _entries = [...widget.initial];
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final v = _controller.text.trim();
    if (v.isEmpty || _entries.contains(v)) return;
    setState(() {
      _entries.add(v);
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.all(ZipherSpacing.lg),
        decoration: BoxDecoration(
          color: ZipherColors.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Allowed destinations',
                style: TextStyle(
                    color: ZipherColors.text90,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const Gap(ZipherSpacing.xs),
            Text(
              'If empty, agent can pay any address. Useful for self-paying loops (sweep to your own shielded address).',
              style: TextStyle(
                  color: ZipherColors.text60,
                  fontSize: 12,
                  height: 1.5),
            ),
            const Gap(ZipherSpacing.md),
            if (_entries.isEmpty)
              Text('No restrictions yet',
                  style: TextStyle(
                      color: ZipherColors.text40, fontSize: 13))
            else
              ..._entries.map(
                (e) => Container(
                  margin: const EdgeInsets.only(bottom: ZipherSpacing.sm),
                  padding: const EdgeInsets.symmetric(
                      horizontal: ZipherSpacing.smMd,
                      vertical: ZipherSpacing.sm),
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBgElevated,
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.md),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          e,
                          style: TextStyle(
                            color: ZipherColors.text90,
                            fontSize: 12,
                            fontFamily: 'JetBrainsMono',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _entries.remove(e)),
                        child: Icon(Icons.close_rounded,
                            color: ZipherColors.text40, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
            const Gap(ZipherSpacing.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: TextStyle(
                        color: ZipherColors.text90, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'u1zec... or t1...',
                      hintStyle: TextStyle(
                          color: ZipherColors.text20, fontSize: 13),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(ZipherRadius.md),
                        borderSide:
                            BorderSide(color: ZipherColors.borderSubtle),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(ZipherRadius.md),
                        borderSide:
                            BorderSide(color: ZipherColors.borderSubtle),
                      ),
                    ),
                  ),
                ),
                const Gap(ZipherSpacing.sm),
                GestureDetector(
                  onTap: _add,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBgElevated,
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.md),
                    ),
                    child: Icon(Icons.add_rounded,
                        color: ZipherColors.text90, size: 18),
                  ),
                ),
              ],
            ),
            const Gap(ZipherSpacing.lg),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(_entries),
              child: Container(
                height: 52,
                decoration: BoxDecoration(
                  gradient: ZipherColors.primaryGradient,
                  borderRadius:
                      BorderRadius.circular(ZipherRadius.md),
                ),
                alignment: Alignment.center,
                child: Text('Save allowlist',
                    style: TextStyle(
                        color: ZipherColors.bg,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showExportSheet(context),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.upload_rounded, color: ZipherColors.cyan, size: 18),
            const Gap(ZipherSpacing.sm),
            Text(
              'Export as TOML',
              style: TextStyle(
                color: ZipherColors.text90,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showExportSheet(BuildContext context) {
    final toml = AgentPolicyStore.instance.policy.toToml();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollCtl) => Container(
          padding: const EdgeInsets.all(ZipherSpacing.lg),
          decoration: BoxDecoration(
            color: ZipherColors.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('policy.toml',
                  style: TextStyle(
                      color: ZipherColors.text90,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'JetBrainsMono')),
              const Gap(ZipherSpacing.xs),
              Text(
                'Copy this to \$HOME/.zipher/<mainnet|testnet>/policy.toml on the host running zipher-cli.',
                style: TextStyle(
                    color: ZipherColors.text60,
                    fontSize: 12,
                    height: 1.5),
              ),
              const Gap(ZipherSpacing.md),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollCtl,
                  child: Container(
                    padding: const EdgeInsets.all(ZipherSpacing.md),
                    decoration: BoxDecoration(
                      color: ZipherColors.bg,
                      borderRadius:
                          BorderRadius.circular(ZipherRadius.md),
                      border: Border.all(
                          color: ZipherColors.borderSubtle),
                    ),
                    child: SelectableText(
                      toml,
                      style: TextStyle(
                        color: ZipherColors.text90,
                        fontSize: 12,
                        height: 1.5,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ),
                ),
              ),
              const Gap(ZipherSpacing.md),
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  Clipboard.setData(ClipboardData(text: toml));
                  ScaffoldMessenger.of(sheetCtx).showSnackBar(
                    SnackBar(
                      content: Text('Copied to clipboard',
                          style: TextStyle(
                              color: ZipherColors.text90,
                              fontSize: 13)),
                      backgroundColor: ZipherColors.bg,
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: ZipherColors.primaryGradient,
                    borderRadius:
                        BorderRadius.circular(ZipherRadius.md),
                  ),
                  alignment: Alignment.center,
                  child: Text('Copy',
                      style: TextStyle(
                          color: ZipherColors.bg,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GetStartedCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const snippet =
        'cargo install --git https://github.com/atmospherelabs/zipher zipher-cli';
    return Container(
      padding: const EdgeInsets.all(ZipherSpacing.md),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal_rounded,
                  color: ZipherColors.cyan, size: 18),
              const Gap(ZipherSpacing.sm),
              Text('Install the CLI',
                  style: TextStyle(
                    color: ZipherColors.text90,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const Gap(ZipherSpacing.smMd),
          GestureDetector(
            onTap: () {
              Clipboard.setData(const ClipboardData(text: snippet));
              HapticFeedback.selectionClick();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Copied',
                      style: TextStyle(
                          color: ZipherColors.text90, fontSize: 13)),
                  backgroundColor: ZipherColors.surface,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: ZipherSpacing.smMd,
                  vertical: ZipherSpacing.smMd),
              decoration: BoxDecoration(
                color: ZipherColors.bg,
                borderRadius:
                    BorderRadius.circular(ZipherRadius.sm),
                border:
                    Border.all(color: ZipherColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      snippet,
                      style: TextStyle(
                        color: ZipherColors.text90,
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                        height: 1.4,
                      ),
                    ),
                  ),
                  Icon(Icons.content_copy_rounded,
                      color: ZipherColors.text40, size: 14),
                ],
              ),
            ),
          ),
          const Gap(ZipherSpacing.smMd),
          Text(
            'Run `zipher wallet init` to bootstrap, then drop the exported policy at the path it prints.',
            style: TextStyle(
                color: ZipherColors.text60,
                fontSize: 12,
                height: 1.5),
          ),
        ],
      ),
    );
  }
}
