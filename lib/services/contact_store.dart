import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobx/mobx.dart';

import '../pages/utils.dart' show Contact;

/// App address book. Persist first so a failed write cannot look like a save.
class ContactStore {
  static const _key = 'zipher_contacts_v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final contacts = ObservableList<Contact>();
  final loadError = Observable<String?>(null);
  Future<void> _tail = Future.value();
  bool _loaded = false;

  ContactStore(
      {Future<String?> Function()? read, Future<void> Function(String)? write})
      : _read = read ?? (() => _storage.read(key: _key)),
        _write = write ?? ((value) => _storage.write(key: _key, value: value));

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final raw = await _read();
    final entries = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
    final loaded = entries
        .map((entry) => Contact(
              id: entry['id'] as int,
              name: entry['name'] as String?,
              address: entry['address'] as String?,
            ))
        .toList();
    if (loaded.any((c) => c.id <= 0) ||
        loaded.map((c) => c.id).toSet().length != loaded.length) {
      throw const FormatException('Invalid contact identifiers');
    }
    runInAction(() {
      contacts
        ..clear()
        ..addAll(loaded);
      loadError.value = null;
    });
    _loaded = true;
  }

  Future<void> fetchContacts() => _enqueue(_load).catchError((Object _) {
        runInAction(() => loadError.value =
            'Contacts could not be loaded. Reopen this page to retry.');
      });

  Future<void> _persist(List<Contact> next) async {
    await _write(jsonEncode(next
        .map((c) => {'id': c.id, 'name': c.name, 'address': c.address})
        .toList()));
    runInAction(() {
      contacts
        ..clear()
        ..addAll(next);
    });
  }

  Future<void> add(Contact contact) => _enqueue(() async {
        await _load();
        final id = contact.id == 0
            ? contacts.fold<int>(
                    0, (highest, c) => c.id > highest ? c.id : highest) +
                1
            : contact.id;
        if (id < 1) throw ArgumentError('Invalid contact identifier');
        final next = contacts.toList();
        final index = next.indexWhere((c) => c.id == id);
        final saved =
            Contact(id: id, name: contact.name, address: contact.address);
        if (index == -1) {
          next.add(saved);
        } else {
          next[index] = saved;
        }
        await _persist(next);
      });

  Future<void> remove(Contact contact) => _enqueue(() async {
        await _load();
        await _persist(contacts.where((c) => c.id != contact.id).toList());
      });
}
