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
                    color: ZipherColors.text20,
                  ),
                ),
                const Gap(8),
                Text(
                  'Tap + to add your first contact',
                  style: TextStyle(
                    fontSize: 13,
                    color: ZipherColors.text10,
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

  _add() {
    GoRouter.of(context).push('/more/contacts/add');
  }

  _edit() {
    final c = listKey.currentState!.selectedContact!;
    final id = c.id;
    GoRouter.of(context).push('/more/contacts/edit?id=$id');
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
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ContactCard(
              contact: contact,
              selected: isSelected,
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

  Contact? get selectedContact => selected?.let((s) => contacts.contacts[s]);
}

class _ContactCard extends StatelessWidget {
  final ContactT contact;
  final bool selected;
  final VoidCallback? onPress;
  final VoidCallback? onLongPress;

  const _ContactCard({
    required this.contact,
    this.selected = false,
    this.onPress,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final addr = contact.address ?? '';
    final truncated = addr.length > 20
        ? '${addr.substring(0, 10)}...${addr.substring(addr.length - 10)}'
        : addr;

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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    (contact.name ?? '?')[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: ZipherColors.cyan.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
              const Gap(14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.name ?? '',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: ZipherColors.text90,
                      ),
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

  @override
  void initState() {
    super.initState();
    final c = WarpApi.getContact(aa.coin, widget.id);
    nameController.text = c.name!;
    addressController.text = c.address!;
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
                  maxLines: 5,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: ZipherColors.text90,
                  ),
                  decoration: InputDecoration(
                    hintText: s.address,
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

  _save() {
    WarpApi.storeContact(
        aa.coin, widget.id, nameController.text, addressController.text, true);
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

  @override
  void dispose() {
    nameController.dispose();
    addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
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
                        validator: addressValidator,
                        minLines: 3,
                        maxLines: 5,
                        style: TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: ZipherColors.text90,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Zcash address',
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
    addressController.text =
        await scanQRCode(context, validator: addressValidator);
  }

  _add() async {
    final form = formKey.currentState!;
    if (form.validate()) {
      WarpApi.storeContact(
          aa.coin, 0, nameController.text, addressController.text, true);
      contacts.fetchContacts();
      GoRouter.of(context).pop();
    }
  }
}
