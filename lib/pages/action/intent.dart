enum IntentType { balance, send, swap, evmSwap, shield, marketSearch, marketDiscover, bet, betPolymarket, portfolio, sell, sweep, help, unknown }

class ParsedIntent {
  final IntentType type;
  final String? address;
  final double? amount;
  final bool amountIsUsd;
  final String? memo;
  final String? fromToken;
  final String? toToken;
  final String? query;
  final int? marketId;
  final String? polymarketId; // condition_id for Polymarket
  final int? outcome;
  final String? direction; // "yes" or "no" for bets
  final String raw;
  /// For multi-runner Polymarket events: the runners to pick from.
  final List<Map<String, dynamic>>? polymarketRunners;
  final String? polymarketEventTitle;
  /// EVM chain name for same-chain swaps (e.g. "polygon", "bsc").
  final String? chain;

  const ParsedIntent({
    required this.type,
    required this.raw,
    this.address,
    this.amount,
    this.amountIsUsd = true,
    this.memo,
    this.fromToken,
    this.toToken,
    this.query,
    this.marketId,
    this.polymarketId,
    this.outcome,
    this.direction,
    this.polymarketRunners,
    this.polymarketEventTitle,
    this.chain,
  });

  ParsedIntent copyWith({
    IntentType? type,
    String? address,
    double? amount,
    bool? amountIsUsd,
    String? memo,
    String? fromToken,
    String? toToken,
    String? query,
    int? marketId,
    String? polymarketId,
    int? outcome,
    String? direction,
    String? raw,
    List<Map<String, dynamic>>? polymarketRunners,
    String? polymarketEventTitle,
    String? chain,
  }) {
    return ParsedIntent(
      type: type ?? this.type,
      raw: raw ?? this.raw,
      address: address ?? this.address,
      amount: amount ?? this.amount,
      amountIsUsd: amountIsUsd ?? this.amountIsUsd,
      memo: memo ?? this.memo,
      fromToken: fromToken ?? this.fromToken,
      toToken: toToken ?? this.toToken,
      query: query ?? this.query,
      marketId: marketId ?? this.marketId,
      polymarketId: polymarketId ?? this.polymarketId,
      outcome: outcome ?? this.outcome,
      direction: direction ?? this.direction,
      polymarketRunners: polymarketRunners ?? this.polymarketRunners,
      polymarketEventTitle: polymarketEventTitle ?? this.polymarketEventTitle,
      chain: chain ?? this.chain,
    );
  }

  String get summary {
    switch (type) {
      case IntentType.balance:
        return 'Checking balance...';
      case IntentType.send:
        final amt = amount != null
            ? (amountIsUsd ? '\$${amount!.toStringAsFixed(2)}' : '${amount!.toStringAsFixed(4)} ZEC')
            : '?';
        return 'Send $amt${address != null ? ' to ${truncAddr(address!)}' : ''}';
      case IntentType.swap:
        final from = fromToken ?? 'ZEC';
        final to = toToken ?? '?';
        final amt = amount != null
            ? (amountIsUsd ? '\$${amount!.toStringAsFixed(2)} ' : '${amount!.toStringAsFixed(4)} ')
            : '';
        return 'Swap $amt$from → $to';
      case IntentType.evmSwap:
        final from = fromToken ?? '?';
        final to = toToken ?? '?';
        final chainLabel = chain ?? 'EVM';
        final amt = amount != null ? '${amount!.toStringAsFixed(4)} ' : '';
        return 'Swap $amt$from → $to on $chainLabel';
      case IntentType.shield:
        return 'Shield transparent funds';
      case IntentType.marketSearch:
        return 'Search markets: "${query ?? raw}"';
      case IntentType.marketDiscover:
        return 'Finding promising markets...';
      case IntentType.bet:
        final amt = amount != null ? '\$${amount!.toStringAsFixed(2)}' : '?';
        final dir = direction != null ? ' ${direction!.toUpperCase()}' : '';
        return 'Bet $amt$dir on market #${marketId ?? "?"}';
      case IntentType.betPolymarket:
        final amt = amount != null ? '\$${amount!.toStringAsFixed(2)}' : '?';
        final dir = direction != null ? ' ${direction!.toUpperCase()}' : '';
        return 'Bet $amt$dir on Polymarket';
      case IntentType.portfolio:
        return 'Checking your positions...';
      case IntentType.sell:
        return 'Selling position on market #${marketId ?? "?"}';
      case IntentType.sweep:
        return 'Checking what you can sweep back to ZEC...';
      case IntentType.help:
        return 'Help';
      case IntentType.unknown:
        return raw;
    }
  }

  static String truncAddr(String addr) {
    if (addr.length <= 16) return addr;
    return '${addr.substring(0, 8)}...${addr.substring(addr.length - 6)}';
  }
}

class IntentParser {
  // Matches: $5, $5.50, 5$, 5.50$, 5 dollars, 5 usd
  static final _usdPattern = RegExp(
    r'(?:\$\s*(\d+\.?\d*)|(\d+\.?\d*)\s*\$|(\d+\.?\d*)\s*(?:dollars?|usd))',
    caseSensitive: false,
  );

  // Matches: 0.5 ZEC, 1.2 zec, 5 zcash
  static final _zecPattern = RegExp(
    r'(\d+\.?\d*)\s*(?:zec|zcash)',
    caseSensitive: false,
  );

  // Bare number fallback (only digits, possibly with decimal)
  static final _bareNumberPattern = RegExp(r'(?<!\w)(\d+\.?\d*)(?!\w)');

  static final _addressPattern = RegExp(
    r'(u1[a-z0-9]{60,}|zs1[a-z0-9]{60,}|t1[a-zA-Z0-9]{33})',
    caseSensitive: false,
  );

  // Market ID: "market #123", "market 123", "#123", or bare 4+ digit number
  static final _marketIdPattern = RegExp(
    r'(?:market\s*#?\s*|#)(\d{4,})',
    caseSensitive: false,
  );
  static final _bareMarketIdPattern = RegExp(
    r'(?<!\d)(\d{4,})(?!\d)',
  );

  // Direction: allow common typos (yess, yea, noo, nah)
  static final _directionPattern = RegExp(
    r'\b(ye+s+|yea+h?|ya|no+|nah|true|false|for|against)\b',
    caseSensitive: false,
  );

  /// Extract a USD amount from text. Tries $X, X$, X dollars, then bare number.
  static double? _parseUsdAmount(String text) {
    final m = _usdPattern.firstMatch(text);
    if (m != null) {
      final v = m.group(1) ?? m.group(2) ?? m.group(3);
      if (v != null) return double.tryParse(v);
    }
    return null;
  }

  /// Extract a ZEC amount from text.
  static double? _parseZecAmount(String text) {
    final m = _zecPattern.firstMatch(text);
    if (m != null) return double.tryParse(m.group(1)!);
    return null;
  }

  /// Extract any bare number (fallback when no currency specified).
  static double? _parseBareNumber(String text, {Set<String> exclude = const {}}) {
    var clean = text;
    // Remove parts we've already parsed (market IDs, etc.)
    for (final ex in exclude) {
      clean = clean.replaceAll(ex, '');
    }
    final m = _bareNumberPattern.firstMatch(clean);
    if (m != null) return double.tryParse(m.group(1)!);
    return null;
  }

  static ParsedIntent parse(String input) {
    final trimmed = input.trim();
    final lower = trimmed.toLowerCase();

    if (_isHelp(lower)) {
      return ParsedIntent(type: IntentType.help, raw: trimmed);
    }

    if (_isBalance(lower)) {
      return ParsedIntent(type: IntentType.balance, raw: trimmed);
    }

    if (_isShield(lower)) {
      return ParsedIntent(type: IntentType.shield, raw: trimmed);
    }

    if (_isMarketDiscover(lower)) {
      return ParsedIntent(type: IntentType.marketDiscover, raw: trimmed, query: trimmed);
    }

    if (_isPortfolio(lower)) {
      return ParsedIntent(type: IntentType.portfolio, raw: trimmed);
    }

    if (_isSweep(lower)) {
      return ParsedIntent(type: IntentType.sweep, raw: trimmed);
    }

    if (_isSell(lower)) {
      return _parseSell(trimmed, lower);
    }

    if (_isBetPolymarket(lower)) {
      return _parseBetPolymarket(trimmed, lower);
    }

    if (_isBet(lower)) {
      return _parseBet(trimmed, lower);
    }

    if (_isSwap(lower)) {
      return _parseSwap(trimmed, lower);
    }

    if (_isSend(lower)) {
      return _parseSend(trimmed, lower);
    }

    if (_isMarketSearch(lower)) {
      return _parseMarketSearch(trimmed, lower);
    }

    return ParsedIntent(type: IntentType.unknown, raw: trimmed);
  }

  static bool _isHelp(String s) =>
      s == 'help' || s == '?' || s.startsWith('what can');

  static bool _isBalance(String s) =>
      s.contains('balance') || s == 'bal' || s.contains('how much');

  static bool _isShield(String s) =>
      s.contains('shield') || s.contains('shielding');

  static bool _isPortfolio(String s) =>
      s.contains('my bet') || s.contains('my position') || s.contains('portfolio') ||
      s.contains('positions') || s.contains('my bets') || s == 'bets';

  static bool _isSweep(String s) =>
      s.contains('sweep') || s.contains('usdt to zec') || s.contains('convert usdt') ||
      s.contains('cash out usdt') || s.contains('withdraw usdt') ||
      s.contains('convert everything') || s.contains('bring it all back') ||
      s.contains('withdraw everything') || s.contains('convert all') ||
      (s.contains('cash out') && !s.contains('market'));

  static bool _isSell(String s) =>
      s.contains('sell') || s.contains('close') || s.contains('cash out') ||
      s.contains('cashout') || s.contains('exit');

  static bool _isBetPolymarket(String s) =>
      s.contains('polymarket') || s.contains('poly market');

  static bool _isBet(String s) =>
      s.contains('bet') || s.contains('wager') || s.contains('place a bet');

  static bool _isSwap(String s) =>
      s.contains('swap') || s.contains('convert') || s.contains('exchange');

  static bool _isSend(String s) =>
      s.contains('send') || s.contains('transfer') || s.contains('pay');

  static bool _isMarketSearch(String s) =>
      s.contains('market') || s.contains('prediction') || s.contains('odds');

  static bool _isMarketDiscover(String s) =>
      s.contains('promising') ||
      s.contains('good bet') ||
      s.contains('best bet') ||
      s.contains('find market') ||
      s.contains('suggest') ||
      s.contains('recommend') ||
      s.contains('trending') ||
      s.contains('hot market') ||
      s.contains('opportunities');

  static ParsedIntent _parseBet(String raw, String lower) {
    // Try explicit "market #ID" first, then fall back to bare 4+ digit number
    var marketMatch = _marketIdPattern.firstMatch(raw);
    int? marketId;
    String marketIdStr = '';
    if (marketMatch != null) {
      marketId = int.tryParse(marketMatch.group(1)!);
      marketIdStr = marketMatch.group(0)!;
    } else {
      // Bare large number as market ID (e.g., "bet $2 yes on 22033")
      final bareMatch = _bareMarketIdPattern.firstMatch(raw);
      if (bareMatch != null) {
        marketId = int.tryParse(bareMatch.group(1)!);
        marketIdStr = bareMatch.group(0)!;
      }
    }

    // Try USD amount first, then bare number (default to USD for bets)
    var amount = _parseUsdAmount(raw);
    var isUsd = true;
    if (amount == null) {
      final zec = _parseZecAmount(raw);
      if (zec != null) {
        amount = zec;
        isUsd = false;
      } else {
        amount = _parseBareNumber(raw, exclude: {marketIdStr});
        isUsd = true;
      }
    }

    // Parse direction — normalize typos to yes/no
    String? direction;
    final dirMatch = _directionPattern.firstMatch(lower);
    if (dirMatch != null) {
      final d = dirMatch.group(1)!.toLowerCase();
      final isYes = d.startsWith('y') || d == 'true' || d == 'for';
      direction = isYes ? 'yes' : 'no';
    }

    return ParsedIntent(
      type: IntentType.bet,
      raw: raw,
      amount: amount,
      amountIsUsd: isUsd,
      marketId: marketId,
      outcome: direction == 'no' ? 1 : (direction == 'yes' ? 0 : null),
      direction: direction,
      query: raw,
    );
  }

  // Matches Polymarket condition IDs: 0x-prefixed hex or bare hex (40+ chars)
  static final _polymarketIdPattern = RegExp(
    r'(?:polymarket|poly market)\s+(?:0x)?([a-f0-9]{40,})',
    caseSensitive: false,
  );
  // Fallback: any long hex string after "polymarket"
  static final _polymarketIdFallback = RegExp(
    r'([a-f0-9]{8,}-[a-f0-9-]+|0x[a-f0-9]{40,}|[a-f0-9]{40,})',
    caseSensitive: false,
  );

  static ParsedIntent _parseBetPolymarket(String raw, String lower) {
    String? polyId;

    // Try structured pattern first
    final match = _polymarketIdPattern.firstMatch(raw);
    if (match != null) {
      polyId = match.group(1)!;
      if (!polyId.startsWith('0x')) polyId = '0x$polyId';
    } else {
      // Try finding any long hex string in the text
      final fallback = _polymarketIdFallback.firstMatch(raw);
      if (fallback != null) {
        polyId = fallback.group(1)!;
        if (polyId.length >= 40 && !polyId.startsWith('0x')) polyId = '0x$polyId';
      }
    }

    // Amount
    var amount = _parseUsdAmount(raw);
    var isUsd = true;
    if (amount == null) {
      final zec = _parseZecAmount(raw);
      if (zec != null) { amount = zec; isUsd = false; }
      else { amount = _parseBareNumber(raw); isUsd = true; }
    }

    // Direction
    String? direction;
    final dirMatch = _directionPattern.firstMatch(lower);
    if (dirMatch != null) {
      final d = dirMatch.group(1)!.toLowerCase();
      direction = (d.startsWith('y') || d == 'true' || d == 'for') ? 'yes' : 'no';
    }

    return ParsedIntent(
      type: IntentType.betPolymarket,
      raw: raw,
      amount: amount,
      amountIsUsd: isUsd,
      polymarketId: polyId,
      outcome: direction == 'no' ? 1 : (direction == 'yes' ? 0 : null),
      direction: direction,
    );
  }

  static ParsedIntent _parseSell(String raw, String lower) {
    var marketMatch = _marketIdPattern.firstMatch(raw);
    int? marketId;
    if (marketMatch != null) {
      marketId = int.tryParse(marketMatch.group(1)!);
    } else {
      final bareMatch = _bareMarketIdPattern.firstMatch(raw);
      if (bareMatch != null) marketId = int.tryParse(bareMatch.group(1)!);
    }

    return ParsedIntent(
      type: IntentType.sell,
      raw: raw,
      marketId: marketId,
    );
  }

  static final _evmTokens = {
    'POL', 'MATIC', 'BNB', 'USDT', 'USDC', 'USDC.E', 'ETH', 'WETH', 'WBNB', 'WMATIC', 'WPOL', 'DAI', 'BUSD',
  };
  static final _chainNames = {
    'POLYGON': 'polygon', 'POL': 'polygon', 'MATIC': 'polygon',
    'BSC': 'bsc', 'BNB': 'bsc', 'BINANCE': 'bsc',
  };

  static ParsedIntent _parseSwap(String raw, String lower) {
    String? from, to;
    final swapTokens = RegExp(r'(\w+(?:\.\w+)?)\s*(?:to|→|->|into)\s*(\w+(?:\.\w+)?)', caseSensitive: false);
    final tokenMatch = swapTokens.firstMatch(raw);
    if (tokenMatch != null) {
      from = tokenMatch.group(1)!.toUpperCase();
      to = tokenMatch.group(2)!.toUpperCase();
    }

    // Detect explicit chain: "on polygon", "on bsc"
    String? chain;
    final chainMatch = RegExp(r'\bon\s+(polygon|pol|matic|bsc|bnb|binance)\b', caseSensitive: false).firstMatch(lower);
    if (chainMatch != null) {
      chain = _chainNames[chainMatch.group(1)!.toUpperCase()];
    }

    // If both tokens are EVM tokens (not ZEC), classify as evmSwap
    final fromIsEvm = from != null && _evmTokens.contains(from);
    final toIsEvm = to != null && _evmTokens.contains(to);
    final isEvmSwap = chain != null || (fromIsEvm && toIsEvm);

    // For EVM swaps, the amount is in the source token units, not USD
    var amount = _parseUsdAmount(raw);
    var isUsd = true;
    if (amount == null) {
      final zec = _parseZecAmount(raw);
      if (zec != null) {
        amount = zec;
        isUsd = false;
      } else {
        amount = _parseBareNumber(raw);
        isUsd = isEvmSwap ? false : true;
      }
    }

    if (isEvmSwap) {
      // Infer chain from token if not explicitly stated
      chain ??= _inferChain(from, to);
      return ParsedIntent(
        type: IntentType.evmSwap,
        raw: raw,
        amount: amount,
        amountIsUsd: isUsd,
        fromToken: from,
        toToken: to,
        chain: chain,
      );
    }

    return ParsedIntent(
      type: IntentType.swap,
      raw: raw,
      amount: amount,
      amountIsUsd: isUsd,
      fromToken: from ?? 'ZEC',
      toToken: to,
    );
  }

  static String? _inferChain(String? from, String? to) {
    for (final t in [from, to]) {
      if (t == null) continue;
      if (t == 'POL' || t == 'MATIC' || t == 'WPOL' || t == 'WMATIC' || t == 'USDC.E') return 'polygon';
      if (t == 'BNB' || t == 'WBNB' || t == 'BUSD') return 'bsc';
    }
    return null;
  }

  static ParsedIntent _parseSend(String raw, String lower) {
    final addrMatch = _addressPattern.firstMatch(raw);

    String? memo;
    final memoMatch = RegExp(r"""memo\s*[:\s]+["']?(.+?)["']?\s*$""", caseSensitive: false).firstMatch(raw);
    if (memoMatch != null) memo = memoMatch.group(1);

    // Try USD first for sends
    var amount = _parseUsdAmount(raw);
    var isUsd = true;
    if (amount == null) {
      final zec = _parseZecAmount(raw);
      if (zec != null) {
        amount = zec;
        isUsd = false;
      } else {
        amount = _parseBareNumber(raw);
        isUsd = true;
      }
    }

    return ParsedIntent(
      type: IntentType.send,
      raw: raw,
      amount: amount,
      amountIsUsd: isUsd,
      address: addrMatch?.group(1),
      memo: memo,
    );
  }

  static ParsedIntent _parseMarketSearch(String raw, String lower) {
    var query = raw;
    for (final prefix in ['search markets', 'find markets', 'show markets',
                          'market search', 'markets', 'market', 'prediction']) {
      final idx = lower.indexOf(prefix);
      if (idx >= 0) {
        query = raw.substring(idx + prefix.length).trim();
        if (query.startsWith(':') || query.startsWith('for')) {
          query = query.substring(query.indexOf(' ') + 1).trim();
        }
        break;
      }
    }
    return ParsedIntent(
      type: IntentType.marketSearch,
      raw: raw,
      query: query.isEmpty ? null : query,
    );
  }
}
