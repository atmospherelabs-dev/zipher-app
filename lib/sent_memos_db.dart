import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' hide getDatabasesPath;

import 'pages/utils.dart';

/// Dart-managed SQLite database for app-level data that the Rust
/// backend (`warp_api`) does not track — primarily outgoing memos.
///
/// Lives in a separate `zipher_app.db` file alongside the Rust-managed
/// `zec.db`, so there is zero risk of schema conflicts.
class SentMemosDb {
  static Database? _db;
  static const _dbName = 'zipher_app.db';
  static const _version = 2;

  /// Open (or create) the database. Safe to call multiple times.
  static Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = null;
    final dbPath = await getDbPath();
    _db = await openDatabase(
      p.join(dbPath, _dbName),
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sent_memos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        coin INTEGER NOT NULL,
        account_id INTEGER NOT NULL,
        tx_hash TEXT NOT NULL,
        memo TEXT NOT NULL,
        recipient TEXT NOT NULL DEFAULT '',
        timestamp_ms INTEGER NOT NULL,
        anonymous INTEGER NOT NULL DEFAULT 0,
        UNIQUE(tx_hash, coin, account_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_sent_memos_account ON sent_memos(coin, account_id)',
    );
    await db.execute(
      'CREATE INDEX idx_sent_memos_tx ON sent_memos(tx_hash)',
    );
  }

  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE sent_memos ADD COLUMN anonymous INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  // ─── CRUD ───────────────────────────────────────────────

  /// Insert a sent memo after broadcast.
  static Future<void> insert({
    required int coin,
    required int accountId,
    required String txHash,
    required String memo,
    required String recipient,
    required int timestampMs,
    bool anonymous = false,
  }) async {
    final db = await database;
    await db.insert(
      'sent_memos',
      {
        'coin': coin,
        'account_id': accountId,
        'tx_hash': txHash,
        'memo': memo,
        'recipient': recipient,
        'timestamp_ms': timestampMs,
        'anonymous': anonymous ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get the memo string for a specific transaction hash.
  static Future<String?> getMemo(String txHash) async {
    final db = await database;
    final rows = await db.query(
      'sent_memos',
      columns: ['memo'],
      where: 'tx_hash = ?',
      whereArgs: [txHash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['memo'] as String?;
  }

  /// Get all sent memos for a specific account (for the Messages page).
  static Future<Map<String, CachedOutgoingMemo>> getAllForAccount(
    int coin,
    int accountId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'sent_memos',
      where: 'coin = ? AND account_id = ?',
      whereArgs: [coin, accountId],
      orderBy: 'timestamp_ms ASC',
    );
    final map = <String, CachedOutgoingMemo>{};
    for (final row in rows) {
      final txHash = row['tx_hash'] as String;
      map[txHash] = CachedOutgoingMemo(
        memo: row['memo'] as String? ?? '',
        recipient: row['recipient'] as String? ?? '',
        timestampMs: row['timestamp_ms'] as int? ?? 0,
        anonymous: (row['anonymous'] as int? ?? 0) != 0,
      );
    }
    return map;
  }

  /// Migrate existing SharedPreferences data into the DB (one-time).
  static Future<void> migrateFromSharedPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys =
          prefs.getKeys().where((k) => k.startsWith('outgoing_memos_v')).toList();
      if (keys.isEmpty) return;

      for (final key in keys) {
        // Parse coin and accountId from key: outgoing_memos_v3_{coin}_{accountId}
        final parts = key.split('_');
        if (parts.length < 5) continue;
        final coin = int.tryParse(parts[3]);
        final accountId = int.tryParse(parts[4]);
        if (coin == null || accountId == null) continue;

        final raw = prefs.getString(key);
        if (raw == null) continue;

        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              final txHash = entry.key.toString();
              String memo;
              String recipient;
              int timestampMs;

              if (entry.value is Map<String, dynamic>) {
                final j = entry.value as Map<String, dynamic>;
                memo = j['memo'] as String? ?? '';
                recipient = j['recipient'] as String? ?? '';
                timestampMs = j['ts'] as int? ?? 0;
              } else {
                memo = entry.value.toString();
                recipient = '';
                timestampMs = 0;
              }

              if (memo.isNotEmpty) {
                await insert(
                  coin: coin,
                  accountId: accountId,
                  txHash: txHash,
                  memo: memo,
                  recipient: recipient,
                  timestampMs: timestampMs,
                );
              }
            }
          }
          // Remove the old key after successful migration
          await prefs.remove(key);
        } catch (_) {}
      }
    } catch (_) {}
  }
}
