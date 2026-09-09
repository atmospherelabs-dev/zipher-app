/// Local, deterministic routing. Conversation text never leaves the device.
/// This collects a request; address/network checks and signing belong to the
/// wallet engine, and a complete request still requires explicit review.
enum WalletCommand {
  send,
  receive,
  swap,
  balance,
  history,
  help,
  cancel,
  unknown
}

class WalletRequest {
  final WalletCommand command;
  final int? zatoshis;
  final String? recipient;
  final String? token;
  final String? memo;

  const WalletRequest(this.command,
      {this.zatoshis, this.recipient, this.token, this.memo});

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
    // Whole words, before broad read-only phrases. An address containing a
    // command substring must never change the intended operation.
    if (RegExp(r'\b(send|transfer|pay)\b').hasMatch(s))
      return WalletCommand.send;
    if (RegExp(r'\b(swap|convert|exchange)\b').hasMatch(s))
      return WalletCommand.swap;
    if (RegExp(r'^(?:\d*\.)?\d+\s+zec\s+(?:to|into)\s+\w+$').hasMatch(s)) {
      return WalletCommand.swap;
    }
    if (RegExp(
            r'\b(receive|receiveing|receiving|reveice|recieve|deposit|addresses|address|qr)\b')
        .hasMatch(s)) {
      return WalletCommand.receive;
    }
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

  static String formatZec(int value) =>
      '${value ~/ 100000000}.${(value % 100000000).toString().padLeft(8, '0')}';

  static bool looksLikeAddress(String text) => RegExp(
          r'^(?:u1|utest1|uregtest1|zs1|ztestsapling1|tex1|textest1|t1|t3|tm|t2)[a-zA-Z0-9]{20,}$')
      .hasMatch(text.trim());

  void cancel() => pending = null;

  String get hint {
    final p = pending;
    if (p == null) return 'What would you like to do?';
    if (p.command == WalletCommand.send && p.recipient == null)
      return 'Paste a Zcash address';
    if (p.zatoshis == null) return 'Amount in ZEC';
    return 'Which token? e.g. BTC, ETH, USDC';
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
      cancel();
      if (cmd != WalletCommand.send && cmd != WalletCommand.swap) {
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
      String? token;
      final target = RegExp(r'\s+(?:to|into)\s+(\S+)\s*$', caseSensitive: false)
          .firstMatch(body);
      if (target != null) {
        final value = target.group(1)!;
        if (cmd == WalletCommand.send && looksLikeAddress(value))
          recipient = value;
        if (cmd == WalletCommand.swap &&
            RegExp(r'^[a-zA-Z][a-zA-Z0-9.]{0,11}$').hasMatch(value))
          token = value.toUpperCase();
        body = body.substring(0, target.start);
      }
      body = body
          .replaceFirst(
              RegExp(r'^.*?\b(?:send|transfer|pay|swap|convert|exchange)\b\s*',
                  caseSensitive: false),
              '')
          .trim();
      final amount = parseZatoshis(body);
      pending = WalletRequest(cmd,
          zatoshis: amount, recipient: recipient, token: token, memo: memo);
      if (body.isNotEmpty && amount == null) {
        return const ConversationReply(
            prompt:
                'Enter an amount in ZEC, with up to 8 decimal places. For example: 0.5 ZEC.');
      }
    } else if (pending != null) {
      var p = pending!;
      if (p.command == WalletCommand.send &&
          p.recipient == null &&
          looksLikeAddress(input)) {
        p = p.withFields(recipient: input);
      } else if (p.zatoshis == null && parseZatoshis(input) != null) {
        p = p.withFields(zatoshis: parseZatoshis(input));
      } else if (p.command == WalletCommand.swap &&
          p.token == null &&
          RegExp(r'^[a-zA-Z][a-zA-Z0-9.]{0,11}$').hasMatch(input)) {
        p = p.withFields(token: input.toUpperCase());
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
    if (p.zatoshis == null ||
        (p.command == WalletCommand.send && p.recipient == null) ||
        (p.command == WalletCommand.swap && p.token == null)) {
      return ConversationReply(prompt: _prompt(p));
    }
    pending = null;
    return ConversationReply(request: p);
  }

  String _prompt(WalletRequest p) {
    if (p.command == WalletCommand.send && p.recipient == null)
      return 'Who would you like to send to? Paste their Zcash address.';
    if (p.zatoshis == null)
      return p.command == WalletCommand.swap
          ? 'How much ZEC would you like to swap?'
          : 'How much ZEC would you like to send?';
    return 'Which token would you like to receive? For example: BTC, ETH, SOL, or USDC.';
  }
}
