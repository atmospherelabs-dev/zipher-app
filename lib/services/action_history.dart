import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A single recorded action (bet, swap, send, etc.)
class ActionRecord {
  final String id;
  final String type; // 'bet', 'swap', 'send', 'shield'
  final DateTime timestamp;
  final bool success;
  final String summary;
  final Map<String, dynamic> details;

  ActionRecord({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.success,
    required this.summary,
    this.details = const {},
  });

  factory ActionRecord.fromJson(Map<String, dynamic> json) {
    return ActionRecord(
      id: json['id'] as String,
      type: json['type'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['ts'] as int),
      success: json['ok'] as bool,
      summary: json['summary'] as String,
      details: json['details'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'ts': timestamp.millisecondsSinceEpoch,
    'ok': success,
    'summary': summary,
    'details': details,
  };
}

/// Persists cross-chain action history to SharedPreferences.
/// ZEC-only transactions live in the main tx list; this is for
/// multi-chain operations (swaps, bets, bridges).
class ActionHistory {
  ActionHistory._();
  static final instance = ActionHistory._();

  static const _key = 'action_history_v1';
  static const _maxRecords = 100;

  List<ActionRecord> _records = [];
  bool _loaded = false;

  List<ActionRecord> get records => List.unmodifiable(_records);

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    _records = raw
        .map((s) {
          try {
            return ActionRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<ActionRecord>()
        .toList();
    _records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    _loaded = true;
  }

  Future<void> add(ActionRecord record) async {
    await load();
    _records.insert(0, record);
    if (_records.length > _maxRecords) {
      _records = _records.sublist(0, _maxRecords);
    }
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = _records.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList(_key, raw);
  }

  /// Helper to create a unique ID for a new record.
  static String newId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
}
