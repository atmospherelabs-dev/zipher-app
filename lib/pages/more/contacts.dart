import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../zipher_theme.dart';
import '../../accounts.dart';
import '../../appsettings.dart';
import '../../generated/intl/messages.dart';
import '../../services/near_intents.dart';
import '../../store2.dart';
import '../scan.dart';
import '../utils.dart';

// ═══════════════════════════════════════════════════════════
// CONTACTS LIST PAGE
// ═══════════════════════════════════════════════════════════

class ContactsPage extends StatefulWidget {
  final bool main;
  ContactsPage({this.main = false}) {
    contacts.fetchContacts();
  }

  @override
  State<StatefulWidget> createState() => _ContactsState();
}

class _ContactsState extends State<ContactsPage> {
  bool selected = false;
  final listKey = GlobalKey<ContactListState>();
  late final s = S.of(context);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'CONTACTS',
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
          if (selected)
            IconButton(
              onPressed: _edit,
              icon: Icon(Icons.edit_rounded,
                  size: 20,
                  color: ZipherColors.text40),
            ),
          if (selected)
            IconButton(
              onPressed: _delete,
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20,
                  color: ZipherColors.red.withValues(alpha: 0.6)),
            ),
          IconButton(
            onPressed: _add,
            icon: Icon(Icons.person_add_alt_1_rounded,
                size: 20,
                color: ZipherColors.cyan.withValues(alpha: 0.7)),
          ),
        ],
      ),
      body: Observer(builder: (context) {
        final c = contacts.contacts;
        if (c.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.people_outline_rounded,
                    size: 48,
                    color: ZipherColors.cardBgElevated),
                const Gap(16),
                Text(
                  'No contacts yet',
                  style: TextStyle(
                    fontSize: 15,
                    color: ZipherColors.text40,
                  ),
                ),
                const Gap(8),
                Text(
                  'Tap + to add your first contact',
                  style: TextStyle(
                    fontSize: 13,
                    color: ZipherColors.text40,
                  ),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            Expanded(
              child: ContactList(
                key: listKey,
                onSelect: widget.main ? _copyToClipboard : (v) => _select(v!),
                onLongSelect: (v) => setState(() => selected = v != null),
              ),
            ),
            // Backup to chain banner
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: GestureDetector(
                  onTap: _save,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: ZipherColors.purple.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.cloud_upload_outlined,
                            size: 18,
                            color: ZipherColors.purple
                                .withValues(alpha: 0.5)),
                        const Gap(12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Backup contacts on-chain',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: ZipherColors.purple
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                              const Gap(2),
                              Text(
                                'Encrypt & store on the blockchain so they sync with your seed',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white
                                      .withValues(alpha: 0.2),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded,
                            size: 16,
                            color: ZipherColors.purple
                                .withValues(alpha: 0.3)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  _select(int v) {
    final c = contacts.contacts[v];
    if (!widget.main) GoRouter.of(context).pop(c);
  }

  _copyToClipboard(int? v) {
    final c = contacts.contacts[v!];
    Clipboard.setData(ClipboardData(text: c.address!));
    showSnackBar(s.addressCopiedToClipboard);
  }

  _save() async {
    final s = S.of(context);
    final coinSettings = CoinSettingsExtension.load(aa.coin);
    final fee = coinSettings.feeT;
    final confirmed =
        await showConfirmDialog(context, s.save, s.confirmSaveContacts);
    if (!confirmed) return;
    final txPlan = WarpApi.commitUnsavedContacts(
        aa.coin,
        aa.id,
        coinSettings.receipientPools,
        appSettings.anchorOffset,
        fee);
    GoRouter.of(context).push('/account/txplan?tab=contacts', extra: txPlan);
  }

  _add() async {
    await GoRouter.of(context).push('/more/contacts/add');
    listKey.currentState?.refreshChains();
  }

  _edit() async {
    final c = listKey.currentState!.selectedContact!;
    final id = c.id;
    await GoRouter.of(context).push('/more/contacts/edit?id=$id');
    listKey.currentState?.refreshChains();
  }

  _delete() async {
    final s = S.of(context);
    final confirmed =
        await showConfirmDialog(context, s.delete, s.confirmDeleteContact);
    if (!confirmed) return;
    final c = listKey.currentState!.selectedContact!;
    WarpApi.storeContact(aa.coin, c.id, c.name!, '', true);
    contacts.fetchContacts();
  }
}

// ═══════════════════════════════════════════════════════════
// CONTACT LIST WIDGET
// ═══════════════════════════════════════════════════════════

class ContactList extends StatefulWidget {
  final int? initialSelect;
  final void Function(int?)? onSelect;
  final void Function(int?)? onLongSelect;
  ContactList(
      {super.key, this.initialSelect, this.onSelect, this.onLongSelect});

  @override
  State<StatefulWidget> createState() => ContactListState();
}

class ContactListState extends State<ContactList> {
  late int? selected = widget.initialSelect;
  Map<String, String> _chainMap = {};

  @override
  void initState() {
    super.initState();
    _loadChains();
  }

  Future<void> _loadChains() async {
    final map = await ContactChainStore.loadAll();
    if (mounted) setState(() => _chainMap = map);
  }

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      final c = contacts.contacts;
      return ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: c.length,
        itemBuilder: (context, index) {
          final contact = c[index].unpack();
          final isSelected = selected == index;
          final addr = contact.address ?? '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ContactCard(
              contact: contact,
              selected: isSelected,
              chainId: _chainMap[addr],
              onPress: () => widget.onSelect?.call(index),
              onLongPress: () {
                final v = selected != index ? index : null;
                widget.onLongSelect?.call(v);
                selected = v;
                setState(() {});
              },
            ),
          );
        },
      );
    });
  }

  void refreshChains() => _loadChains();

  Contact? get selectedContact => selected?.let((s) => contacts.contacts[s]);
}

class _ContactCard extends StatelessWidget {
  final ContactT contact;
  final bool selected;
  final String? chainId;
  final VoidCallback? onPress;
  final VoidCallback? onLongPress;

  const _ContactCard({
    required this.contact,
    this.selected = false,
    this.chainId,
    this.onPress,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final addr = contact.address ?? '';
    final truncated = addr.length > 20
        ? '${addr.substring(0, 10)}...${addr.substring(addr.length - 10)}'
        : addr;
    final chain = ChainInfo.byId(chainId);
    final symbol = chain?.symbol ?? 'ZEC';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPress,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? ZipherColors.cyan.withValues(alpha: 0.08)
                : ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: selected
                ? Border.all(
                    color: ZipherColors.cyan.withValues(alpha: 0.15))
                : null,
          ),
          child: Row(
            children: [
              CurrencyIcon(symbol: symbol, size: 40),
              const Gap(14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            contact.name ?? '',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: ZipherColors.text90,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (chain != null) ...[
                          const Gap(8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ZipherColors.cardBgElevated,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              chain.symbol,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: ZipherColors.text40,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const Gap(2),
                    Text(
                      truncated,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: ZipherColors.text20,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18,
                  color: ZipherColors.text10),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// CONTACT ITEM (for backward compat)
// ═══════════════════════════════════════════════════════════

class ContactItem extends StatelessWidget {
  final ContactT contact;
  final bool? selected;
  final void Function()? onPress;
  final void Function()? onLongPress;
  ContactItem(this.contact, {this.selected, this.onPress, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return _ContactCard(
      contact: contact,
      selected: selected ?? false,
      onPress: onPress,
      onLongPress: onLongPress,
    );
  }
}

// ═══════════════════════════════════════════════════════════
// EDIT CONTACT
// ═══════════════════════════════════════════════════════════

class ContactEditPage extends StatefulWidget {
  final int id;
  ContactEditPage(this.id);

  @override
  State<StatefulWidget> createState() => _ContactEditState();
}

class _ContactEditState extends State<ContactEditPage> {
  final formKey = GlobalKey<FormBuilderState>();
  final nameController = TextEditingController();
  final addressController = TextEditingController();
  ChainInfo _selectedChain = ChainInfo.all.first;
  String _originalAddress = '';

  @override
  void initState() {
    super.initState();
    final c = WarpApi.getContact(aa.coin, widget.id);
    nameController.text = c.name!;
    addressController.text = c.address!;
    _originalAddress = c.address!;
    _loadChain();
  }

  Future<void> _loadChain() async {
    final chainId = await ContactChainStore.get(_originalAddress);
    final chain = ChainInfo.byId(chainId);
    if (chain != null && mounted) setState(() => _selectedChain = chain);
  }

  @override
  void dispose() {
    nameController.dispose();
    addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isZec = _selectedChain.id == 'zec';
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'EDIT CONTACT',
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
          IconButton(
            onPressed: _save,
            icon: Icon(Icons.check_rounded,
                size: 22,
                color: ZipherColors.cyan.withValues(alpha: 0.8)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: FormBuilder(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Name',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text40,
                ),
              ),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.borderSubtle,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: FormBuilderTextField(
                  name: 'name',
                  controller: nameController,
                  style: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text90,
                  ),
                  decoration: InputDecoration(
                    hintText: s.name,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: ZipherColors.text20,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const Gap(20),
              Text(
                'Chain',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text40,
                ),
              ),
              const Gap(8),
              _ChainSelector(
                selected: _selectedChain,
                onChanged: (c) => setState(() => _selectedChain = c),
              ),
              const Gap(20),
              Text(
                'Address',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text40,
                ),
              ),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.borderSubtle,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: FormBuilderTextField(
                  name: 'address',
                  controller: addressController,
                  validator: isZec
                      ? null
                      : (v) => chainAddressValidator(v, _selectedChain.id),
                  maxLines: 5,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: ZipherColors.text90,
                  ),
                  decoration: InputDecoration(
                    hintText: '${_selectedChain.name} address',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: ZipherColors.text20,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _save() async {
    final addr = addressController.text;
    WarpApi.storeContact(
        aa.coin, widget.id, nameController.text, addr, true);
    if (_originalAddress != addr) {
      await ContactChainStore.remove(_originalAddress);
    }
    await ContactChainStore.set(addr, _selectedChain.id);
    contacts.fetchContacts();
    GoRouter.of(context).pop();
  }
}

// ═══════════════════════════════════════════════════════════
// ADD CONTACT
// ═══════════════════════════════════════════════════════════

class ContactAddPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _ContactAddState();
}

class _ContactAddState extends State<ContactAddPage> {
  final formKey = GlobalKey<FormBuilderState>();
  final nameController = TextEditingController();
  final addressController = TextEditingController();
  ChainInfo _selectedChain = ChainInfo.all.first; // ZEC default

  @override
  void dispose() {
    nameController.dispose();
    addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isZec = _selectedChain.id == 'zec';
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'ADD CONTACT',
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
          IconButton(
            onPressed: _add,
            icon: Icon(Icons.check_rounded,
                size: 22,
                color: ZipherColors.cyan.withValues(alpha: 0.8)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: FormBuilder(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Name',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text40,
                ),
              ),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.borderSubtle,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: FormBuilderTextField(
                  name: 'name',
                  controller: nameController,
                  validator: FormBuilderValidators.required(),
                  style: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text90,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Contact name',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: ZipherColors.text20,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const Gap(20),
              Text(
                'Chain',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text40,
                ),
              ),
              const Gap(8),
              _ChainSelector(
                selected: _selectedChain,
                onChanged: (c) => setState(() => _selectedChain = c),
              ),
              const Gap(20),
              Text(
                'Address',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text40,
                ),
              ),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.borderSubtle,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: FormBuilderTextField(
                        name: 'address',
                        controller: addressController,
                        validator: isZec
                            ? addressValidator
                            : (v) => chainAddressValidator(v, _selectedChain.id),
                        minLines: 3,
                        maxLines: 5,
                        style: TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: ZipherColors.text90,
                        ),
                        decoration: InputDecoration(
                          hintText: '${_selectedChain.name} address',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: ZipherColors.text40,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.fromLTRB(16, 14, 8, 14),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 10, right: 8),
                      child: GestureDetector(
                        onTap: _qr,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: ZipherColors.cardBgElevated,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.qr_code_rounded,
                              size: 18,
                              color: ZipherColors.text40),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _qr() async {
    final isZec = _selectedChain.id == 'zec';
    addressController.text =
        await scanQRCode(context, validator: isZec ? addressValidator : null);
  }

  _add() async {
    final form = formKey.currentState!;
    if (form.validate()) {
      final addr = addressController.text;
      WarpApi.storeContact(
          aa.coin, 0, nameController.text, addr, true);
      await ContactChainStore.set(addr, _selectedChain.id);
      contacts.fetchContacts();
      GoRouter.of(context).pop();
    }
  }
}

// ═══════════════════════════════════════════════════════════
// CHAIN SELECTOR
// ═══════════════════════════════════════════════════════════

class _ChainSelector extends StatelessWidget {
  final ChainInfo selected;
  final ValueChanged<ChainInfo> onChanged;

  const _ChainSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showPicker(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: ZipherColors.borderSubtle,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            CurrencyIcon(symbol: selected.symbol, size: 28),
            const Gap(12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selected.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: ZipherColors.text90,
                    ),
                  ),
                  Text(
                    selected.symbol,
                    style: TextStyle(
                      fontSize: 11,
                      color: ZipherColors.text40,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.unfold_more_rounded,
                size: 18,
                color: ZipherColors.text40),
          ],
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZipherColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (_) => _ChainPickerSheet(
        selected: selected,
        onSelected: (c) {
          onChanged(c);
          Navigator.of(context).pop();
        },
      ),
    );
  }
}

class _ChainPickerSheet extends StatefulWidget {
  final ChainInfo selected;
  final ValueChanged<ChainInfo> onSelected;

  const _ChainPickerSheet({required this.selected, required this.onSelected});

  @override
  State<_ChainPickerSheet> createState() => _ChainPickerSheetState();
}

class _ChainPickerSheetState extends State<_ChainPickerSheet> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final filtered = _search.isEmpty
        ? ChainInfo.all
        : ChainInfo.all.where((c) =>
            c.name.toLowerCase().contains(_search.toLowerCase()) ||
            c.symbol.toLowerCase().contains(_search.toLowerCase())).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          const Gap(8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: ZipherColors.text10,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: ZipherColors.borderSubtle,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                style: TextStyle(
                  fontSize: 14,
                  color: ZipherColors.text90,
                ),
                decoration: InputDecoration(
                  hintText: 'Search chains...',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text20,
                  ),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: ZipherColors.text20),
                  filled: false,
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final chain = filtered[index];
                final isCurrent = chain.id == widget.selected.id;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => widget.onSelected(chain),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          CurrencyIcon(symbol: chain.symbol, size: 36),
                          const Gap(14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  chain.name,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: ZipherColors.text90,
                                  ),
                                ),
                                const Gap(1),
                                Text(
                                  chain.symbol,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: ZipherColors.text40,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isCurrent)
                            Icon(Icons.check_rounded,
                                size: 18,
                                color: ZipherColors.cyan.withValues(alpha: 0.7)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
