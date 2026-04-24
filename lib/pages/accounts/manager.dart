import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../zipher_theme.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet_registry.dart';
import '../utils.dart';

class AccountManagerPage extends StatefulWidget {
  final bool main;
  AccountManagerPage({required this.main});
  @override
  State<StatefulWidget> createState() => _AccountManagerState();
}

class _AccountManagerState extends State<AccountManagerPage> {
  late final s = S.of(context);
  List<WalletProfile> _wallets = [];
  bool _loading = true;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final wallets = await WalletRegistry.instance.getAll();
    if (mounted) {
      setState(() {
        _wallets = wallets;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeWalletId = WalletService.instance.activeWalletId;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'WALLET MANAGER',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon:
              Icon(Icons.arrow_back_rounded, color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        actions: [
          IconButton(
            onPressed: _addWallet,
            icon: Icon(Icons.add_rounded,
                size: 22,
                color: ZipherColors.cyan.withValues(alpha: 0.7)),
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                color: ZipherColors.cyan,
                strokeWidth: 2,
              ),
            )
          : _switching
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: ZipherColors.cyan,
                        ),
                      ),
                      const Gap(12),
                      Text(
                        'Switching account...',
                        style: TextStyle(
                          fontSize: 13,
                          color: ZipherColors.text40,
                        ),
                      ),
                    ],
                  ),
                )
              : _wallets.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.account_balance_wallet_outlined,
                              size: 40,
                              color: ZipherColors.cardBgElevated),
                          const Gap(12),
                          Text(
                            'No accounts',
                            style: TextStyle(
                              fontSize: 14,
                              color: ZipherColors.text40,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      itemCount: _wallets.length,
                      itemBuilder: (context, index) {
                        final w = _wallets[index];
                        final isActive = w.id == activeWalletId;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? ZipherColors.cyan
                                      .withValues(alpha: 0.06)
                                  : ZipherColors.cardBg,
                              borderRadius:
                                  BorderRadius.circular(ZipherRadius.lg),
                              border: isActive
                                  ? Border.all(
                                      color: ZipherColors.cyan
                                          .withValues(alpha: 0.15))
                                  : null,
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: (isActive
                                                ? ZipherColors.cyan
                                                : ZipherColors.text20)
                                            .withValues(alpha: 0.1),
                                        borderRadius:
                                            BorderRadius.circular(
                                                ZipherRadius.md),
                                      ),
                                      child: Center(
                                        child: Icon(
                                          w.isWatchOnly
                                              ? Icons.visibility_rounded
                                              : Icons
                                                  .account_balance_wallet_rounded,
                                          size: 18,
                                          color: isActive
                                              ? ZipherColors.cyan
                                                  .withValues(
                                                      alpha: 0.7)
                                              : ZipherColors.text20,
                                        ),
                                      ),
                                    ),
                                    const Gap(12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  w.name,
                                                  style: TextStyle(
                                                    fontSize: 15,
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    color: ZipherColors
                                                        .text90,
                                                  ),
                                                  overflow: TextOverflow
                                                      .ellipsis,
                                                ),
                                              ),
                                              if (w.isWatchOnly) ...[
                                                const Gap(6),
                                                Container(
                                                  padding:
                                                      const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 5,
                                                          vertical: 1),
                                                  decoration:
                                                      BoxDecoration(
                                                    color: ZipherColors
                                                        .orange
                                                        .withValues(
                                                            alpha: 0.10),
                                                    borderRadius:
                                                        BorderRadius
                                                            .circular(4),
                                                  ),
                                                  child: Text(
                                                    'Watch',
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: ZipherColors
                                                          .orange
                                                          .withValues(
                                                              alpha:
                                                                  0.7),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              if (isActive) ...[
                                                const Gap(6),
                                                Container(
                                                  padding:
                                                      const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 5,
                                                          vertical: 1),
                                                  decoration:
                                                      BoxDecoration(
                                                    color: ZipherColors
                                                        .green
                                                        .withValues(
                                                            alpha: 0.10),
                                                    borderRadius:
                                                        BorderRadius
                                                            .circular(4),
                                                  ),
                                                  child: Text(
                                                    'Active',
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: ZipherColors
                                                          .green
                                                          .withValues(
                                                              alpha:
                                                                  0.7),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const Gap(2),
                                          Text(
                                            '${amountToString2(w.lastBalance)} ZEC',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: ZipherColors.text40,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      icon: Icon(
                                        Icons.more_vert_rounded,
                                        size: 18,
                                        color: ZipherColors.text20,
                                      ),
                                      color: ZipherColors.cardBgElevated,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(
                                                ZipherRadius.md),
                                      ),
                                      onSelected: (action) =>
                                          _onWalletAction(
                                              action, w, isActive),
                                      itemBuilder: (_) => [
                                        if (!isActive)
                                          PopupMenuItem(
                                            value: 'switch',
                                            child: Row(
                                              children: [
                                                Icon(
                                                    Icons
                                                        .swap_horiz_rounded,
                                                    size: 16,
                                                    color: ZipherColors
                                                        .text60),
                                                const Gap(8),
                                                Text('Switch to',
                                                    style: TextStyle(
                                                        fontSize: 13,
                                                        color:
                                                            ZipherColors
                                                                .text90)),
                                              ],
                                            ),
                                          ),
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Row(
                                            children: [
                                              Icon(Icons.edit_rounded,
                                                  size: 16,
                                                  color: ZipherColors
                                                      .text60),
                                              const Gap(8),
                                              Text('Rename',
                                                  style: TextStyle(
                                                      fontSize: 13,
                                                      color:
                                                          ZipherColors
                                                              .text90)),
                                            ],
                                          ),
                                        ),
                                        if (!isActive)
                                          PopupMenuItem(
                                            value: 'delete',
                                            child: Row(
                                              children: [
                                                Icon(
                                                    Icons
                                                        .delete_outline_rounded,
                                                    size: 16,
                                                    color: ZipherColors
                                                        .red
                                                        .withValues(
                                                            alpha: 0.6)),
                                                const Gap(8),
                                                Text('Delete',
                                                    style: TextStyle(
                                                        fontSize: 13,
                                                        color: ZipherColors
                                                            .red
                                                            .withValues(
                                                                alpha:
                                                                    0.7))),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }

  void _onWalletAction(
      String action, WalletProfile w, bool isActive) async {
    switch (action) {
      case 'switch':
        await _switchWallet(w);
      case 'rename':
        await _renameWallet(w);
      case 'delete':
        await _deleteWallet(w);
    }
  }

  Future<void> _switchWallet(WalletProfile w) async {
    setState(() => _switching = true);
    try {
      final ws = WalletService.instance;
      await ws.switchWallet(w.id);

      final balance = await ws.getBalanceOrZero();
      final addrs = await ws.getAddresses();
      aa = ActiveAccount2.fromWallet(
        coin: activeCoin.coin,
        address: addrs.isNotEmpty ? addrs.first.address : '',
        balance: balance,
        walletName: w.name,
        walletId: w.id,
      );
      aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to switch: $e'),
            backgroundColor: ZipherColors.surface,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _renameWallet(WalletProfile w) async {
    final controller = TextEditingController(text: w.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZipherColors.cardBgElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.lg),
        ),
        title: Text('Rename Wallet',
            style:
                TextStyle(fontSize: 16, color: ZipherColors.text90)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(
              fontSize: 14, color: ZipherColors.text90),
          decoration: InputDecoration(
            hintText: 'Wallet name',
            hintStyle: TextStyle(
                fontSize: 14, color: ZipherColors.text40),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel',
                style: TextStyle(color: ZipherColors.text40)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(controller.text.trim()),
            child: Text('Save',
                style: TextStyle(color: ZipherColors.cyan)),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name != null && name.isNotEmpty && name != w.name) {
      await WalletRegistry.instance.rename(w.id, name);
      if (w.id == WalletService.instance.activeWalletId) {
        aa.name = name;
      }
      await _load();
    }
  }

  Future<void> _deleteWallet(WalletProfile w) async {
    if (_wallets.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot delete the only account'),
          backgroundColor: ZipherColors.surface,
        ),
      );
      return;
    }

    final confirmed = await showConfirmDialog(
      context,
      'Delete "${w.name}"?',
      'This will permanently remove the wallet and all its data. This cannot be undone.',
      isDanger: true,
    );
    if (confirmed) {
      await WalletService.instance.deleteWalletById(w.id);
      await _load();
    }
  }

  void _addWallet() {
    GoRouter.of(context).push('/welcome');
  }
}

class AccountList extends StatelessWidget {
  final List<Account> accounts;
  final int? selected;
  final bool editing;
  final void Function(int?)? onSelect;
  final void Function(int?)? onLongSelect;
  final void Function(String)? onEdit;

  AccountList({
    required this.accounts,
    this.selected,
    this.onSelect,
    this.onLongSelect,
    this.editing = false,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
        itemBuilder: (context, index) {
          final a = accounts[index];
          return AccountTile(
            a,
            selected: index == selected,
            editing: editing,
            onPress: () => onSelect?.call(index),
            onLongPress: () {
              final v = selected != index ? index : null;
              onLongSelect?.call(v);
            },
            onEdit: onEdit,
          );
        },
        separatorBuilder: (context, index) =>
            Divider(color: ZipherColors.border),
        itemCount: accounts.length);
  }
}

class AccountTile extends StatelessWidget {
  final Account a;
  final void Function()? onPress;
  final void Function()? onLongPress;
  final bool selected;
  final bool editing;
  final void Function(String)? onEdit;
  late final nameController = TextEditingController(text: a.name);
  AccountTile(this.a,
      {this.onPress,
      this.onLongPress,
      required this.selected,
      required this.editing,
      this.onEdit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = coins[a.coin];
    return ListTile(
      selected: selected,
      leading: CircleAvatar(backgroundImage: c.image),
      title: editing && selected
          ? TextField(
              controller: nameController,
              autofocus: true,
              onEditingComplete: () => onEdit?.call(nameController.text))
          : Text(a.name ?? 'Account',
              style: t.textTheme.headlineSmall),
      trailing: Text(amountToString2(a.balance)),
      onTap: onPress,
      onLongPress: onLongPress,
      selectedTileColor: ZipherColors.cyan.withValues(alpha: 0.15),
    );
  }
}
