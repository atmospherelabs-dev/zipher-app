import 'dart:math' as math;

import '../../services/near_intents.dart';
import 'wallet_conversation.dart';

/// Display names and accepted spellings for the networks a swap can deliver to.
abstract final class SwapNetworks {
  static const _names = {
    'abs': 'Abstract',
    'adi': 'ADI',
    'aleo': 'Aleo',
    'dash': 'Dash',
    'fogo': 'Fogo',
    'hypercore': 'Hyperliquid',
    'miden': 'Miden',
    'monad': 'Monad',
    'movement': 'Movement',
    'plasma': 'Plasma',
    'scroll': 'Scroll',
    'xlayer': 'X Layer',
  };

  static const _aliases = {
    'solana': 'sol',
    'ethereum': 'eth',
    'mainnet': 'eth',
    'erc20': 'eth',
    'arbitrum': 'arb',
    'arbitrum one': 'arb',
    'optimism': 'op',
    'polygon': 'pol',
    'matic': 'pol',
    'bnb': 'bsc',
    'bnb chain': 'bsc',
    'binance': 'bsc',
    'bep20': 'bsc',
    'avalanche': 'avax',
    'bitcoin': 'btc',
    'trc20': 'tron',
    'trx': 'tron',
    'stellar': 'stellar',
    'xlm': 'stellar',
    'ada': 'cardano',
    'apt': 'aptos',
    'dogecoin': 'doge',
    'litecoin': 'ltc',
    'bitcoin cash': 'bch',
    'ripple': 'xrp',
    'xrpl': 'xrp',
    'berachain': 'bera',
    'xdai': 'gnosis',
    'abstract': 'abs',
    'hyperliquid': 'hypercore',
    'x layer': 'xlayer',
  };

  /// Most ZEC leaves towards these, in this order.
  static const priority = [
    'sol',
    'eth',
    'base',
    'arb',
    'tron',
    'bsc',
    'near',
    'btc',
    'op',
    'pol',
    'avax',
    'sui',
    'ton',
    'aptos',
    'gnosis',
    'stellar',
  ];

  static String name(String id) {
    final key = id.toLowerCase();
    final known = ChainInfo.byId(key)?.name ?? _names[key];
    if (known != null) return known;
    return key.isEmpty ? key : '${key[0].toUpperCase()}${key.substring(1)}';
  }

  /// The network id a person meant, or null when the text names no network.
  static String? id(String input, Iterable<String> known) {
    final text = input.trim().toLowerCase();
    if (text.isEmpty) return null;
    final alias = _aliases[text];
    for (final id in known) {
      final key = id.toLowerCase();
      if (key == text || key == alias || name(key).toLowerCase() == text) {
        return key;
      }
    }
    return null;
  }

  /// Whether the text names a network at all, offered or not.
  static bool isNetworkName(String input) {
    final text = input.trim().toLowerCase();
    return _aliases.containsKey(text) ||
        ChainInfo.all.any((c) => c.id == text || c.name.toLowerCase() == text);
  }
}

/// Swappable destinations from the provider's token list. Resolution is exact;
/// near misses are only ever offered back as suggestions, never chosen.
class SwapCatalog {
  SwapCatalog(Iterable<NearToken> tokens) {
    final seen = <String, int>{};
    final usable = tokens.where((t) =>
        t.assetId.isNotEmpty &&
        t.symbol.isNotEmpty &&
        !t.symbol.contains('(') &&
        t.symbol.toUpperCase() != 'ZEC' &&
        t.blockchain.toLowerCase() != 'zec' &&
        (t.price ?? 0) > 0);
    for (final t in usable) {
      final key = '${_key(t.symbol)}:${t.blockchain.toLowerCase()}';
      seen[key] = (seen[key] ?? 0) + 1;
    }
    for (final t in usable) {
      // Two assets sharing a symbol on one network cannot be told apart in chat.
      if (seen['${_key(t.symbol)}:${t.blockchain.toLowerCase()}'] != 1) {
        continue;
      }
      _bySymbol.putIfAbsent(_key(t.symbol), () => []).add(t);
    }
    for (final entry in _bySymbol.entries) {
      entry.value.sort((a, b) => _rank(entry.key, a) - _rank(entry.key, b));
    }
  }

  final _bySymbol = <String, List<NearToken>>{};

  static const popular = ['USDC', 'USDT', 'BTC', 'ETH', 'SOL'];

  static const _nameToSymbol = {
    'BITCOIN': 'BTC',
    'ETHER': 'ETH',
    'ETHEREUM': 'ETH',
    'SOLANA': 'SOL',
    'TETHER': 'USDT',
    'USD COIN': 'USDC',
    'USDCOIN': 'USDC',
    'DOGECOIN': 'DOGE',
    'LITECOIN': 'LTC',
    'RIPPLE': 'XRP',
    'CARDANO': 'ADA',
    'TRON': 'TRX',
    'POLYGON': 'POL',
    'MATIC': 'POL',
    'AVALANCHE': 'AVAX',
    'BINANCE': 'BNB',
  };

  /// One typed symbol can cover a wrapped form the provider lists separately.
  static const _alsoListedAs = {
    'NEAR': ['WNEAR'],
  };

  static const _nativeNetwork = {
    'BTC': 'btc',
    'ETH': 'eth',
    'SOL': 'sol',
    'BNB': 'bsc',
    'DOGE': 'doge',
    'XRP': 'xrp',
    'ADA': 'cardano',
    'TRX': 'tron',
    'AVAX': 'avax',
    'LTC': 'ltc',
    'BCH': 'bch',
    'SUI': 'sui',
    'APT': 'aptos',
    'TON': 'ton',
    'XLM': 'stellar',
    'NEAR': 'near',
    'WNEAR': 'near',
    'ARB': 'arb',
    'OP': 'op',
    'POL': 'pol',
    'BERA': 'bera',
    'STRK': 'starknet',
    'GNO': 'gnosis',
  };

  static String _key(String symbol) =>
      symbol.trim().replaceFirst(RegExp(r'^\$'), '').toUpperCase();

  static int _rank(String symbol, NearToken token) {
    final chain = token.blockchain.toLowerCase();
    if (_nativeNetwork[symbol] == chain) return -1;
    final index = SwapNetworks.priority.indexOf(chain);
    return index < 0 ? SwapNetworks.priority.length : index;
  }

  bool get isEmpty => _bySymbol.isEmpty;

  List<String> get popularSymbols => [
        for (final s in popular)
          if (_bySymbol.containsKey(s)) s
      ];

  /// Networks for an exactly named token, best first. Empty when unknown.
  List<NearToken> networksFor(String query) {
    final typed = _key(query);
    if (typed.isEmpty) return const [];
    final symbol = _nameToSymbol[typed] ?? typed;
    final found = <NearToken>[
      ...?_bySymbol[symbol],
      for (final other in _alsoListedAs[symbol] ?? const <String>[])
        ...?_bySymbol[other],
    ];
    if (found.length < 2) return found;
    final order = {for (final (i, t) in found.indexed) t.assetId: i};
    return found
      ..sort((a, b) {
        final rank = _rank(symbol, a) - _rank(symbol, b);
        return rank != 0 ? rank : order[a.assetId]! - order[b.assetId]!;
      });
  }

  /// Tokens the person may have meant. Popular tokens outrank closer but
  /// obscure spellings: "USED" should offer USDC before USAD.
  List<String> suggest(String query, {int limit = 4}) {
    final typed = _key(query);
    if (typed.isEmpty || typed.length > 12) return popularSymbols;
    final maxDistance = typed.length <= 3 ? 1 : 2;
    final scored = <(int, String)>[];
    for (final entry in _bySymbol.entries) {
      final symbol = entry.key;
      final popularity = popular.indexOf(symbol);
      final weight = popularity < 0 ? 15 : popularity;
      int? score;
      if (typed.length >= 2 && symbol.startsWith(typed)) {
        score = 5 + weight;
      } else {
        final distance = _editDistance(typed, symbol);
        if (distance <= maxDistance) score = distance * 10 + weight;
      }
      if (score != null) scored.add((score, entry.value.first.symbol));
    }
    for (final entry in _nameToSymbol.entries) {
      if (typed.length >= 3 &&
          entry.key.startsWith(typed) &&
          _bySymbol.containsKey(entry.value)) {
        scored.add((4, _bySymbol[entry.value]!.first.symbol));
      }
    }
    scored.sort(
        (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final result = <String>[];
    for (final (_, symbol) in scored) {
      if (!result.contains(symbol)) result.add(symbol);
      if (result.length == limit) break;
    }
    return result;
  }

  /// Optimal string alignment distance: one swapped pair counts once.
  static int _editDistance(String a, String b) {
    final rows = List.generate(
        a.length + 1, (i) => List<int>.filled(b.length + 1, 0),
        growable: false);
    for (var i = 0; i <= a.length; i++) {
      rows[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      rows[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var best = math.min(math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1),
            rows[i - 1][j - 1] + cost);
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
          best = math.min(best, rows[i - 2][j - 2] + 1);
        }
        rows[i][j] = best;
      }
    }
    return rows[a.length][b.length];
  }
}

enum SwapStep { amount, token, network, recipient, ready }

enum SwapChange { none, amount, token, network, recipient }

class SwapReply {
  const SwapReply(
      {this.change = SwapChange.none,
      this.replaced = false,
      this.problem,
      this.suggestions = const []});

  final SwapChange change;

  /// The changed field already had a value: this was a correction.
  final bool replaced;

  /// What was wrong with the input, when nothing could be used.
  final String? problem;

  /// Token symbols to offer after an unknown token.
  final List<String> suggestions;
}

/// A ZEC-out swap being collected. Every field can be corrected at any step by
/// typing it again; a mistake never discards the fields already given.
class SwapDraft {
  SwapDraft(this.catalog,
      {this.addressValidator = chainAddressValidator,
      this.hasFormat = chainHasAddressFormat});

  final SwapCatalog catalog;
  final String? Function(String?, String) addressValidator;
  final bool Function(String) hasFormat;

  int? zatoshis;
  List<NearToken> networks = const [];
  NearToken? token;
  String? recipient;

  SwapStep get step => zatoshis == null
      ? SwapStep.amount
      : networks.isEmpty
          ? SwapStep.token
          : token == null
              ? SwapStep.network
              : recipient == null
                  ? SwapStep.recipient
                  : SwapStep.ready;

  String? get symbol =>
      token?.symbol ?? (networks.isEmpty ? null : networks.first.symbol);

  String? get networkName =>
      token == null ? null : SwapNetworks.name(token!.blockchain);

  /// "1.5 ZEC to USDC · Solana", as far as it is known.
  String get summary => [
        if (zatoshis != null) '${WalletConversation.formatZec(zatoshis!)} ZEC',
        if (symbol != null) 'to $symbol',
        if (networkName != null) '· $networkName',
      ].join(' ');

  /// Start from whatever a one-line request already contained.
  SwapReply seed({int? zatoshis, String? token, String? network}) {
    this.zatoshis = zatoshis;
    var reply = const SwapReply();
    if (token != null) {
      reply = _useToken(token) ?? _unknownToken(token);
    }
    if (network != null && networks.isNotEmpty && reply.problem == null) {
      reply = _useNetwork(network) ??
          SwapReply(
              problem:
                  '$symbol isn’t available on ${_title(network)} through this route.');
    }
    return reply;
  }

  SwapReply accept(String text) {
    final input = text.trim();
    final amount = WalletConversation.parseZatoshis(input);
    if (amount != null) {
      final replaced = zatoshis != null;
      zatoshis = amount;
      return SwapReply(change: SwapChange.amount, replaced: replaced);
    }
    final network = _useNetwork(input);
    if (network != null) return network;
    final tokenReply = _looksLikeToken(input) ? _useToken(input) : null;
    if (tokenReply != null) return tokenReply;

    switch (step) {
      case SwapStep.amount:
        return const SwapReply(
            problem:
                'Amounts are in ZEC, with up to 8 decimal places. For example: 0.5');
      case SwapStep.token:
        return _unknownToken(input);
      case SwapStep.network:
        return SwapReply(
            problem: SwapNetworks.isNetworkName(input)
                ? '$symbol isn’t available on ${_title(input)} through this route.'
                : 'Choose one of the networks for $symbol.');
      case SwapStep.recipient:
      case SwapStep.ready:
        final problem = _recipientProblem(input, token!);
        if (problem == null) {
          final replaced = recipient != null;
          recipient = input;
          return SwapReply(change: SwapChange.recipient, replaced: replaced);
        }
        return SwapReply(problem: problem);
    }
  }

  static String _title(String text) {
    final t = text.trim();
    return t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';
  }

  static bool _looksLikeToken(String input) =>
      RegExp(r'^\$?[A-Za-z][A-Za-z0-9. ]{0,15}$').hasMatch(input);

  SwapReply _unknownToken(String input) {
    final shown = input.length > 16 ? '${input.substring(0, 16)}…' : input;
    final suggestions = _looksLikeToken(input)
        ? catalog.suggest(input)
        : catalog.popularSymbols;
    return SwapReply(
        problem: 'I couldn’t find a token called “$shown”.',
        suggestions:
            suggestions.isEmpty ? catalog.popularSymbols : suggestions);
  }

  SwapReply? _useToken(String query) {
    final found = catalog.networksFor(query);
    if (found.isEmpty) return null;
    final previousChain = token?.blockchain.toLowerCase();
    final replaced = networks.isNotEmpty;
    networks = found;
    // Keep the chosen network when the new token also lives there.
    token = found.length == 1
        ? found.single
        : found
            .where((t) => t.blockchain.toLowerCase() == previousChain)
            .firstOrNull;
    _dropUnfitRecipient();
    return SwapReply(change: SwapChange.token, replaced: replaced);
  }

  SwapReply? _useNetwork(String input) {
    if (networks.isEmpty) return null;
    final id = SwapNetworks.id(input, networks.map((t) => t.blockchain));
    if (id == null) return null;
    final replaced = token != null;
    token = networks.firstWhere((t) => t.blockchain.toLowerCase() == id);
    _dropUnfitRecipient();
    return SwapReply(change: SwapChange.network, replaced: replaced);
  }

  void _dropUnfitRecipient() {
    final current = recipient;
    if (current == null) return;
    if (token == null || _recipientProblem(current, token!) != null) {
      recipient = null;
    }
  }

  String? _recipientProblem(String input, NearToken token) {
    final network = SwapNetworks.name(token.blockchain);
    if (input.contains(RegExp(r'\s')) || input.length > 512) {
      return 'Paste one $network address, without spaces.';
    }
    final chain = token.blockchain.toLowerCase();
    // Chains without a known format still get a floor against stray words.
    if (hasFormat(chain)
        ? addressValidator(input, chain) != null
        : input.length < 10) {
      return 'That doesn’t look like a $network address.';
    }
    return null;
  }
}
