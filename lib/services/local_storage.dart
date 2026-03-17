import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class Contact {
  final String id;
  final String name;
  final String address;

  Contact({required this.id, required this.name, required this.address});

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'address': address};

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
      );
}

class ContactStore {
  ContactStore._();
  static final ContactStore instance = ContactStore._();

  static const _prefix = 'zipher_contacts_';
  static const _listKey = '${_prefix}list';

  Future<void> save(Contact contact) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _loadIds(prefs);
    if (!list.contains(contact.id)) list.add(contact.id);
    await prefs.setString(_listKey, jsonEncode(list));
    await prefs.setString('$_prefix${contact.id}', jsonEncode(contact.toJson()));
  }

  Future<List<Contact>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _loadIds(prefs);
    final contacts = <Contact>[];
    for (final id in list) {
      final raw = prefs.getString('$_prefix$id');
      if (raw != null) {
        try {
          contacts.add(Contact.fromJson(jsonDecode(raw) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    return contacts;
  }

  Future<Contact?> get(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$id');
    if (raw == null) return null;
    try {
      return Contact.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _loadIds(prefs);
    list.remove(id);
    await prefs.setString(_listKey, jsonEncode(list));
    await prefs.remove('$_prefix$id');
  }

  Future<List<String>> _loadIds(SharedPreferences prefs) async {
    final raw = prefs.getString(_listKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      return List<String>.from(decoded as List);
    } catch (_) {
      return [];
    }
  }
}

class MessageReadStore {
  MessageReadStore._();
  static final MessageReadStore instance = MessageReadStore._();

  static const _key = 'zipher_read_txids';

  Future<void> markRead(String txid) async {
    final prefs = await SharedPreferences.getInstance();
    final set = await _loadSet(prefs);
    set.add(txid);
    await prefs.setStringList(_key, set.toList());
  }

  Future<void> markAllRead() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<bool> isRead(String txid) async {
    final prefs = await SharedPreferences.getInstance();
    final set = await _loadSet(prefs);
    return set.contains(txid);
  }

  Future<int> getUnreadCount(List<String> txids) async {
    final prefs = await SharedPreferences.getInstance();
    final set = await _loadSet(prefs);
    return txids.where((id) => !set.contains(id)).length;
  }

  Future<Set<String>> _loadSet(SharedPreferences prefs) async {
    final list = prefs.getStringList(_key);
    return list != null ? list.toSet() : <String>{};
  }
}

class SwapRecord {
  final String id;
  final String fromCurrency;
  final String toCurrency;
  final double fromAmount;
  final double toAmount;
  final String status;
  final DateTime timestamp;
  final String? txid;

  SwapRecord({
    required this.id,
    required this.fromCurrency,
    required this.toCurrency,
    required this.fromAmount,
    required this.toAmount,
    required this.status,
    required this.timestamp,
    this.txid,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromCurrency': fromCurrency,
        'toCurrency': toCurrency,
        'fromAmount': fromAmount,
        'toAmount': toAmount,
        'status': status,
        'timestamp': timestamp.toIso8601String(),
        if (txid != null) 'txid': txid,
      };

  factory SwapRecord.fromJson(Map<String, dynamic> json) => SwapRecord(
        id: json['id'] as String,
        fromCurrency: json['fromCurrency'] as String,
        toCurrency: json['toCurrency'] as String,
        fromAmount: (json['fromAmount'] as num).toDouble(),
        toAmount: (json['toAmount'] as num).toDouble(),
        status: json['status'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        txid: json['txid'] as String?,
      );
}

class SwapHistoryStore {
  SwapHistoryStore._();
  static final SwapHistoryStore instance = SwapHistoryStore._();

  static const _key = 'zipher_swap_history';

  Future<void> save(SwapRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _loadList(prefs);
    final idx = list.indexWhere((r) => r.id == record.id);
    if (idx >= 0) {
      list[idx] = record;
    } else {
      list.add(record);
    }
    await _saveList(prefs, list);
  }

  Future<List<SwapRecord>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadList(prefs);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<List<SwapRecord>> _loadList(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => SwapRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveList(SharedPreferences prefs, List<SwapRecord> list) async {
    await prefs.setString(
        _key, jsonEncode(list.map((r) => r.toJson()).toList()));
  }
}

class SendTemplate {
  final String id;
  final String name;
  final String address;
  final int amount;
  final String? memo;

  SendTemplate({
    required this.id,
    required this.name,
    required this.address,
    required this.amount,
    this.memo,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'amount': amount,
        if (memo != null) 'memo': memo,
      };

  factory SendTemplate.fromJson(Map<String, dynamic> json) => SendTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
        amount: json['amount'] as int,
        memo: json['memo'] as String?,
      );
}

class SendTemplateStore {
  SendTemplateStore._();
  static final SendTemplateStore instance = SendTemplateStore._();

  static const _prefix = 'zipher_send_template_';
  static const _listKey = '${_prefix}list';

  Future<void> save(SendTemplate template) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _loadIds(prefs);
    if (!list.contains(template.id)) list.add(template.id);
    await prefs.setString(_listKey, jsonEncode(list));
    await prefs.setString(
        '$_prefix${template.id}', jsonEncode(template.toJson()));
  }

  Future<List<SendTemplate>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _loadIds(prefs);
    final templates = <SendTemplate>[];
    for (final id in list) {
      final raw = prefs.getString('$_prefix$id');
      if (raw != null) {
        try {
          templates.add(SendTemplate.fromJson(
              jsonDecode(raw) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    return templates;
  }

  Future<void> delete(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _loadIds(prefs);
    list.remove(id);
    await prefs.setString(_listKey, jsonEncode(list));
    await prefs.remove('$_prefix$id');
  }

  Future<List<String>> _loadIds(SharedPreferences prefs) async {
    final raw = prefs.getString(_listKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      return List<String>.from(decoded as List);
    } catch (_) {
      return [];
    }
  }
}
