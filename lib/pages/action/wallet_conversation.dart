/// Local, deterministic routing. Conversation text never leaves the device.
/// This collects a request; address/network checks and signing belong to the
/// wallet engine, and a complete request still requires explicit review.
enum WalletCommand {
  send,
  receive,
  swap,
  balance,
  pools,
  privacy,
  torOn,
  torOff,
  nym,
  vpn,
  history,
  memos,
  clear,
  help,
  cancel,
  unknown
}

class WalletRequest {
  final WalletCommand command;
  final int? zatoshis;
  final String? recipient;
  final String? token;

  /// Destination network named in a swap request, as typed.
  final String? network;
  final String? memo;

  /// A swap amount was typed but is not an exact ZEC amount.
  final bool unreadAmount;

  const WalletRequest(this.command,
      {this.zatoshis,
      this.recipient,
      this.token,
      this.network,
      this.memo,
      this.unreadAmount = false});

  WalletRequest withFields({int? zatoshis, String? recipient, String? token}) =>
      WalletRequest(command,
          zatoshis: zatoshis ?? this.zatoshis,
          recipient: recipient ?? this.recipient,
          token: token ?? this.token,
          memo: memo);
}

class ConversationReply {
  final String? prompt;
  final WalletRequest? request;
  const ConversationReply({this.prompt, this.request});
}

class WalletConversation {
  WalletRequest? pending;

  static WalletCommand command(String text) {
    final s = text.trim().toLowerCase().replaceFirst(RegExp(r'^/'), '');
    if (RegExp(r'^(cancel|stop|never mind|nevermind|start over)$')
        .hasMatch(s)) {
      return WalletCommand.cancel;
    }
    if (RegExp(r'^(?:clear|clear chat|clear conversation|reset chat|new chat)$')
        .hasMatch(s)) return WalletCommand.clear;
    if (RegExp(
            r'^(?:(?:show|read)(?: me)? )?(?:(?:my|the) )?(?:latest |recent )?(?:memos|messages|inbox)$')
        .hasMatch(s)) return WalletCommand.memos;
    // Exact privacy commands cannot capture payment memos or addresses.
    if (RegExp(
            r'^(?:please )?(?:activate|enable|use|turn on|connect to) tor$|^tor on$')
        .hasMatch(s)) return WalletCommand.torOn;
    if (RegExp(
            r'^(?:please )?(?:disable|deactivate|turn off|disconnect from) tor$|^tor off$')
        .hasMatch(s)) return WalletCommand.torOff;
    if (RegExp(
            r'^(?:(?:activate|enable|use|turn on|connect to) )?nym(?: vpn)?$')
        .hasMatch(s)) return WalletCommand.nym;
    if (RegExp(r'^(?:(?:activate|enable|use|turn on|connect to) )?(?:a )?vpn$')
        .hasMatch(s)) return WalletCommand.vpn;
    if (RegExp(
            r'^(?:privacy|network privacy|connection|connection status|tor|tor status)$')
        .hasMatch(s)) return WalletCommand.privacy;
    // Whole words, before broad read-only phrases. An address containing a
    // command substring must never change the intended operation.
    if (RegExp(r'\b(send|transfer|pay)\b').hasMatch(s))
      return WalletCommand.send;
    if (RegExp(r'\b(swap|convert|exchange)\b').hasMatch(s))
      return WalletCommand.swap;
    if (RegExp(
            r'^(?:\d*\.)?\d+\s*(?:zec|zcash)\s+(?:to|into|for)\s+\$?[a-z][a-z0-9.]{0,11}(?:\s+(?:on\s+)?[a-z][a-z0-9 ]{1,24}|\s*\([a-z0-9 ]{2,24}\))?$')
        .hasMatch(s)) {
      return WalletCommand.swap;
    }
    if (RegExp(
            r'\b(receive|receiveing|receiving|reveice|recieve|deposit|addresses|address|qr)\b')
        .hasMatch(s)) {
      return WalletCommand.receive;
    }
    if (RegExp(r'\b(pool|pools|breakdown|repartition)\b|where.*(?:zec|zcash)')
        .hasMatch(s)) return WalletCommand.pools;
    if (RegExp(
            r'\b(balances|balance|bal)\b|how much (?:do i have|zec do i have)')
        .hasMatch(s)) {
      return WalletCommand.balance;
    }
    if (RegExp(r'\b(history|transactions|activity)\b').hasMatch(s))
      return WalletCommand.history;
    if (s == '?' || RegExp(r'\b(help|hello|hi)\b|what can').hasMatch(s))
      return WalletCommand.help;
    return WalletCommand.unknown;
  }

  /// Exact decimal conversion: reject rounding, signs, exponent notation and
  /// ambiguous separators. No floating point arithmetic on payment amounts.
  static int? parseZatoshis(String text) {
    final match = RegExp(
            r'^(\d+(?:\.\d{1,8})?|\.\d{1,8})(?:\s*(?:zec|zcash))?$',
            caseSensitive: false)
        .firstMatch(text.trim());
    if (match == null) return null;
    final parts = match.group(1)!.split('.');
    final whole = BigInt.tryParse(parts[0].isEmpty ? '0' : parts[0]);
    if (whole == null) return null;
    final fractional = parts.length == 2 ? parts[1] : '';
    final amount = whole * BigInt.from(100000000) +
        BigInt.parse(fractional.padRight(8, '0'));
    if (amount <= BigInt.zero || amount > BigInt.from(2100000000000000))
      return null;
    return amount.toInt();
  }

  static String formatZec(int value) {
    final amount = value.abs();
    final fraction = (amount % 100000000)
        .toString()
        .padLeft(8, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${value < 0 ? '-' : ''}${amount ~/ 100000000}'
        '${fraction.isEmpty ? '' : '.$fraction'}';
  }

  static bool looksLikeAddress(String text) => RegExp(
          r'^(?:u1|utest1|uregtest1|zs1|ztestsapling1|tex1|textest1|t1|t3|tm|t2)[a-zA-Z0-9]{20,}$')
      .hasMatch(text.trim());

  /// Reading these never changes a payment, so a draft survives them.
  static const informational = {
    WalletCommand.balance,
    WalletCommand.pools,
    WalletCommand.privacy,
    WalletCommand.memos,
    WalletCommand.help,
  };

  /// Whatever a one-line swap request already says. Amounts are exact ZEC only;
  /// the token and network are returned as typed and resolved by the swap flow.
  static WalletRequest parseSwap(String text) {
    var body = text
        .trim()
        .replaceFirst(RegExp(r'^/'), '')
        .replaceFirst(
            RegExp(r'^.*?\b(?:swap|convert|exchange)\b\s*',
                caseSensitive: false),
            '')
        .trim();
    String? token;
    String? network;
    final place = RegExp(
            r'(?:\s+(?:on|via)\s+|\s*\()([A-Za-z][A-Za-z0-9 ]{1,24}?)\)?\s*$',
            caseSensitive: false)
        .firstMatch(body);
    if (place != null) {
      network = place.group(1)!.trim();
      body = body.substring(0, place.start).trim();
    }
    const symbol = r'\$?[A-Za-z][A-Za-z0-9.]{0,11}';
    final target = RegExp(
            '(?:^|\\s+)(?:to|into|for)\\s+($symbol)(?:\\s+([A-Za-z][A-Za-z0-9]{1,15}))?\\s*\$',
            caseSensitive: false)
        .firstMatch(body);
    if (target != null) {
      token = target.group(1);
      network ??= target.group(2);
      body = body.substring(0, target.start).trim();
    } else if (RegExp('^$symbol\$').hasMatch(body) &&
        !RegExp(r'^(?:zec|zcash)$', caseSensitive: false).hasMatch(body)) {
      token = body;
      body = '';
    }
    if (RegExp(r'^(?:(?:my|some)\s+)?(?:zec|zcash)$', caseSensitive: false)
        .hasMatch(body)) {
      body = '';
    }
    final amount = body.isEmpty ? null : parseZatoshis(body);
    return WalletRequest(WalletCommand.swap,
        zatoshis: amount,
        token: token?.toUpperCase(),
        network: network,
        unreadAmount: body.isNotEmpty && amount == null);
  }

  void cancel() => pending = null;

  String get hint {
    final p = pending;
    if (p == null) return 'What would you like to do?';
    if (p.recipient == null) return 'Paste a Zcash address';
    return 'Amount in ZEC';
  }

  ConversationReply accept(String text) {
    final input = text.trim();
    final cmd = command(input);
    if (cmd == WalletCommand.cancel) {
      cancel();
      return const ConversationReply(
          prompt: 'Cancelled. What would you like to do next?');
    }
    if (cmd != WalletCommand.unknown) {
      if (informational.contains(cmd)) {
        return ConversationReply(request: WalletRequest(cmd));
      }
      cancel();
      if (cmd == WalletCommand.swap) {
        // The swap flow collects what is missing and lets any field be retyped.
        return ConversationReply(request: parseSwap(input));
      }
      if (cmd != WalletCommand.send) {
        return ConversationReply(request: WalletRequest(cmd));
      }
      String body = input.replaceFirst(RegExp(r'^/'), '');
      String? memo;
      final memoMatch =
          RegExp(r'\s+memo\s*:\s*(.*)$', caseSensitive: false).firstMatch(body);
      if (memoMatch != null) {
        memo = memoMatch.group(1);
        body = body.substring(0, memoMatch.start);
      }
      String? recipient;
      final target = RegExp(r'\s+(?:to|into)\s+(\S+)\s*$', caseSensitive: false)
          .firstMatch(body);
      if (target != null) {
        final value = target.group(1)!;
        if (looksLikeAddress(value)) recipient = value;
        body = body.substring(0, target.start);
      }
      body = body
          .replaceFirst(
              RegExp(r'^.*?\b(?:send|transfer|pay)\b\s*',
                  caseSensitive: false),
              '')
          .trim();
      final amount = parseZatoshis(body);
      pending = WalletRequest(cmd,
          zatoshis: amount, recipient: recipient, memo: memo);
      if (body.isNotEmpty && amount == null) {
        return const ConversationReply(
            prompt:
                'Enter an amount in ZEC, with up to 8 decimal places. For example: 0.5 ZEC.');
      }
    } else if (pending != null) {
      var p = pending!;
      if (looksLikeAddress(input)) {
        // A pasted address replaces the recipient, so a wrong one is fixable.
        p = p.withFields(recipient: input);
      } else if (parseZatoshis(input) != null) {
        p = p.withFields(zatoshis: parseZatoshis(input));
      } else {
        return ConversationReply(
            prompt: '${_prompt(p)} You can also type cancel.');
      }
      pending = p;
    } else {
      if (looksLikeAddress(input)) {
        pending = WalletRequest(WalletCommand.send, recipient: input);
      } else {
        return const ConversationReply(
            prompt:
                'Try send, receive, swap, balance, or history. I’ll guide you through each step.');
      }
    }
    final p = pending!;
    if (p.zatoshis == null || p.recipient == null) {
      return ConversationReply(prompt: _prompt(p));
    }
    pending = null;
    return ConversationReply(request: p);
  }

  String _prompt(WalletRequest p) => p.recipient == null
      ? 'Who would you like to send to? Paste their Zcash address.'
      : 'How much ZEC would you like to send?';
}
