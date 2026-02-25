import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../zipher_theme.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../utils.dart';

class AccountManagerPage extends StatefulWidget {
  final bool main;
  AccountManagerPage({required this.main});
  @override
  State<StatefulWidget> createState() => _AccountManagerState();
}

class _AccountManagerState extends State<AccountManagerPage> {
  late List<Account> accounts = getAllAccounts();
  late final s = S.of(context);
  int? selected;
  bool editing = false;
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'ACCOUNTS',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded,
              color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        actions: [
          if (selected != null && !editing)
            IconButton(
              onPressed: _edit,
              icon: Icon(Icons.edit_rounded,
                  size: 20,
                  color: ZipherColors.text40),
            ),
          if (selected != null && !editing)
            IconButton(
              onPressed: _delete,
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20,
                  color: ZipherColors.red.withValues(alpha: 0.5)),
            ),
          if (selected == null)
            IconButton(
              onPressed: _add,
              icon: Icon(Icons.add_rounded,
                  size: 22,
                  color: ZipherColors.cyan.withValues(alpha: 0.7)),
            ),
        ],
      ),
      body: accounts.isEmpty
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
                      color: ZipherColors.text20,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: accounts.length,
              itemBuilder: (context, index) {
                final a = accounts[index];
                final isSelected = index == selected;
                final isActive = a.coin == aa.coin && a.id == aa.id;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () => _select(index),
                    onLongPress: () =>
                        setState(() => selected = isSelected ? null : index),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? ZipherColors.cyan.withValues(alpha: 0.06)
                            : ZipherColors.cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: isSelected
                            ? Border.all(
                                color:
                                    ZipherColors.cyan.withValues(alpha: 0.15))
                            : null,
                      ),
                      child: Row(
                        children: [
                          // Avatar
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _accountColor(a)
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                (a.name ?? '?')[0].toUpperCase(),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: _accountColor(a)
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ),
                          const Gap(12),
                          // Name & type
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (editing && isSelected)
                                  TextField(
                                    controller: _nameController,
                                    autofocus: true,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: ZipherColors.text90,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      filled: false,
                                      border: InputBorder.none,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                    onSubmitted: _onEditDone,
                                  )
                                else
                                  Text(
                                    a.name ?? 'Account',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: ZipherColors.text90,
                                    ),
                                  ),
                                const Gap(2),
                                Row(
                                  children: [
                                    if (isActive)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1),
                                        margin:
                                            const EdgeInsets.only(right: 6),
                                        decoration: BoxDecoration(
                                          color: ZipherColors.green
                                              .withValues(alpha: 0.1),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'Active',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                            color: ZipherColors.green
                                                .withValues(alpha: 0.6),
                                          ),
                                        ),
                                      ),
                                    if (a.keyType == 0x80)
                                      _typeBadge('Watch-only',
                                          ZipherColors.cyan),
                                    if (a.keyType == 1)
                                      _typeBadge(
                                          'Secret key', ZipherColors.purple),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Balance
                          Text(
                            '${amountToString2(a.balance)} ZEC',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color:
                                  ZipherColors.text60,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Color _accountColor(Account a) {
    switch (a.keyType) {
      case 0x80:
        return ZipherColors.cyan;
      case 1:
        return ZipherColors.purple;
      default:
        return ZipherColors.cyan;
    }
  }

  Widget _typeBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w500,
          color: color.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  void _select(int index) {
    if (selected != null) {
      setState(() => selected = index == selected ? null : index);
      return;
    }
    final a = accounts[index];
    if (widget.main) {
      setActiveAccount(a.coin, a.id);
      Future(() async {
        final prefs = await SharedPreferences.getInstance();
        await aa.save(prefs);
      });
      aa.update(null);
    }
    GoRouter.of(context).pop<Account>(a);
  }

  void _add() async {
    await GoRouter.of(context).push('/more/account_manager/new');
    _refresh();
    setState(() {});
  }

  void _edit() {
    if (selected == null) return;
    _nameController.text = accounts[selected!].name ?? '';
    setState(() => editing = true);
  }

  void _onEditDone(String name) {
    final a = accounts[selected!];
    WarpApi.updateAccountName(a.coin, a.id, name);
    _refresh();
    setState(() => editing = false);
  }

  void _delete() async {
    if (selected == null) return;
    final a = accounts[selected!];
    if (accounts.length > 1 && a.coin == aa.coin && a.id == aa.id) {
      await showMessageBox2(context, s.error, s.cannotDeleteActive);
      return;
    }
    final confirmed = await showConfirmDialog(
        context, s.deleteAccount(a.name!), s.confirmDeleteAccount);
    if (confirmed) {
      WarpApi.deleteAccount(a.coin, a.id);
      _refresh();
      if (accounts.isEmpty) {
        setActiveAccount(0, 0);
        GoRouter.of(context).go('/account');
      } else {
        selected = null;
        setState(() {});
      }
    }
  }

  void _refresh() {
    accounts = getAllAccounts();
  }
}

// Keep AccountList and AccountTile for backward compatibility with router
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
