import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/utils.dart' show Contact;
import 'package:zipher/services/contact_store.dart';

void main() {
  test(
      'concurrent additions persist with distinct IDs and edits replace one contact',
      () async {
    String? disk;
    ContactStore open() => ContactStore(
        read: () async => disk, write: (value) async => disk = value);
    final store = open();
    await Future.wait([
      store.add(Contact(id: 0, name: 'Alice', address: 'test-address-a')),
      store.add(Contact(id: 0, name: 'Bob', address: 'test-address-b')),
    ]);
    expect(store.contacts.map((c) => c.id), [1, 2]);
    await store
        .add(Contact(id: 1, name: 'Alice updated', address: 'test-address-c'));
    final reopened = open();
    await reopened.fetchContacts();
    expect(reopened.contacts.map((c) => c.name), ['Alice updated', 'Bob']);
    await reopened.remove(reopened.contacts.first);
    final afterDelete = open();
    await afterDelete.fetchContacts();
    expect(afterDelete.contacts.single.name, 'Bob');
  });

  test('same address retains different chains after reopening', () async {
    String? disk;
    ContactStore open() => ContactStore(
        read: () async => disk, write: (value) async => disk = value);
    final store = open();
    const address = '0x1111111111111111111111111111111111111111';
    await store
        .add(Contact(id: 0, name: 'Alice', address: address, chainId: 'eth'));
    await store
        .add(Contact(id: 0, name: 'Alice', address: address, chainId: 'base'));
    final restored = open();
    await restored.fetchContacts();
    expect(restored.contacts.map((c) => c.chainId), ['eth', 'base']);
  });

  test('failed writes preserve the saved list and later retries can succeed',
      () async {
    var fail = true;
    final store = ContactStore(
        read: () async => null,
        write: (_) async {
          if (fail) throw StateError('disposable write failure');
        });
    await expectLater(
        store.add(Contact(id: 0, name: 'Alice')), throwsStateError);
    expect(store.contacts, isEmpty);
    fail = false;
    await store.add(Contact(id: 0, name: 'Alice'));
    expect(store.contacts.single.id, 1);
  });

  test('unreadable stored contacts are not silently overwritten', () async {
    var writes = 0;
    final store = ContactStore(
        read: () async => 'invalid json',
        write: (_) async {
          writes++;
        });
    await store.fetchContacts();
    expect(store.loadError.value, isNotNull);
    await expectLater(
        store.add(Contact(id: 0, name: 'Alice')), throwsFormatException);
    expect(writes, 0);
  });
}
