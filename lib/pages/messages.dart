import 'package:flutter/material.dart';

import '../zipher_theme.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/warp_api.dart';

import '../store2.dart';
import '../accounts.dart';
import '../appsettings.dart';
import '../generated/intl/messages.dart';
import '../tablelist.dart';
import '../../pages/accounts/send.dart';
import 'avatar.dart';
import 'utils.dart';
import 'widgets.dart';

class MessagePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SortSetting(
      child: Observer(
        builder: (context) {
          aaSequence.seqno;
          aaSequence.settingsSeqno;
          syncStatus2.changed;
          return TableListPage(
            listKey: PageStorageKey('messages'),
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            view: appSettings.messageView,
            items: aa.messages.items,
            metadata: TableListMessageMetadata(),
          );
        },
      ),
    );
  }
}

class TableListMessageMetadata extends TableListItemMetadata<ZMessage> {
  @override
  List<Widget>? actions(BuildContext context) => null;

  @override
  Text? headerText(BuildContext context) => null;

  @override
  void inverseSelection() {}

  @override
  Widget toListTile(BuildContext context, int index, ZMessage message,
      {void Function(void Function())? setState}) {
    return MessageBubble(message, index: index);
  }

  @override
  List<ColumnDefinition> columns(BuildContext context) {
    final s = S.of(context);
    return [
      ColumnDefinition(label: s.datetime),
      ColumnDefinition(label: s.fromto),
      ColumnDefinition(label: s.subject),
      ColumnDefinition(label: s.body),
    ];
  }

  @override
  DataRow toRow(BuildContext context, int index, ZMessage message) {
    final t = Theme.of(context);
    var style = t.textTheme.bodyMedium!;
    if (!message.read) style = style.copyWith(fontWeight: FontWeight.bold);
    final addressStyle = message.incoming
        ? style.apply(color: ZipherColors.green)
        : style.apply(color: ZipherColors.red);
    return DataRow.byIndex(
        index: index,
        cells: [
          DataCell(
              Text("${msgDateFormat.format(message.timestamp)}", style: style)),
          DataCell(Text("${message.fromto()}", style: addressStyle)),
          DataCell(Text("${message.subject}", style: style)),
          DataCell(Text("${message.body}", style: style)),
        ],
        onSelectChanged: (_) {
          GoRouter.of(context).push('/messages/details?index=$index');
        });
  }

  @override
  SortConfig2? sortBy(String field) {
    aa.messages.setSortOrder(field);
    return aa.messages.order;
  }

  @override
  Widget? header(BuildContext context) => null;
}

class MessageBubble extends StatelessWidget {
  final ZMessage message;
  final int index;
  MessageBubble(this.message, {required this.index});

  @override
  Widget build(BuildContext context) {
    final date = humanizeDateTime(context, message.timestamp);
    final owner = centerTrim(
        (message.incoming ? message.sender : message.recipient) ?? '',
        length: 8);
    final bubbleColor = message.incoming
        ? ZipherColors.surface
        : ZipherColors.surfaceLight;
    return GestureDetector(
        onTap: () => select(context),
        child: Container(
          padding: const EdgeInsets.all(ZipherSpacing.md),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(ZipherRadius.md),
            border: Border.all(color: ZipherColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              Text(owner,
                  style: const TextStyle(
                      color: ZipherColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              Align(
                  child: Text(message.subject,
                      style: const TextStyle(
                          color: ZipherColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w400))),
              Align(
                  alignment: Alignment.centerRight,
                  child: Text(date,
                      style: const TextStyle(
                          color: ZipherColors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500))),
            ]),
            Gap(8),
            Text(
              message.body,
              style: const TextStyle(
                  color: ZipherColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w400),
            ),
          ]),
        ));
  }

  select(BuildContext context) {
    GoRouter.of(context).push('/messages/details?index=$index');
  }
}

class MessageTile extends StatelessWidget {
  final ZMessage message;
  final int index;
  final double? width;

  MessageTile(this.message, this.index, {this.width});

  @override
  Widget build(BuildContext context) {
    final s = message.incoming ? message.sender : message.recipient;
    final initial = (s == null || s.isEmpty) ? "?" : s[0];
    final dateString = humanizeDateTime(context, message.timestamp);

    final unreadStyle = (TextStyle? s) =>
        message.read ? s : s?.copyWith(fontWeight: FontWeight.bold);

    final av = avatar(initial);

    final body = Column(
      children: [
        Text(message.fromto(),
            style: unreadStyle(const TextStyle(
                color: ZipherColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w400))),
        Gap(4),
        if (message.subject.isNotEmpty)
          Text(message.subject,
              style: unreadStyle(const TextStyle(
                  color: ZipherColors.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
              overflow: TextOverflow.ellipsis),
        Gap(6),
        Text(
          message.body,
          style: const TextStyle(
              color: ZipherColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w400),
          softWrap: true,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return GestureDetector(
        onTap: () {
          _onSelect(context);
        },
        onLongPress: () {
          WarpApi.markAllMessagesAsRead(aa.coin, aa.id, true);
        },
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            av,
            Gap(15),
            Expanded(child: body),
            SizedBox(
                width: 80,
                child: Text(dateString,
                    style: const TextStyle(
                        color: ZipherColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w400),
                    textAlign: TextAlign.right)),
          ]),
        ));
  }

  _onSelect(BuildContext context) {
    GoRouter.of(context).push('/messages/details?index=$index');
  }
}

class MessageItemPage extends StatefulWidget {
  final int index;
  MessageItemPage(this.index);

  @override
  State<StatefulWidget> createState() => _MessageItemState();
}

class _MessageItemState extends State<MessageItemPage> {
  late int idx;
  late final n;
  final replyController = TextEditingController();

  ZMessage get message => aa.messages.items[idx];

  void initState() {
    n = aa.messages.items.length;
    idx = widget.index;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final ts = msgDateFormatFull.format(message.timestamp);
    return Scaffold(
        backgroundColor: ZipherColors.bg,
        appBar: AppBar(
            backgroundColor: ZipherColors.surface,
            title: Text(message.subject),
            actions: [
          IconButton(
              onPressed: nextInThread,
              icon: const Icon(Icons.arrow_left, color: ZipherColors.cyan)),
          IconButton(
              onPressed: idx > 0 ? prev : null,
              icon: const Icon(Icons.chevron_left, color: ZipherColors.cyan)),
          IconButton(
              onPressed: idx < n - 1 ? next : null,
              icon: const Icon(Icons.chevron_right, color: ZipherColors.cyan)),
          IconButton(
              onPressed: prevInThread,
              icon: const Icon(Icons.arrow_right, color: ZipherColors.cyan)),
          if (message.fromAddress?.isNotEmpty == true)
            IconButton(
                onPressed: reply,
                icon: const Icon(Icons.reply, color: ZipherColors.cyan)),
          IconButton(
              onPressed: open,
              icon: const Icon(Icons.open_in_browser, color: ZipherColors.cyan)),
        ]),
        body: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              Gap(16),
              Panel(s.datetime, text: ts),
              Gap(8),
              Panel(s.sender, text: message.sender ?? ''),
              Gap(8),
              Panel(s.recipient, text: message.recipient),
              Gap(8),
              Panel(s.subject, text: message.subject),
              Gap(8),
              Panel(s.body, text: message.body, maxLines: 20),
            ]),
          ),
        ));
  }

  prev() {
    if (idx > 0) idx -= 1;
    setState(() {});
  }

  next() {
    if (idx < n - 1) idx += 1;
    setState(() {});
  }

  prevInThread() {
    final pn = WarpApi.getPrevNextMessage(
        aa.coin, aa.id, message.subject, message.height);
    final id = pn.prev;
    if (id != 0) idx = aa.messages.items.indexWhere((m) => m.id == id);
    setState(() {});
  }

  nextInThread() {
    final pn = WarpApi.getPrevNextMessage(
        aa.coin, aa.id, message.subject, message.height);
    final id = pn.next;
    if (id != 0) idx = aa.messages.items.indexWhere((m) => m.id == id);
    setState(() {});
  }

  reply() async {
    final memo = MemoData(true, message.subject, '');
    final sc = SendContext(message.fromAddress!, 7, Amount(0, false), memo);
    GoRouter.of(context).go('/account/quick_send', extra: sc);
  }

  open() {
    final index = aa.txs.items.indexWhere((tx) => tx.id == message.txId);
    assert(index >= 0);
    GoRouter.of(context).push('/history/details?index=$index');
  }
}
