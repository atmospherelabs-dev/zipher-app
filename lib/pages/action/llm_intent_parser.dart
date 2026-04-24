import 'dart:convert';

import 'package:logger/logger.dart';

import '../../services/llm_service.dart';
import 'intent.dart';

final _log = Logger();

/// Intent parser powered by an on-device LLM.
///
/// Falls back to [IntentParser] (regex-based) when:
/// - The LLM is not loaded
/// - The LLM output can't be parsed as valid JSON
/// - The model returns "unknown"
class LlmIntentParser {
  LlmIntentParser._();
  static final instance = LlmIntentParser._();

  /// Recent context for resolving ambiguous references.
  /// Set by the Action page after showing markets, results, etc.
  String? _recentContext;

  /// Stored Polymarket discovery rows for resolving positional references.
  List<Map<String, dynamic>> _polymarketRows = [];

  /// Update the context with recently shown markets or actions.
  void setContext(String? context) {
    _recentContext = context;
    if (context == null || !context.startsWith('Polymarket events:')) {
      _polymarketRows = [];
      _log.d('[LLM] Context set (non-Polymarket), cleared stored rows');
    } else {
      _log.d('[LLM] Context set (Polymarket), ${_polymarketRows.length} rows stored');
    }
  }

  /// Store Polymarket discovery rows for positional resolution.
  void setPolymarketRows(List<Map<String, dynamic>> rows) {
    _polymarketRows = List.of(rows);
    _log.d('[LLM] Stored ${rows.length} Polymarket rows for resolution');
  }

  /// Resolve a 1-based runner_index against stored Polymarket rows.
  /// Returns the top_runners list entry (with condition_id, token_id, label, price).
  Map<String, dynamic>? resolvePolymarketRunner(int index, {String? label}) {
    if (index < 1 || index > _polymarketRows.length) {
      _log.w('[LLM] resolvePolymarketRunner: index $index out of range (have ${_polymarketRows.length} rows)');
      return null;
    }
    final row = _polymarketRows[index - 1];
    final runners = (row['top_runners'] as List<dynamic>?) ?? [];
    _log.d('[LLM] resolvePolymarketRunner: index=$index label=$label event="${row['title']}" runners=${runners.length}');
    if (label != null && label.isNotEmpty) {
      final lower = label.toLowerCase();
      final match = runners.cast<Map<String, dynamic>>().where(
        (r) => (r['label'] as String? ?? '').toLowerCase().contains(lower),
      ).firstOrNull;
      if (match != null) {
        _log.d('[LLM] Matched runner by label: ${match['label']} → ${match['condition_id']}');
        return {...match, '_event_title': row['title']};
      }
    }
    if (runners.isNotEmpty) {
      final first = runners.first as Map<String, dynamic>;
      _log.d('[LLM] Using first runner: ${first['label']} → ${first['condition_id']}');
      return {...first, '_event_title': row['title']};
    }
    return null;
  }

  /// Build context string from a list of markets.
  static String marketsContext(List<Map<String, dynamic>> markets) {
    if (markets.isEmpty) return '';
    final lines = markets.take(5).map((m) {
      final id = m['id'] ?? m['market_id'] ?? '?';
      final title = m['title'] ?? m['question'] ?? '?';
      return '#$id "$title"';
    }).join(', ');
    return 'Recent markets shown: $lines';
  }

  /// LLM context after Polymarket discovery (grouped rows + top runners).
  static String polymarketDiscoveryContext(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return '';
    final buf = StringBuffer('Polymarket events:\n');
    for (var i = 0; i < rows.length && i < 10; i++) {
      final r = rows[i];
      final title = r['title'] ?? '?';
      final runners = (r['top_runners'] as List<dynamic>?) ?? [];
      final bits = runners.take(4).map((u) {
        final m = u as Map<String, dynamic>;
        final pct = ((m['price'] as num?)?.toDouble() ?? 0) * 100;
        return '${m['label']} ${pct.toStringAsFixed(0)}%';
      }).join(', ');
      buf.writeln('${i + 1}. "$title" → $bits');
    }
    return buf.toString();
  }

  /// Parse user input using the LLM if available, otherwise regex.
  Future<ParsedIntent> parse(String input) async {
    // Fast path: if model isn't loaded, use regex
    if (LlmService.instance.status != LlmStatus.loaded) {
      _log.d('[LLM] Model not loaded, using regex parser');
      return IntentParser.parse(input);
    }

    _log.d('[LLM] Parsing: "$input"');
    _log.d('[LLM] Context present: ${_recentContext != null}, polymarketRows: ${_polymarketRows.length}');
    if (_recentContext != null) {
      final preview = _recentContext!.length > 200
          ? '${_recentContext!.substring(0, 200)}…'
          : _recentContext!;
      _log.d('[LLM] Context preview: $preview');
    }

    try {
      final raw = await LlmService.instance.classifyIntent(
        input,
        context: _recentContext,
      );
      _log.d('[LLM] raw output: $raw');

      final json = _extractJson(raw);
      if (json == null) {
        _log.w('[LLM] Could not extract JSON from output, falling back to regex');
        return IntentParser.parse(input);
      }

      final intent = _jsonToIntent(json, input);
      _log.d('[LLM] Parsed intent: type=${intent.type.name}, marketId=${intent.marketId}, polymarketId=${intent.polymarketId}, amount=${intent.amount}, direction=${intent.direction}');

      if (intent.type == IntentType.unknown) {
        final regexIntent = IntentParser.parse(input);
        if (regexIntent.type != IntentType.unknown) {
          _log.d('[LLM] LLM returned unknown, regex found: ${regexIntent.type.name}');
          return regexIntent;
        }
      }
      return intent;
    } catch (e) {
      _log.w('[LLM] Intent parse error: $e, falling back to regex');
      return IntentParser.parse(input);
    }
  }

  /// Extract the first JSON object from the model's output.
  Map<String, dynamic>? _extractJson(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) return null;

    try {
      return jsonDecode(text.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  ParsedIntent _jsonToIntent(Map<String, dynamic> json, String raw) {
    final type = json['type'] as String? ?? 'unknown';
    _log.d('[LLM] _jsonToIntent: type=$type, json=$json');

    switch (type) {
      case 'balance':
        return ParsedIntent(type: IntentType.balance, raw: raw);

      case 'send':
        return ParsedIntent(
          type: IntentType.send,
          raw: raw,
          amount: _toDouble(json['amount']),
          address: json['address'] as String?,
        );

      case 'swap':
        return ParsedIntent(
          type: IntentType.swap,
          raw: raw,
          amount: _toDouble(json['amount']),
          fromToken: json['from'] as String?,
          toToken: json['to'] as String?,
        );

      case 'shield':
        return ParsedIntent(type: IntentType.shield, raw: raw);

      case 'market_search':
        final query = json['query'] as String? ?? '';
        if (_isDiscoveryQuery(query)) {
          return ParsedIntent(type: IntentType.marketDiscover, raw: raw);
        }
        return ParsedIntent(
          type: IntentType.marketSearch,
          raw: raw,
          query: query.isEmpty ? null : query,
        );

      case 'market_discover':
        return ParsedIntent(
          type: IntentType.marketDiscover,
          raw: raw,
        );

      case 'bet':
        final dir = json['direction'] as String?;
        String? direction;
        int? outcome;
        if (dir != null) {
          final d = dir.toLowerCase();
          direction = (d == 'yes' || d == 'true' || d == 'for') ? 'yes' : 'no';
          outcome = direction == 'yes' ? 0 : 1;
        }
        final betMarketId = _toInt(json['market_id']);

        _log.d('[LLM] bet: market_id=$betMarketId, polymarketRows=${_polymarketRows.length}');

        if (_polymarketRows.isNotEmpty) {
          final fuzzyMatch = _fuzzyMatchPolymarketRow(raw);
          if (fuzzyMatch != null) {
            final runners = (fuzzyMatch['top_runners'] as List<dynamic>?) ?? [];
            final eventTitle = fuzzyMatch['title']?.toString() ?? '?';
            final runnerLabel = json['runner_label'] as String?;

            // If user named a specific runner, pick it
            if (runnerLabel != null && runnerLabel.isNotEmpty) {
              final lower = runnerLabel.toLowerCase();
              final runner = runners.cast<Map<String, dynamic>>().where(
                (r) => (r['label'] as String? ?? '').toLowerCase().contains(lower),
              ).firstOrNull;
              if (runner != null) {
                _log.i('[LLM] Fuzzy matched bet → "$eventTitle" runner=${runner['label']} cid=${runner['condition_id']}');
                return ParsedIntent(
                  type: IntentType.betPolymarket,
                  raw: raw,
                  amount: _toDouble(json['amount']),
                  polymarketId: runner['condition_id'] as String?,
                  outcome: outcome,
                  direction: direction,
                );
              }
            }

            // Multiple runners — let the user pick
            if (runners.length > 2) {
              _log.i('[LLM] Fuzzy matched bet → "$eventTitle" with ${runners.length} runners — showing picker');
              return ParsedIntent(
                type: IntentType.betPolymarket,
                raw: raw,
                amount: _toDouble(json['amount']),
                direction: direction,
                polymarketEventTitle: eventTitle,
                polymarketRunners: runners.cast<Map<String, dynamic>>().toList(),
              );
            }

            // Single/binary runner — pick it
            if (runners.isNotEmpty) {
              final runner = runners.first as Map<String, dynamic>;
              _log.i('[LLM] Fuzzy matched bet → "$eventTitle" runner=${runner['label']} cid=${runner['condition_id']}');
              return ParsedIntent(
                type: IntentType.betPolymarket,
                raw: raw,
                amount: _toDouble(json['amount']),
                polymarketId: runner['condition_id'] as String?,
                outcome: outcome,
                direction: direction,
              );
            }
          }

          if (betMarketId != null && betMarketId <= 100) {
            final resolved = resolvePolymarketRunner(betMarketId);
            if (resolved != null) {
              _log.i('[LLM] Positional bet #$betMarketId → Polymarket ${resolved['condition_id']} (${resolved['_event_title']})');
              return ParsedIntent(
                type: IntentType.betPolymarket,
                raw: raw,
                amount: _toDouble(json['amount']),
                polymarketId: resolved['condition_id'] as String?,
                outcome: outcome,
                direction: direction,
              );
            }
          }

          _log.w('[LLM] Polymarket rows stored but no match found for "$raw". Falling through to Myriad.');
        }

        return ParsedIntent(
          type: IntentType.bet,
          raw: raw,
          amount: _toDouble(json['amount']),
          marketId: betMarketId,
          outcome: outcome,
          direction: direction,
        );

      case 'bet_polymarket':
        final dir2 = json['direction'] as String?;
        String? direction2;
        int? outcome2;
        if (dir2 != null) {
          final d = dir2.toLowerCase();
          direction2 = (d == 'yes' || d == 'true' || d == 'for') ? 'yes' : 'no';
          outcome2 = direction2 == 'yes' ? 0 : 1;
        }

        String? polyId = json['condition_id'] as String?;
        final runnerIndex = _toInt(json['runner_index']);
        final runnerLabel = json['runner_label'] as String?;

        _log.d('[LLM] bet_polymarket: condition_id=$polyId, runner_index=$runnerIndex, runner_label=$runnerLabel, polymarketRows=${_polymarketRows.length}');

        // Fuzzy-match the user's raw text first -- the small LLM's runner_index
        // is often wrong; the user's words ("UEFA champions league") are reliable.
        if (polyId == null && _polymarketRows.isNotEmpty) {
          final fuzzyMatch = _fuzzyMatchPolymarketRow(raw);
          if (fuzzyMatch != null) {
            final runners = (fuzzyMatch['top_runners'] as List<dynamic>?) ?? [];
            Map<String, dynamic>? runner;
            if (runnerLabel != null && runnerLabel.isNotEmpty) {
              final lower = runnerLabel.toLowerCase();
              runner = runners.cast<Map<String, dynamic>>().where(
                (r) => (r['label'] as String? ?? '').toLowerCase().contains(lower),
              ).firstOrNull;
            }
            runner ??= runners.isNotEmpty ? runners.first as Map<String, dynamic> : null;
            if (runner != null) {
              polyId = runner['condition_id'] as String?;
              _log.i('[LLM] Fuzzy matched bet_polymarket → "${fuzzyMatch['title']}" runner=${runner['label']} cid=$polyId');
            }
          }
        }
        // Fallback: try the LLM's runner_index if fuzzy match found nothing
        if (polyId == null && runnerIndex != null) {
          final resolved = resolvePolymarketRunner(runnerIndex, label: runnerLabel);
          if (resolved != null) {
            polyId = resolved['condition_id'] as String?;
            _log.i('[LLM] Resolved runner_index=$runnerIndex → $polyId (${resolved['_event_title']})');
          }
        }
        polyId ??= json['market_id'] as String?;

        return ParsedIntent(
          type: IntentType.betPolymarket,
          raw: raw,
          amount: _toDouble(json['amount']),
          polymarketId: polyId,
          outcome: outcome2,
          direction: direction2,
        );

      case 'portfolio':
        return ParsedIntent(type: IntentType.portfolio, raw: raw);

      case 'sell':
        return ParsedIntent(
          type: IntentType.sell,
          raw: raw,
          marketId: _toInt(json['market_id']),
        );

      case 'sweep':
        return ParsedIntent(type: IntentType.sweep, raw: raw);

      case 'help':
        return ParsedIntent(type: IntentType.help, raw: raw);

      default:
        _log.w('[LLM] Unknown intent type: $type');
        return ParsedIntent(type: IntentType.unknown, raw: raw);
    }
  }

  /// Fuzzy-match user input against stored Polymarket event titles.
  /// Returns the best matching row, or null if no title words overlap enough.
  Map<String, dynamic>? _fuzzyMatchPolymarketRow(String userInput) {
    if (_polymarketRows.isEmpty) return null;
    final inputWords = _tokenize(userInput);
    if (inputWords.isEmpty) return null;

    Map<String, dynamic>? bestRow;
    int bestScore = 0;

    for (final row in _polymarketRows) {
      final title = (row['title'] as String? ?? '').toLowerCase();
      final titleWords = _tokenize(title);

      // Also check runner labels for matches
      final runners = (row['top_runners'] as List<dynamic>?) ?? [];
      final runnerWords = <String>{};
      for (final r in runners) {
        final label = ((r as Map<String, dynamic>)['label'] as String? ?? '').toLowerCase();
        runnerWords.addAll(_tokenize(label));
      }

      int score = 0;
      for (final w in inputWords) {
        if (titleWords.contains(w)) {
          score += 3;
        } else if (titleWords.any((t) => t.startsWith(w) || w.startsWith(t))) {
          score += 2;
        }
        if (runnerWords.contains(w)) {
          score += 2;
        } else if (runnerWords.any((r) => r.startsWith(w) || w.startsWith(r))) {
          score += 1;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        bestRow = row;
      }
    }

    _log.d('[LLM] Fuzzy match: best score=$bestScore for "${bestRow?['title']}" (input words: $inputWords)');
    // Require at least 2 points to avoid false positives
    return bestScore >= 2 ? bestRow : null;
  }

  static final _stopWords = {'the', 'a', 'an', 'on', 'in', 'to', 'of', 'for', 'is', 'at', 'by',
      'can', 'you', 'bet', 'i', 'my', 'if', 'do', 'it', 'and', 'or', 'will', 'be'};

  static Set<String> _tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 1 && !_stopWords.contains(w))
        .toSet();
  }

  static const _discoveryWords = {
    'promising', 'good', 'best', 'trending', 'hot',
    'opportunities', 'recommend', 'suggest', 'interesting',
  };

  bool _isDiscoveryQuery(String query) {
    final lower = query.toLowerCase().trim();
    return _discoveryWords.contains(lower) ||
        _discoveryWords.any((w) => lower == '$w markets' || lower == '$w bets');
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
