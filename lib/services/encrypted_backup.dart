import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'wallet_service.dart';

const _version = 1;
const _magic = 'ZBAK';
const _pbkdf2Iterations = 100000;
const _keyLength = 32;

class BackupPayload {
  final String? seedPhrase;
  final String? ufvk;
  final int birthday;
  final Map<int, String> accountNames;
  final String chainType;

  BackupPayload({
    this.seedPhrase,
    this.ufvk,
    required this.birthday,
    this.accountNames = const {},
    required this.chainType,
  });

  Map<String, dynamic> toJson() => {
        'version': _version,
        'magic': _magic,
        if (seedPhrase != null) 'seed': seedPhrase,
        if (ufvk != null) 'ufvk': ufvk,
        'birthday': birthday,
        'accounts': accountNames.map((k, v) => MapEntry(k.toString(), v)),
        'chain': chainType,
      };

  factory BackupPayload.fromJson(Map<String, dynamic> json) {
    final accounts = <int, String>{};
    final raw = json['accounts'] as Map<String, dynamic>? ?? {};
    raw.forEach((k, v) => accounts[int.parse(k)] = v as String);
    return BackupPayload(
      seedPhrase: json['seed'] as String?,
      ufvk: json['ufvk'] as String?,
      birthday: json['birthday'] as int,
      accountNames: accounts,
      chainType: json['chain'] as String? ?? 'mainnet',
    );
  }
}

class EncryptedBackupService {
  EncryptedBackupService._();
  static final EncryptedBackupService instance = EncryptedBackupService._();

  /// Export wallet data as an AES-256-CBC encrypted file.
  /// Returns the file path of the created .zbak file.
  Future<String> exportBackup(String password) async {
    final ws = WalletService.instance;

    final seed = await ws.getSeedPhrase();
    final ufvk = await ws.exportUfvk();
    final birthday = await ws.getBirthday();

    final payload = BackupPayload(
      seedPhrase: seed,
      ufvk: ufvk,
      birthday: birthday,
      chainType: 'mainnet',
    );

    final plaintext = jsonEncode(payload.toJson());
    final encrypted = _encrypt(plaintext, password);

    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/zipher_backup_$timestamp.zbak');
    await file.writeAsBytes(encrypted);

    return file.path;
  }

  /// Decrypt and parse a .zbak backup file.
  Future<BackupPayload> importBackup(String filePath, String password) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Backup file not found');
    }

    final bytes = await file.readAsBytes();
    final plaintext = _decrypt(bytes, password);

    final json = jsonDecode(plaintext) as Map<String, dynamic>;
    if (json['magic'] != _magic) {
      throw Exception('Invalid backup file format');
    }

    return BackupPayload.fromJson(json);
  }

  Uint8List _encrypt(String plaintext, String password) {
    final salt = enc.SecureRandom(16).bytes;
    final iv = enc.IV.fromSecureRandom(16);

    final key = _deriveKey(password, salt);
    final encrypter = enc.Encrypter(
        enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);

    // File format: ZBAK (4) | version (1) | salt (16) | iv (16) | ciphertext
    final output = BytesBuilder();
    output.add(utf8.encode(_magic));
    output.addByte(_version);
    output.add(salt);
    output.add(iv.bytes);
    output.add(encrypted.bytes);
    return output.toBytes();
  }

  String _decrypt(Uint8List data, String password) {
    if (data.length < 37) throw Exception('Invalid backup data');

    final magic = utf8.decode(data.sublist(0, 4));
    if (magic != _magic) throw Exception('Not a Zipher backup file');

    final version = data[4];
    if (version != _version) {
      throw Exception('Unsupported backup version: $version');
    }

    final salt = data.sublist(5, 21);
    final iv = enc.IV(data.sublist(21, 37));
    final ciphertext = data.sublist(37);

    final key = _deriveKey(password, Uint8List.fromList(salt));
    final encrypter = enc.Encrypter(
        enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));

    try {
      return encrypter.decrypt(enc.Encrypted(ciphertext), iv: iv);
    } catch (_) {
      throw Exception('Wrong password or corrupted backup');
    }
  }

  enc.Key _deriveKey(String password, Uint8List salt) {
    final params = pc.Pbkdf2Parameters(salt, _pbkdf2Iterations, _keyLength);
    final kdf = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
      ..init(params);
    final derived = kdf.process(Uint8List.fromList(utf8.encode(password)));
    return enc.Key(derived);
  }
}
