import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../zipher_theme.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/warp_api.dart';
import 'package:warp_api/data_fb_generated.dart';

import '../store2.dart';
import '../accounts.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../tablelist.dart';
import 'avatar.dart';
import 'utils.dart';

// ═══════════════════════════════════════════════════════════
// CONVERSATION MODEL
// ═══════════════════════════════════════════════════════════

class _Conversation {
  /// Unique key used for grouping & filtering (contact name, address, or '_anon')
  final String key;
  /// Best known Zcash address for this conversation (for replying)
  final String address;
  final String? contactName;
  final List<ZMessage> messages;
  final int unreadCount;

  _Conversation({
    required this.key,
    required this.address,
    required this.contactName,
    required this.messages,
    required this.unreadCount,
  });

  bool get isAnonymous => key == '_anon';

  bool get canReply => !isAnonymous && address.length > 40;

  ZMessage get lastMessage => messages.first;

  String get displayName {
    if (isAnonymous) return 'Memo Inbox';
    if (contactName != null && contactName!.isNotEmpty) return contactName!;
    if (address.length > 40) return centerTrim(address, length: 14);
    return address;
  }

  String get initial {
    if (isAnonymous) return '';
    if (contactName != null && contactName!.isNotEmpty) {
      return contactName![0].toUpperCase();
    }
    if (address.isNotEmpty) return address[0].toUpperCase();
    return '?';
  }
}

// ═══════════════════════════════════════════════════════════
// SHARED: compute the conversation key for any message
// ═══════════════════════════════════════════════════════════

Map<String, String>? _contactCache;

Map<String, String> _getAddrToContact() {
  if (_contactCache != null) return _contactCache!;
  final map = <String, String>{};
  try {
    final contacts = WarpApi.getContacts(aa.coin);
    for (final c in contacts) {
      if (c.address != null && c.name != null && c.name!.isNotEmpty) {
        map[c.address!] = c.name!;
      }
    }
  } catch (_) {}

  // Also map other wallet accounts' address variants to their name.
  // This merges conversations when a contact replies with a different
  // address variant (e.g. diversified or different UA type) than the one
  // stored in the contacts list.
  try {
    final accounts = WarpApi.getAccountList(activeCoin.coin);
    for (final acct in accounts) {
      if (acct.id == aa.id) continue; // skip current account
      final acctAddr = acct.address ?? '';
      // Use the contact name if this account already matches a contact,
      // otherwise fall back to the account name.
      String? displayName;
      if (acctAddr.isNotEmpty && map.containsKey(acctAddr)) {
        displayName = map[acctAddr];
      }
      displayName ??= acct.name;
      if (displayName == null || displayName.isEmpty) continue;
      // Add the account's primary address
      if (acctAddr.isNotEmpty) {
        map.putIfAbsent(acctAddr, () => displayName!);
      }
      // Add all UA-type variants (1=sapling, 6=orchard, 7=unified)
      for (final uaType in [1, 6, 7]) {
        try {
          final addr = WarpApi.getAddress(aa.coin, acct.id, uaType);
          if (addr.isNotEmpty) {
            map.putIfAbsent(addr, () => displayName!);
          }
        } catch (_) {}
      }
    }
  } catch (_) {}

  _contactCache = map;
  return map;
}

void _invalidateContactCache() {
  _contactCache = null;
}

/// Returns the conversation key for a given message.
/// Same key = same conversation thread.
String _conversationKeyFor(ZMessage msg) {
  final addrToContact = _getAddrToContact();

  // Get the counterparty address
  String rawAddr;
  if (msg.incoming) {
    rawAddr = msg.fromAddress ?? msg.sender ?? '';
  } else {
    rawAddr = msg.recipient;
  }

  if (rawAddr.isEmpty) return '_anon';

  // Check if rawAddr itself is an address in the contacts
  final contact = addrToContact[rawAddr];
  if (contact != null) return 'contact:$contact';

  // Check if rawAddr is a contact display name (not a real address)
  for (final entry in addrToContact.entries) {
    if (entry.value == rawAddr) return 'contact:${entry.value}';
  }

  // No contact — use the raw address as key
  return rawAddr;
}

// ═══════════════════════════════════════════════════════════
// CONVERSATIONS LIST PAGE
// ═══════════════════════════════════════════════════════════

class MessagesPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        aaSequence.seqno;
        aaSequence.settingsSeqno;
        syncStatus2.changed;
        final items = aa.messages.items;
        final hasCached = outgoingMemoCache.values
            .any((c) => c.recipient.isNotEmpty && c.memo.isNotEmpty);

        if (items.isEmpty && !hasCached) return _EmptyMessages();

        final conversations = _groupIntoConversations(items);

        return Scaffold(
          backgroundColor: ZipherColors.bg,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: const Text(
              'Messages',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: ZipherColors.textPrimary,
              ),
            ),
            centerTitle: true,
            iconTheme:
                const IconThemeData(color: ZipherColors.textSecondary),
            actions: [
              IconButton(
                onPressed: () => GoRouter.of(context).push('/more/contacts'),
                icon: Icon(Icons.people_outline_rounded,
                    size: 20, color: Colors.white.withValues(alpha: 0.35)),
                tooltip: 'Contacts',
              ),
            ],
          ),
          floatingActionButton: _ComposeButton(),
          body: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: conversations.length,
            separatorBuilder: (_, __) => Divider(
              height: 1,
              color: Colors.white.withValues(alpha: 0.04),
              indent: 64,
            ),
            itemBuilder: (context, index) {
              return _ConversationRow(conversations[index]);
            },
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════
// EMPTY STATE
// ═══════════════════════════════════════════════════════════

class _EmptyMessages extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Messages',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: ZipherColors.textPrimary,
          ),
        ),
        centerTitle: true,
        iconTheme: const IconThemeData(color: ZipherColors.textSecondary),
        actions: [
          IconButton(
            onPressed: () => GoRouter.of(context).push('/more/contacts'),
            icon: Icon(Icons.people_outline_rounded,
                size: 20, color: Colors.white.withValues(alpha: 0.35)),
            tooltip: 'Contacts',
          ),
        ],
      ),
      floatingActionButton: _ComposeButton(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: ZipherColors.purple.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.lock_outline_rounded,
                  size: 36,
                  color: ZipherColors.purple.withValues(alpha: 0.4),
                ),
              ),
              const Gap(20),
              Text(
                'Encrypted Messages',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
              const Gap(10),
              Text(
                'Send private messages using Zcash\nshielded memos. No one can read\nthem except you and the recipient.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.3),
                  height: 1.6,
                ),
              ),
              const Gap(10),
              Text(
                'Messages are stored permanently on\nthe blockchain. Use caution.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.orange.withValues(alpha: 0.25),
                  height: 1.5,
                ),
              ),
              const Gap(28),
              GestureDetector(
                onTap: () => _navigateCompose(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: ZipherColors.purple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: ZipherColors.purple.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_rounded,
                          size: 16, color: ZipherColors.purple),
                      const Gap(8),
                      Text(
                        'New Message',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: ZipherColors.purple,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// COMPOSE FAB
// ═══════════════════════════════════════════════════════════

class _ComposeButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => _navigateCompose(context),
      backgroundColor: ZipherColors.purple,
      elevation: 0,
      child: const Icon(Icons.edit_rounded, color: Colors.white, size: 22),
    );
  }
}

void _navigateCompose(BuildContext context) {
  GoRouter.of(context).push('/messages/compose');
}

// ═══════════════════════════════════════════════════════════
// CONVERSATION ROW
// ═══════════════════════════════════════════════════════════

class _ConversationRow extends StatelessWidget {
  final _Conversation conversation;

  const _ConversationRow(this.conversation);

  @override
  Widget build(BuildContext context) {
    final last = conversation.lastMessage;
    final date = humanizeDateTime(context, last.timestamp);
    final hasUnread = conversation.unreadCount > 0;

    return GestureDetector(
      onTap: () {
        GoRouter.of(context).push(
          '/messages/thread',
          extra: conversation.key,
        );
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar: tray icon for inbox, letter avatar for contacts
            if (conversation.isAnonymous)
              CircleAvatar(
                radius: 22,
                backgroundColor: Colors.white.withValues(alpha: 0.06),
                child: Icon(
                  Icons.all_inbox_rounded,
                  size: 20,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              )
            else
              Stack(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: initialToColor(conversation.initial)
                        .withValues(alpha: 0.15),
                    child: Text(
                      conversation.initial,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: initialToColor(conversation.initial),
                      ),
                    ),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: ZipherColors.purple,
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: ZipherColors.bg, width: 2),
                      ),
                      child: const Icon(Icons.shield_rounded,
                          size: 8, color: Colors.white),
                    ),
                  ),
                ],
              ),
            const Gap(12),

            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + date
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.displayName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: hasUnread
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        date,
                        style: TextStyle(
                          fontSize: 11,
                          color: hasUnread
                              ? ZipherColors.purple.withValues(alpha: 0.7)
                              : Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                    ],
                  ),

                  const Gap(4),

                  // Preview
                  Row(
                    children: [
                      if (!last.incoming)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.reply_rounded,
                              size: 12,
                              color: Colors.white.withValues(alpha: 0.2)),
                        ),
                      Expanded(
                        child: Text(
                          last.body.isNotEmpty
                              ? parseMemoBody(last.body)
                              : (last.subject.isNotEmpty
                                  ? last.subject
                                  : 'Empty memo'),
                          style: TextStyle(
                            fontSize: 13,
                            color: hasUnread
                                ? Colors.white.withValues(alpha: 0.5)
                                : Colors.white.withValues(alpha: 0.25),
                            fontWeight: hasUnread
                                ? FontWeight.w500
                                : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                      // Unread badge
                      if (hasUnread) ...[
                        const Gap(8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: ZipherColors.purple,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${conversation.unreadCount}',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
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

// ═══════════════════════════════════════════════════════════
// CONVERSATION THREAD PAGE (CHAT VIEW)
// ═══════════════════════════════════════════════════════════

class ConversationPage extends StatefulWidget {
  final String conversationKey;
  ConversationPage({required this.conversationKey});

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  bool _includeReplyTo = true;

  /// Set of ZMessage.id values that were sent without reply-to.
  final _anonymousIds = <int>{};

  /// Inbox filter (only used when _isAnon)
  _InboxFilter _inboxFilter = _InboxFilter.all;

  bool get _isAnon => widget.conversationKey == '_anon';

  List<ZMessage> get _messages {
    _invalidateContactCache();
    _anonymousIds.clear();

    // Start with messages from the Rust backend
    final msgs = aa.messages.items.where((m) {
      return _conversationKeyFor(m) == widget.conversationKey;
    }).toList();

    // Merge cached outgoing messages that the sync hasn't picked up.
    // Dedup by clean body text only — within a conversation, the same
    // text appearing as both a Rust message and a cached memo is a dup.
    // (Recipient can differ: contact name vs raw address.)
    final existingBodies = <String>{};
    for (final m in msgs) {
      if (!m.incoming) {
        existingBodies.add(parseMemoBody(m.body));
      }
    }
    for (final entry in outgoingMemoCache.entries) {
      final c = entry.value;
      if (c.recipient.isEmpty || c.memo.isEmpty) continue;
      final cleanMemo = parseMemoBody(c.memo);
      if (existingBodies.contains(cleanMemo)) continue;
      final syntheticId = -entry.key.hashCode;
      final synthetic = ZMessage(
        syntheticId, 0, false, null, null,
        c.recipient, '', c.memo,
        DateTime.fromMillisecondsSinceEpoch(c.timestampMs),
        0, true,
      );
      if (_conversationKeyFor(synthetic) == widget.conversationKey) {
        msgs.add(synthetic);
        if (c.anonymous) _anonymousIds.add(syntheticId);
      }
    }

    msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return msgs;
  }

  /// Best known Zcash address for this conversation (for replying).
  /// Fields like recipient/sender can contain contact display names,
  /// so we resolve them back to actual addresses via the contacts list.
  String get _bestAddress {
    final addrToContact = _getAddrToContact();
    // Reverse map: contact name → address
    final contactToAddr = <String, String>{};
    for (final entry in addrToContact.entries) {
      contactToAddr[entry.value] = entry.key;
    }

    String _resolve(String raw) {
      // If it's already a long address (>40 chars), it's a real Zcash address
      if (raw.length > 40) return raw;
      // Otherwise it might be a contact name — resolve it
      return contactToAddr[raw] ?? raw;
    }

    // First pass: prefer outgoing recipient (we know we sent to it)
    for (final m in aa.messages.items) {
      if (_conversationKeyFor(m) != widget.conversationKey) continue;
      if (!m.incoming && m.recipient.isNotEmpty) {
        final resolved = _resolve(m.recipient);
        if (resolved.length > 40) return resolved;
      }
    }
    // Second pass: incoming reply-to address
    for (final m in aa.messages.items) {
      if (_conversationKeyFor(m) != widget.conversationKey) continue;
      if (m.incoming && m.fromAddress != null && m.fromAddress!.isNotEmpty) {
        final resolved = _resolve(m.fromAddress!);
        if (resolved.length > 40) return resolved;
      }
    }
    return '';
  }

  String get _displayName {
    // If key is a contact key, extract the name
    if (widget.conversationKey.startsWith('contact:')) {
      return widget.conversationKey.substring(8);
    }
    if (_isAnon) return 'Memo Inbox';
    final addr = _bestAddress;
    if (addr.isEmpty) return 'Unknown';
    return centerTrim(addr, length: 16);
  }

  @override
  void initState() {
    super.initState();
    _markAllRead();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _markAllRead() {
    for (final m in _messages) {
      if (!m.read && m.incoming) {
        WarpApi.markMessageAsRead(aa.coin, m.id, true);
      }
    }
    aa.messages.read(null);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isAnon) return _buildInboxView(context);
    return _buildConversationView(context);
  }

  /// Standard chat-style conversation (for identified contacts).
  Widget _buildConversationView(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: _buildAppBar(),
      body: Observer(
        builder: (context) {
          aaSequence.seqno;
          syncStatus2.changed;
          final msgs = _messages;

          return Column(
            children: [
              // Messages
              Expanded(
                child: msgs.isEmpty
                    ? _EmptyThread()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: msgs.length,
                        itemBuilder: (context, index) {
                          final msg = msgs[index];
                          final showDate = index == 0 ||
                              !_isSameDay(
                                  msgs[index - 1].timestamp, msg.timestamp);
                          return Column(
                            children: [
                              if (showDate) _DateSeparator(msg.timestamp),
                              _ChatBubble(
                                message: msg,
                                onViewTx: () => _openTx(msg),
                                anonymous: _anonymousIds.contains(msg.id),
                              ),
                            ],
                          );
                        },
                      ),
              ),

              // Reply-to is always ON in a conversation — you're already
              // identified, and disabling it would confuse the recipient.
              _ComposeBar(
                controller: _controller,
                sending: _sending,
                onSend: _sendMessage,
                includeReplyTo: true,
                onToggleReplyTo: null,
              ),
            ],
          );
        },
      ),
    );
  }

  /// Card-based notification feed for anonymous / unidentified memos.
  Widget _buildInboxView(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              child: Icon(
                Icons.all_inbox_rounded,
                size: 16,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
            const Gap(10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Memo Inbox',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: ZipherColors.textPrimary,
                    ),
                  ),
                  const Gap(2),
                  Text(
                    'No sender address included',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Observer(
        builder: (context) {
          aaSequence.seqno;
          syncStatus2.changed;
          final allMsgs = _messages.reversed.toList(); // newest first

          // Apply filter
          final msgs = allMsgs.where((m) {
            final body = parseMemoBody(m.body);
            switch (_inboxFilter) {
              case _InboxFilter.all:
                return true;
              case _InboxFilter.messages:
                return !_isSystemMemo(body);
              case _InboxFilter.system:
                return _isSystemMemo(body);
            }
          }).toList();

          final systemCount =
              allMsgs.where((m) => _isSystemMemo(parseMemoBody(m.body))).length;
          final userCount = allMsgs.length - systemCount;

          return Column(
            children: [
              // Filter tabs
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    _InboxFilterChip(
                      label: 'All (${allMsgs.length})',
                      selected: _inboxFilter == _InboxFilter.all,
                      onTap: () =>
                          setState(() => _inboxFilter = _InboxFilter.all),
                    ),
                    const Gap(8),
                    _InboxFilterChip(
                      label: 'Messages ($userCount)',
                      selected: _inboxFilter == _InboxFilter.messages,
                      onTap: () =>
                          setState(() => _inboxFilter = _InboxFilter.messages),
                    ),
                    const Gap(8),
                    _InboxFilterChip(
                      label: 'System ($systemCount)',
                      selected: _inboxFilter == _InboxFilter.system,
                      onTap: () =>
                          setState(() => _inboxFilter = _InboxFilter.system),
                    ),
                  ],
                ),
              ),

              // Cards feed
              Expanded(
                child: msgs.isEmpty
                    ? _EmptyInbox(_inboxFilter)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: msgs.length,
                        itemBuilder: (context, index) {
                          final msg = msgs[index];
                          return _MemoCard(
                            message: msg,
                            onViewTx: () => _openTx(msg),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// AppBar for identified conversation threads (not used for inbox).
  AppBar _buildAppBar() {
    final name = _displayName;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: const IconThemeData(color: Colors.white),
      titleSpacing: 0,
      title: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: initialToColor(initial).withValues(alpha: 0.15),
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: initialToColor(initial),
              ),
            ),
          ),
          const Gap(10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const Gap(3),
                Row(
                  children: [
                    Icon(Icons.shield_rounded,
                        size: 10,
                        color: ZipherColors.purple.withValues(alpha: 0.6)),
                    const Gap(3),
                    Text(
                      'Encrypted · permanent on chain',
                      style: TextStyle(
                        fontSize: 10,
                        color: ZipherColors.purple.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          onPressed: () {
            final addr = _bestAddress;
            if (addr.isEmpty) return;
            Clipboard.setData(ClipboardData(text: addr));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Address copied'),
                backgroundColor: ZipherColors.surface,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                duration: const Duration(seconds: 1),
              ),
            );
          },
          icon: Icon(Icons.copy_rounded,
              size: 18, color: Colors.white.withValues(alpha: 0.3)),
        ),
      ],
    );
  }

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);

    try {
      final addr = _bestAddress;
      logger.i('[Messages] Reply to key=${widget.conversationKey}');
      logger.i('[Messages] Best address=$addr (len=${addr.length})');
      logger.i('[Messages] includeReplyTo=$_includeReplyTo, memo="${text.substring(0, text.length.clamp(0, 40))}"');

      if (addr.isEmpty) {
        logger.e('[Messages] No reply address available');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('No reply address available'),
              backgroundColor: ZipherColors.red.withValues(alpha: 0.9),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          );
        }
        return;
      }

      // Always include reply-to in conversation threads — the user
      // is already identified in this thread.
      final builder = RecipientObjectBuilder(
        address: addr,
        pools: 7,
        amount: MIN_MEMO_AMOUNT,
        feeIncluded: false,
        replyTo: true,
        subject: '',
        memo: text,
      );
      final recipient = Recipient(builder.toBytes());

      logger.i('[Messages] Calling prepareTx coin=${aa.coin} id=${aa.id}');

      final plan = await WarpApi.prepareTx(
        aa.coin,
        aa.id,
        [recipient],
        7,
        coinSettings.replyUa,
        appSettings.anchorOffset,
        coinSettings.feeT,
      );

      logger.i('[Messages] prepareTx success');

      // Store memo + recipient so SubmitTxPage can persist after broadcast.
      // Reply-to is always ON in conversations, so never anonymous here.
      pendingOutgoingMemo = text;
      pendingOutgoingRecipient = addr;
      pendingOutgoingAnonymous = false;

      if (!mounted) return;
      _controller.clear();

      GoRouter.of(context).push(
        '/account/txplan?tab=account',
        extra: plan,
      );
    } on String catch (e) {
      logger.e('[Messages] prepareTx error (String): $e');
      if (mounted) {
        showMessageBox2(context, 'Error', e);
      }
    } catch (e) {
      logger.e('[Messages] prepareTx error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send: $e'),
            backgroundColor: ZipherColors.red.withValues(alpha: 0.9),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _openTx(ZMessage msg) {
    final index = aa.txs.items.indexWhere((tx) => tx.id == msg.txId);
    if (index >= 0) {
      GoRouter.of(context).push('/more/history/details?index=$index');
    }
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ═══════════════════════════════════════════════════════════
// EMPTY THREAD
// ═══════════════════════════════════════════════════════════

class _EmptyThread extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline_rounded,
              size: 40, color: Colors.white.withValues(alpha: 0.08)),
          const Gap(12),
          Text(
            'Start the conversation',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.2),
            ),
          ),
          const Gap(4),
          Text(
            'Send an encrypted memo below',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.1),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  final _InboxFilter filter;
  const _EmptyInbox(this.filter);

  @override
  Widget build(BuildContext context) {
    final String title;
    final String subtitle;
    final IconData icon;
    switch (filter) {
      case _InboxFilter.messages:
        title = 'No user messages';
        subtitle = 'Only system memos have been received';
        icon = Icons.mail_outline_rounded;
        break;
      case _InboxFilter.system:
        title = 'No system alerts';
        subtitle = 'Auto-shield and system memos appear here';
        icon = Icons.settings_rounded;
        break;
      case _InboxFilter.all:
        title = 'Inbox is empty';
        subtitle = 'Anonymous memos will appear here';
        icon = Icons.all_inbox_rounded;
        break;
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: Colors.white.withValues(alpha: 0.08)),
          const Gap(12),
          Text(title,
              style: TextStyle(
                  fontSize: 14, color: Colors.white.withValues(alpha: 0.2))),
          const Gap(4),
          Text(subtitle,
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withValues(alpha: 0.1))),
        ],
      ),
    );
  }
}

class _InboxFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _InboxFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? ZipherColors.purple.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? ZipherColors.purple.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? ZipherColors.purple.withValues(alpha: 0.8)
                : Colors.white.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// DATE SEPARATOR
// ═══════════════════════════════════════════════════════════

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator(this.date);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final d = date.toLocal();
    String label;
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      label = 'Today';
    } else if (d.year == now.year &&
        d.month == now.month &&
        d.day == now.day - 1) {
      label = 'Yesterday';
    } else {
      label =
          '${_monthName(d.month)} ${d.day}${d.year != now.year ? ', ${d.year}' : ''}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.25),
            ),
          ),
        ),
      ),
    );
  }

  static String _monthName(int m) => const [
        '',
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ][m];
}

// ═══════════════════════════════════════════════════════════
// MEMO INBOX: system message detection & filter
// ═══════════════════════════════════════════════════════════

/// Known prefixes/patterns for system-generated memos.
bool _isSystemMemo(String body) {
  final lower = body.toLowerCase().trim();
  return lower.startsWith('auto-shield') ||
      lower.startsWith('sent from zipher') ||
      lower.startsWith('shielding') ||
      lower.startsWith('auto shield') ||
      lower.contains('via zipher');
}

enum _InboxFilter { all, messages, system }

// ═══════════════════════════════════════════════════════════
// MEMO INBOX CARD (replaces chat bubbles for anonymous memos)
// ═══════════════════════════════════════════════════════════

class _MemoCard extends StatelessWidget {
  final ZMessage message;
  final VoidCallback onViewTx;

  const _MemoCard({required this.message, required this.onViewTx});

  @override
  Widget build(BuildContext context) {
    final body = parseMemoBody(message.body);
    final isSystem = _isSystemMemo(body);
    final time = _formatCardTime(message.timestamp);
    final txHash = message.txId > 0
        ? aa.txs.items
            .where((tx) => tx.id == message.txId)
            .map((tx) => tx.fullTxId)
            .firstOrNull
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSystem
            ? Colors.white.withValues(alpha: 0.02)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(
            width: 3,
            color: isSystem
                ? Colors.white.withValues(alpha: 0.06)
                : ZipherColors.purple.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: type badge + time
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isSystem
                        ? Colors.white.withValues(alpha: 0.04)
                        : ZipherColors.purple.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSystem
                            ? Icons.settings_rounded
                            : Icons.mail_rounded,
                        size: 10,
                        color: isSystem
                            ? Colors.white.withValues(alpha: 0.25)
                            : ZipherColors.purple.withValues(alpha: 0.5),
                      ),
                      const Gap(4),
                      Text(
                        isSystem ? 'System' : 'Memo',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: isSystem
                              ? Colors.white.withValues(alpha: 0.25)
                              : ZipherColors.purple.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
              ],
            ),

            const Gap(10),

            // Memo body
            Text(
              body.isNotEmpty ? body : 'Empty memo',
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: isSystem
                    ? Colors.white.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.8),
                fontStyle: isSystem ? FontStyle.italic : FontStyle.normal,
              ),
            ),

            const Gap(10),

            // Actions: Copy + View Tx
            Row(
              children: [
                _MemoCardAction(
                  icon: Icons.copy_rounded,
                  label: 'Copy',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: body));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Memo copied'),
                        backgroundColor: ZipherColors.surface,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                const Gap(12),
                _MemoCardAction(
                  icon: Icons.open_in_new_rounded,
                  label: 'View Tx',
                  onTap: onViewTx,
                ),
                if (txHash != null && txHash.isNotEmpty) ...[
                  const Spacer(),
                  Text(
                    txHash.length > 12
                        ? '${txHash.substring(0, 6)}…${txHash.substring(txHash.length - 4)}'
                        : txHash,
                    style: TextStyle(
                      fontSize: 9,
                      fontFamily: 'monospace',
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatCardTime(DateTime dt) {
    final t = dt.toLocal();
    final now = DateTime.now();
    final h = t.hour;
    final m = t.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    final time = '$hour:$m $period';
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return time;
    }
    return '${_DateSeparator._monthName(t.month)} ${t.day}, $time';
  }
}

class _MemoCardAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MemoCardAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white.withValues(alpha: 0.2)),
          const Gap(4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.25),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// CHAT BUBBLE
// ═══════════════════════════════════════════════════════════

class _ChatBubble extends StatelessWidget {
  final ZMessage message;
  final VoidCallback onViewTx;
  final bool anonymous;

  const _ChatBubble({
    required this.message,
    required this.onViewTx,
    this.anonymous = false,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = !message.incoming;
    final time = _formatTime(message.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) const SizedBox(width: 4),
          Flexible(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: message.body));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Message copied'),
                    backgroundColor: ZipherColors.surface,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              onDoubleTap: onViewTx,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isMe
                      ? ZipherColors.purple.withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft:
                        isMe ? const Radius.circular(16) : Radius.zero,
                    bottomRight:
                        isMe ? Radius.zero : const Radius.circular(16),
                  ),
                  border: Border.all(
                    color: isMe
                        ? ZipherColors.purple.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.04),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Subject if present
                    if (message.subject.isNotEmpty) ...[
                      Text(
                        message.subject,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isMe
                              ? ZipherColors.purple.withValues(alpha: 0.7)
                              : Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      const Gap(4),
                    ],

                    // Body
                    if (message.body.isNotEmpty)
                      Text(
                        message.body,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),

                    const Gap(4),

                    // Time + status
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        if (isMe && anonymous) ...[
                          const Gap(5),
                          Icon(
                            Icons.visibility_off_rounded,
                            size: 10,
                            color: Colors.orangeAccent.withValues(alpha: 0.45),
                          ),
                          const Gap(2),
                          Text(
                            'sent anonymously',
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.orangeAccent.withValues(alpha: 0.4),
                            ),
                          ),
                        ] else if (isMe) ...[
                          const Gap(4),
                          Icon(
                            Icons.done_all_rounded,
                            size: 12,
                            color: ZipherColors.purple.withValues(alpha: 0.4),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isMe) const SizedBox(width: 4),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final t = dt.toLocal();
    final h = t.hour;
    final m = t.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final hour = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$hour:$m $period';
  }
}

// ═══════════════════════════════════════════════════════════
// COMPOSE BAR
// ═══════════════════════════════════════════════════════════

class _ComposeBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final bool includeReplyTo;
  final VoidCallback? onToggleReplyTo;

  const _ComposeBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    this.includeReplyTo = true,
    this.onToggleReplyTo,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.bg.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.05),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reply-to toggle (shown on full compose) or static label
              if (onToggleReplyTo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: GestureDetector(
                    onTap: onToggleReplyTo,
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          includeReplyTo
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                          size: 12,
                          color: includeReplyTo
                              ? ZipherColors.purple.withValues(alpha: 0.5)
                              : Colors.white.withValues(alpha: 0.15),
                        ),
                        const Gap(5),
                        Text(
                          includeReplyTo
                              ? 'Reply address included'
                              : 'Reply address hidden',
                          style: TextStyle(
                            fontSize: 10,
                            color: includeReplyTo
                                ? ZipherColors.purple.withValues(alpha: 0.4)
                                : Colors.white.withValues(alpha: 0.15),
                          ),
                        ),
                        const Gap(4),
                        Icon(
                          Icons.swap_horiz_rounded,
                          size: 10,
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ],
                    ),
                  ),
                )
              else
                // In-conversation: reply-to is always on (static hint)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility_rounded,
                        size: 11,
                        color: ZipherColors.purple.withValues(alpha: 0.35),
                      ),
                      const Gap(4),
                      Text(
                        'Reply address always included in conversations',
                        style: TextStyle(
                          fontSize: 9,
                          color: ZipherColors.purple.withValues(alpha: 0.3),
                        ),
                      ),
                    ],
                  ),
                ),

              // Cost hint
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '0.0001 ZEC per message + network fee',
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
              ),

              // Input row
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Text field
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                      child: TextField(
                        controller: controller,
                        maxLines: null,
                        maxLength: includeReplyTo
                            ? MAX_MESSAGE_CHARS_WITH_REPLY
                            : MAX_MESSAGE_CHARS_NO_REPLY,
                        textInputAction: TextInputAction.newline,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                        decoration: InputDecoration(
                          hintText: 'Encrypted message…',
                          hintStyle: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          isDense: true,
                          counterText: '',
                        ),
                      ),
                    ),
                  ),
                  const Gap(8),

                  // Send button
                  GestureDetector(
                    onTap: sending ? null : onSend,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: sending
                            ? ZipherColors.purple.withValues(alpha: 0.2)
                            : ZipherColors.purple,
                        shape: BoxShape.circle,
                      ),
                      child: sending
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded,
                              size: 18, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// COMPOSE NEW MESSAGE PAGE
// ═══════════════════════════════════════════════════════════

class ComposeMessagePage extends StatefulWidget {
  @override
  State<ComposeMessagePage> createState() => _ComposeMessagePageState();
}

class _ComposeMessagePageState extends State<ComposeMessagePage> {
  final _addressController = TextEditingController();
  final _memoController = TextEditingController();
  bool _sending = false;
  bool _includeReplyTo = true;
  String? _error;

  @override
  void dispose() {
    _addressController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'New Message',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: ZipherColors.textPrimary,
          ),
        ),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          children: [
            const Gap(16),

            // Hero
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: ZipherColors.purple.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.mail_lock_rounded,
                  size: 28,
                  color: ZipherColors.purple.withValues(alpha: 0.6)),
            ),
            const Gap(12),
            Text(
              'Send an encrypted memo',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
            const Gap(4),
            Text(
              'This uses a 0 ZEC shielded transaction',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
            const Gap(28),

            // Address field with contact autocomplete
            ContactAutocomplete(
              controller: _addressController,
              onSelected: (address, name) {
                _addressController.text = address;
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: TextField(
                  controller: _addressController,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                  decoration: InputDecoration(
                    hintText: 'Recipient or contact name',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                    border: InputBorder.none,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () async {
                            final c = await GoRouter.of(context)
                                .push<Contact>('/more/contacts');
                            if (c != null && c.address != null) {
                              _addressController.text = c.address!;
                            }
                          },
                          icon: Icon(Icons.people_outline_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        IconButton(
                          onPressed: () async {
                            final data = await Clipboard.getData('text/plain');
                            if (data?.text != null) {
                              _addressController.text = data!.text!;
                            }
                          },
                          icon: Icon(Icons.paste_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.2)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const Gap(14),

            // Memo field
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
              constraints: const BoxConstraints(minHeight: 100),
              child: TextField(
                controller: _memoController,
                maxLines: 5,
                minLines: 3,
                maxLength: _includeReplyTo
                    ? MAX_MESSAGE_CHARS_WITH_REPLY
                    : MAX_MESSAGE_CHARS_NO_REPLY,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
                decoration: InputDecoration(
                  hintText: 'Your encrypted message…',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  counterStyle: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
              ),
            ),

            if (_error != null) ...[
              const Gap(12),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: ZipherColors.red),
              ),
            ],

            const Gap(16),

            // Reply-to toggle
            GestureDetector(
              onTap: () =>
                  setState(() => _includeReplyTo = !_includeReplyTo),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _includeReplyTo
                        ? ZipherColors.purple.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.04),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _includeReplyTo
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      size: 16,
                      color: _includeReplyTo
                          ? ZipherColors.purple.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.2),
                    ),
                    const Gap(10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Include my reply address',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                          const Gap(1),
                          Text(
                            _includeReplyTo
                                ? 'Recipient can see your address and reply'
                                : 'Anonymous message — no reply possible',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white.withValues(alpha: 0.2),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 36,
                      height: 20,
                      decoration: BoxDecoration(
                        color: _includeReplyTo
                            ? ZipherColors.purple.withValues(alpha: 0.3)
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: AnimatedAlign(
                        duration: const Duration(milliseconds: 150),
                        alignment: _includeReplyTo
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          width: 16,
                          height: 16,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: _includeReplyTo
                                ? ZipherColors.purple
                                : Colors.white.withValues(alpha: 0.3),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Gap(20),

            // Send button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _sending ? null : _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZipherColors.purple,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.send_rounded, size: 18),
                          Gap(8),
                          Text(
                            'Send Message',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
              ),
            ),

            const Gap(16),

            // Fee hint
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ZipherColors.purple.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: ZipherColors.purple.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14,
                      color: ZipherColors.purple.withValues(alpha: 0.4)),
                  const Gap(8),
                  Expanded(
                    child: Text(
                      'Each message costs 0.0001 ZEC + network fee (~0.0002 ZEC total).',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.25),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Gap(10),

            // Blockchain permanence warning
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ZipherColors.orange.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: ZipherColors.orange.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(Icons.warning_amber_rounded,
                        size: 14,
                        color: ZipherColors.orange.withValues(alpha: 0.5)),
                  ),
                  const Gap(8),
                  Expanded(
                    child: Text(
                      'Messages are stored permanently on the blockchain. '
                      'They are encrypted but cannot be deleted. Use caution.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.25),
                        height: 1.4,
                      ),
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

  void _send() async {
    final address = _addressController.text.trim();
    final memo = _memoController.text.trim();

    if (address.isEmpty) {
      setState(() => _error = 'Please enter a recipient address');
      return;
    }
    if (memo.isEmpty) {
      setState(() => _error = 'Please enter a message');
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      final builder = RecipientObjectBuilder(
        address: address,
        pools: 7,
        amount: MIN_MEMO_AMOUNT,
        feeIncluded: false,
        replyTo: _includeReplyTo,
        subject: '',
        memo: memo,
      );
      final recipient = Recipient(builder.toBytes());

      final plan = await WarpApi.prepareTx(
        aa.coin,
        aa.id,
        [recipient],
        7,
        coinSettings.replyUa,
        appSettings.anchorOffset,
        coinSettings.feeT,
      );

      // Store memo + recipient so SubmitTxPage can persist after broadcast
      pendingOutgoingMemo = memo;
      pendingOutgoingRecipient = address;
      pendingOutgoingAnonymous = !_includeReplyTo;

      if (!mounted) return;
      GoRouter.of(context).push(
        '/account/txplan?tab=account',
        extra: plan,
      );
    } on String catch (e) {
      if (mounted) setState(() => _error = e);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

// ═══════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════

/// Collect the current account's own addresses so we can detect self-conversations.
Set<String> _getOwnAddresses() {
  final own = <String>{};
  try {
    // Current diversified address
    if (aa.diversifiedAddress.isNotEmpty) own.add(aa.diversifiedAddress);
    // All UA types (1=sapling, 6=orchard, 7=unified, etc.)
    for (final uaType in [1, 6, 7]) {
      try {
        final addr = WarpApi.getAddress(aa.coin, aa.id, uaType);
        if (addr.isNotEmpty) own.add(addr);
      } catch (_) {}
    }
    // Also check all accounts on this coin (in case of rotated/old addresses)
    try {
      final accounts = WarpApi.getAccountList(activeCoin.coin);
      for (final acct in accounts) {
        if (acct.address != null && acct.address!.isNotEmpty) {
          own.add(acct.address!);
        }
      }
    } catch (_) {}
  } catch (_) {}
  return own;
}

List<_Conversation> _groupIntoConversations(List<ZMessage> allMessages) {
  _invalidateContactCache();

  // Collect own addresses for self-conversation detection
  final ownAddresses = _getOwnAddresses();

  // Merge cached outgoing messages that the Rust sync hasn't picked up yet.
  // Dedup by clean body text only — recipient can differ (contact name vs address).
  final existingBodies = <String>{};
  for (final m in allMessages) {
    if (!m.incoming) {
      existingBodies.add(parseMemoBody(m.body));
    }
  }
  final merged = List<ZMessage>.from(allMessages);
  for (final entry in outgoingMemoCache.entries) {
    final c = entry.value;
    if (c.recipient.isEmpty || c.memo.isEmpty) continue;
    final cleanMemo = parseMemoBody(c.memo);
    if (existingBodies.contains(cleanMemo)) continue;
    // Create a synthetic ZMessage for the cached outgoing message
    merged.add(ZMessage(
      -entry.key.hashCode, // negative id to avoid collision
      0, // txId (unused for display)
      false, // incoming = false (we sent it)
      null, // fromAddress
      null, // sender
      c.recipient, // recipient
      '', // subject
      c.memo, // body
      DateTime.fromMillisecondsSinceEpoch(c.timestampMs),
      0, // height (unknown until sync)
      true, // read (we sent it ourselves)
    ));
  }

  final Map<String, List<ZMessage>> groups = {};
  final Map<String, String> keyToBestAddr = {};

  for (final msg in merged) {
    final key = _conversationKeyFor(msg);
    groups.putIfAbsent(key, () => []).add(msg);

    // Track the best Zcash address for replying
    if (key != '_anon') {
      final rawAddr = msg.incoming
          ? (msg.fromAddress ?? '')
          : msg.recipient;
      if (rawAddr.length > (keyToBestAddr[key]?.length ?? 0)) {
        keyToBestAddr[key] = rawAddr;
      }
    }
  }

  final conversations = groups.entries.map((e) {
    final msgs = e.value
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final unread = msgs.where((m) => m.incoming && !m.read).length;

    // Extract contact name from key if it's a contact key
    String? contactName;
    if (e.key.startsWith('contact:')) {
      contactName = e.key.substring(8);
    }

    return _Conversation(
      key: e.key,
      address: keyToBestAddr[e.key] ?? '',
      contactName: contactName,
      messages: msgs,
      unreadCount: unread,
    );
  }).toList();

  // Filter out self-conversations: threads where we sent messages to
  // ourselves.  These already appear in the Activity feed, so showing
  // them as a "conversation" is confusing.
  //
  // Detection uses two methods:
  //  1. Direct address match against known own addresses.
  //  2. Transaction-value heuristic: when we send a memo to ourselves,
  //     the net value is just the fee (~0.00001 ZEC).  For a real send
  //     the net value is at least MIN_MEMO_AMOUNT (0.0001 ZEC) + fee.
  //     This catches self-sends to old diversified addresses that are
  //     no longer in _getOwnAddresses() (e.g. after a wallet reset).
  final memoThreshold = MIN_MEMO_AMOUNT / ZECUNIT; // 0.0001 ZEC
  conversations.removeWhere((c) {
    if (c.isAnonymous) return false; // keep Memo Inbox
    if (c.contactName != null) return false; // keep named contacts
    // Only consider conversations where ALL messages are outgoing
    if (!c.messages.every((m) => !m.incoming)) return false;

    // Method 1: address is directly recognized as our own
    final addr = c.address;
    if (addr.isNotEmpty && ownAddresses.contains(addr)) return true;

    // Method 2: check if the associated transactions have near-zero net
    // value, which means the funds came back to us (self-send).
    final txIds = c.messages.map((m) => m.txId).where((id) => id > 0).toSet();
    if (txIds.isEmpty) return false;
    return txIds.every((txId) {
      final tx = aa.txs.items.where((t) => t.id == txId).firstOrNull;
      if (tx == null) return false;
      return tx.value.abs() < memoThreshold;
    });
  });

  // Sort: pin Memo Inbox at top when it has unread items,
  // otherwise sort all by last message timestamp.
  conversations.sort((a, b) {
    final aInboxPin = a.isAnonymous && a.unreadCount > 0;
    final bInboxPin = b.isAnonymous && b.unreadCount > 0;
    if (aInboxPin && !bInboxPin) return -1;
    if (!aInboxPin && bInboxPin) return 1;
    return b.lastMessage.timestamp.compareTo(a.lastMessage.timestamp);
  });

  return conversations;
}

// ═══════════════════════════════════════════════════════════
// LEGACY WIDGETS (kept for compatibility)
// ═══════════════════════════════════════════════════════════

class MessagePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MessagesPage();
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

  ZMessage get message => aa.messages.items[idx];

  void initState() {
    n = aa.messages.items.length;
    idx = widget.index;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Center(
        child: Text('Redirecting...', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final ZMessage message;
  final int index;
  MessageBubble(this.message, {required this.index});

  @override
  Widget build(BuildContext context) {
    return SizedBox.shrink();
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
    return SizedBox.shrink();
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
    return SizedBox.shrink();
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
    return DataRow.byIndex(index: index, cells: [
      DataCell(Text("${msgDateFormat.format(message.timestamp)}", style: style)),
      DataCell(Text("${message.fromto()}", style: style)),
      DataCell(Text("${message.subject}", style: style)),
      DataCell(Text("${message.body}", style: style)),
    ]);
  }

  @override
  SortConfig2? sortBy(String field) {
    aa.messages.setSortOrder(field);
    return aa.messages.order;
  }

  @override
  Widget? header(BuildContext context) => null;
}
