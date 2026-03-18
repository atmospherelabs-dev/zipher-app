import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

import '../coin/coins.dart';
import '../src/rust/api/wallet.dart' as rust_wallet;
import '../src/rust/api/engine_api.dart' as rust_engine;
import '../src/rust/frb_generated.dart';
import 'wallet_registry.dart';
import 'secure_key_store.dart';

final _log = Logger();

class WalletBusyException implements Exception {
  @override
  String toString() => 'Wallet is busy (switching). Try again shortly.';
}

/// Singleton service bridging the Dart UI to the Zcash wallet engine
/// (zcash_client_backend + zcash_client_sqlite) via flutter_rust_bridge.
class WalletService {
  WalletService._();
  static final instance = WalletService._();

  /// Toggle for the zcash_client_sqlite engine (always true, legacy stubs remain for FRB compat).
  static const bool useNewEngine = true;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  bool _walletOpen = false;
  bool get isWalletOpen => _walletOpen;

  bool _busy = false;
  bool get isBusy => _busy;

  String? _activeWalletId;
  String? get activeWalletId => _activeWalletId;

  void _checkBusy() {
    if (_busy) throw WalletBusyException();
  }

  // -----------------------------------------------------------------------
  // Init
  // -----------------------------------------------------------------------

  /// Call once at app startup, before any other Rust call.
  Future<void> initRustLib() async {
    if (_initialized) return;
    await RustLib.init();
    await _ensureSaplingParams();
    _initialized = true;
  }

  /// Copy Sapling proving parameters from Flutter assets to the Documents
  /// directory so the Rust prover can find them on the filesystem.
  Future<void> _ensureSaplingParams() async {
    final appDir = await getApplicationDocumentsDirectory();
    for (final name in ['sapling-spend.params', 'sapling-output.params']) {
      final file = File('${appDir.path}/$name');
      if (!file.existsSync()) {
        _log.i('[WS] copying $name to ${appDir.path}');
        final data = await rootBundle.load('assets/$name');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    }
  }

  /// Data directory for a specific wallet.
  Future<String> walletDir({String? walletId, bool? testnet}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final suffix = (testnet ?? isTestnet) ? '_testnet' : '';
    final id = walletId ?? _activeWalletId;
    final dirName = id != null ? 'zipher_wallet_$id$suffix' : 'zipher_wallet$suffix';
    final dir = Directory('${appDir.path}/$dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// First server URL from the active coin's LWD list.
  String get serverUrl {
    final servers = activeCoin.lwd;
    return servers.isNotEmpty ? servers.first.url : 'https://zec.rocks:443';
  }

  /// Lazily-generated per-coin DB encryption key stored in platform keychain.
  Future<String> _getDbCipherKey() async {
    return SecureKeyStore.getOrCreateDbKey(activeCoin.coin);
  }

  rust_wallet.ChainType get _chainType =>
      isTestnet ? rust_wallet.ChainType.testnet : rust_wallet.ChainType.mainnet;

  /// Check if a wallet file exists on disk for a specific wallet ID.
  Future<bool> walletExists({String? walletId}) async {
    final dir = await walletDir(walletId: walletId);
    if (useNewEngine) {
      final dbFile = File('$dir/zipher-data.sqlite');
      return dbFile.existsSync();
    }
    final walletFile = File('$dir/zingo-wallet.dat');
    return walletFile.existsSync();
  }

  // -----------------------------------------------------------------------
  // Multi-wallet lifecycle
  // -----------------------------------------------------------------------

  /// Fetch the latest block height from the server (no wallet needed).
  Future<int> getLatestBlockHeight() async {
    if (useNewEngine) {
      return rust_engine.engineGetLatestBlockHeight(serverUrl: serverUrl);
    }
    return rust_wallet.getLatestBlockHeight(
      serverUrl: serverUrl,
      chainType: _chainType,
    );
  }

  /// Create a brand-new wallet. Returns the seed phrase.
  /// Creates a WalletProfile in the registry and stores the seed securely.
  Future<String> createNewWallet(String name) async {
    _checkBusy();
    _log.i('[WS] createNewWallet "$name" server=$serverUrl');
    final registry = WalletRegistry.instance;
    final profile = await registry.create(name);
    _log.i('[WS] profile created id=${profile.id}');

    int chainHeight = 0;
    try {
      _log.i('[WS] fetching latest block height...');
      chainHeight = await getLatestBlockHeight();
      _log.i('[WS] chain height = $chainHeight');
    } catch (e) {
      _log.w('[WS] failed to get chain height, using 0: $e');
    }

    final dir = await walletDir(walletId: profile.id);
    _log.i('[WS] creating wallet in $dir at height $chainHeight');
    final String seed;
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      seed = await rust_engine.engineCreateWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        chainHeight: chainHeight,
        dbCipherKey: dbKey,
      );
    } else {
      seed = await rust_wallet.createWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        chainHeight: chainHeight,
      );
    }
    _log.i('[WS] wallet created, seed obtained');

    _walletOpen = true;
    _activeWalletId = profile.id;
    await registry.setActive(profile.id);
    await SecureKeyStore.storeSeedForWallet(profile.id, seed);
    await _applyFileProtection(dir);
    if (!useNewEngine) await rust_wallet.startSaveTask();
    _log.i('[WS] createNewWallet complete');
    return seed;
  }

  /// Restore a wallet from a seed phrase.
  /// Creates a WalletProfile and stores the seed securely.
  Future<void> restoreWallet(
      String name, String seedPhrase, int birthday) async {
    _checkBusy();
    _log.i('[WS] restoreWallet "$name" birthday=$birthday server=$serverUrl');
    final registry = WalletRegistry.instance;
    final profile = await registry.create(name);
    _log.i('[WS] profile created id=${profile.id}');

    final dir = await walletDir(walletId: profile.id);
    _log.i('[WS] restoring from seed in $dir ...');
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      await rust_engine.engineRestoreFromSeed(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        seedPhrase: seedPhrase,
        birthday: birthday,
        dbCipherKey: dbKey,
      );
    } else {
      await rust_wallet.restoreFromSeed(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        seedPhrase: seedPhrase,
        birthday: birthday,
      );
    }
    _log.i('[WS] restoreFromSeed completed');

    _walletOpen = true;
    _activeWalletId = profile.id;
    await registry.setActive(profile.id);
    await SecureKeyStore.storeSeedForWallet(profile.id, seedPhrase);
    await _applyFileProtection(dir);
    if (!useNewEngine) await rust_wallet.startSaveTask();
    _log.i('[WS] restoreWallet complete');
  }

  /// Restore from a unified full viewing key (watch-only).
  Future<void> restoreWalletFromUfvk(
      String name, String ufvk, int birthday) async {
    _checkBusy();
    final registry = WalletRegistry.instance;
    final profile = await registry.create(name, watchOnly: true);

    final dir = await walletDir(walletId: profile.id);
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      await rust_engine.engineRestoreFromUfvk(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        ufvk: ufvk,
        birthday: birthday,
        dbCipherKey: dbKey,
      );
    } else {
      await rust_wallet.restoreFromUfvk(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        ufvk: ufvk,
        birthday: birthday,
      );
    }

    _walletOpen = true;
    _activeWalletId = profile.id;
    await registry.setActive(profile.id);
    await _applyFileProtection(dir);
    if (!useNewEngine) await rust_wallet.startSaveTask();
  }

  /// Open an existing wallet by profile ID.
  Future<void> openWalletById(String walletId) async {
    _checkBusy();
    await _openWalletByIdInternal(walletId);
  }

  Future<void> _openWalletByIdInternal(String walletId) async {
    final dir = await walletDir(walletId: walletId);
    _log.i('[WS] openWalletById $walletId dir=$dir server=$serverUrl');
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      await rust_engine.engineOpenWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        dbCipherKey: dbKey,
      );
      await _registerInactiveWallets(walletId);
    } else {
      await rust_wallet.openWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
      );
    }
    _walletOpen = true;
    _activeWalletId = walletId;
    await WalletRegistry.instance.setActive(walletId);
    if (!useNewEngine) await rust_wallet.startSaveTask();
    _log.i('[WS] openWalletById complete');
  }

  /// Switch from the current wallet to another.
  /// Handles the full close-save-open lifecycle with busy locking.
  Future<void> switchWallet(String targetWalletId) async {
    _log.i('[WS] switchWallet from=$_activeWalletId to=$targetWalletId');
    if (_activeWalletId == targetWalletId && _walletOpen) return;
    _busy = true;
    try {
      if (_walletOpen) {
        _log.i('[WS] closing current wallet...');
        await _snapshotAndClose();
        _log.i('[WS] current wallet closed');
      }

      await Future.delayed(const Duration(milliseconds: 100));

      await _openWalletByIdInternal(targetWalletId);
      _log.i('[WS] switchWallet complete');
    } finally {
      _busy = false;
    }
  }

  /// Delete a wallet: close if active, remove files, remove from registry.
  Future<void> deleteWalletById(String walletId) async {
    _checkBusy();
    if (_activeWalletId == walletId && _walletOpen) {
      await closeWallet();
    }

    // Remove wallet files
    final mainDir = await walletDir(walletId: walletId, testnet: false);
    final testDir = await walletDir(walletId: walletId, testnet: true);
    await _deleteDirectory(mainDir);
    await _deleteDirectory(testDir);

    // Remove seed from secure storage
    await SecureKeyStore.deleteSeedForWallet(walletId);

    // Remove from registry
    await WalletRegistry.instance.delete(walletId);

    if (_activeWalletId == walletId) {
      _activeWalletId = null;
      _walletOpen = false;
    }
  }

  Future<void> _deleteDirectory(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Snapshot current balance into registry and close.
  Future<void> _snapshotAndClose() async {
    if (_activeWalletId != null && _walletOpen) {
      _log.i('[WS] _snapshotAndClose activeId=$_activeWalletId');

      try {
        final balance = useNewEngine
            ? await rust_engine.engineGetWalletBalance()
            : await rust_wallet.getWalletBalance();
        final confirmed = balance.transparent.toInt() +
            balance.sapling.toInt() +
            balance.orchard.toInt();
        await WalletRegistry.instance.updateSnapshot(
          _activeWalletId!,
          balance: confirmed,
        );
      } catch (e) {
        _log.w('[WS] snapshot failed (sync may be running): $e');
      }

      await closeWallet();
    }
  }

  /// Snapshot balance after sync (call this after sync completion).
  Future<void> snapshotAfterSync() async {
    if (_activeWalletId == null || !_walletOpen) return;
    try {
      final balance = useNewEngine
          ? await rust_engine.engineGetWalletBalance()
          : await rust_wallet.getWalletBalance();
      final confirmed = balance.transparent.toInt() +
          balance.sapling.toInt() +
          balance.orchard.toInt();
      await WalletRegistry.instance.updateSnapshot(
        _activeWalletId!,
        balance: confirmed,
      );
    } catch (_) {}
  }

  // -----------------------------------------------------------------------
  // Legacy wallet lifecycle (kept for migration & backward compat)
  // -----------------------------------------------------------------------

  /// Legacy: create wallet without registry (used during migration).
  Future<String> createWallet({int? chainHeight}) async {
    _checkBusy();
    final dir = await walletDir();
    final height = chainHeight ?? 0;
    final String seed;
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      seed = await rust_engine.engineCreateWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        chainHeight: height,
        dbCipherKey: dbKey,
      );
    } else {
      seed = await rust_wallet.createWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        chainHeight: height,
      );
    }
    _walletOpen = true;
    await _applyFileProtection(dir);
    if (!useNewEngine) await rust_wallet.startSaveTask();
    return seed;
  }

  /// Legacy: restore from seed without registry.
  Future<void> restoreFromSeed(String seedPhrase, int birthday) async {
    _checkBusy();
    final dir = await walletDir();
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      await rust_engine.engineRestoreFromSeed(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        seedPhrase: seedPhrase,
        birthday: birthday,
        dbCipherKey: dbKey,
      );
    } else {
      await rust_wallet.restoreFromSeed(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        seedPhrase: seedPhrase,
        birthday: birthday,
      );
    }
    _walletOpen = true;
    await _applyFileProtection(dir);
    if (!useNewEngine) await rust_wallet.startSaveTask();
  }

  /// Legacy: restore from UFVK without registry.
  Future<void> restoreFromUfvk(String ufvk, int birthday) async {
    _checkBusy();
    final dir = await walletDir();
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      await rust_engine.engineRestoreFromUfvk(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        ufvk: ufvk,
        birthday: birthday,
        dbCipherKey: dbKey,
      );
    } else {
      await rust_wallet.restoreFromUfvk(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        ufvk: ufvk,
        birthday: birthday,
      );
    }
    _walletOpen = true;
    await _applyFileProtection(dir);
    if (!useNewEngine) await rust_wallet.startSaveTask();
  }

  /// Legacy: open wallet without specifying ID.
  Future<void> openWallet() async {
    _checkBusy();
    final dir = await walletDir();
    if (useNewEngine) {
      final dbKey = await _getDbCipherKey();
      await rust_engine.engineOpenWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
        dbCipherKey: dbKey,
      );
    } else {
      await rust_wallet.openWallet(
        dataDir: dir,
        serverUrl: serverUrl,
        chainType: _chainType,
      );
    }
    _walletOpen = true;
    if (!useNewEngine) await rust_wallet.startSaveTask();
  }

  Future<void> closeWallet() async {
    final closingId = _activeWalletId;
    _log.i('[WS] closeWallet (activeId=$closingId)');
    final sw = Stopwatch()..start();
    try {
      if (useNewEngine) {
        await rust_engine.engineCloseWallet();
      } else {
        await rust_wallet.closeWallet();
      }
    } catch (e) {
      _log.w('[WS] closeWallet error (proceeding anyway): $e');
    }
    sw.stop();
    _walletOpen = false;
    _log.i('[WS] closeWallet done in ${sw.elapsedMilliseconds}ms');
  }

  /// Delete wallet data from disk. Must call closeWallet() first.
  Future<void> deleteWallet() async {
    final dir = await walletDir();
    if (useNewEngine) {
      await rust_engine.engineDeleteWalletData(dataDir: dir);
    } else {
      await rust_wallet.deleteWalletData(dataDir: dir);
    }
  }

  // -----------------------------------------------------------------------
  // iOS Data Protection
  // -----------------------------------------------------------------------

  Future<void> _applyFileProtection(String dirPath) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    try {
      await Process.run('xattr', [
        '-w',
        'com.apple.metadata:com_apple_backup_excludeItem',
        'com.apple.MobileBackup',
        dirPath,
      ]);
    } catch (_) {}
  }

  // -----------------------------------------------------------------------
  // Background sync — register inactive wallets
  // -----------------------------------------------------------------------

  /// Register all wallets except [activeId] so the Rust sync engine
  /// can sync them in the background after the active wallet catches up.
  Future<void> _registerInactiveWallets(String activeId) async {
    try {
      await rust_engine.engineClearInactiveWallets();
      final profiles = await WalletRegistry.instance.getAll();
      for (final p in profiles) {
        if (p.id == activeId) continue;
        final dir = await walletDir(walletId: p.id);
        await rust_engine.engineRegisterInactiveWallet(dataDir: dir);
      }
    } catch (e) {
      _log.w('[WS] failed to register inactive wallets: $e');
    }
  }

  // -----------------------------------------------------------------------
  // Sync
  // -----------------------------------------------------------------------

  Future<rust_wallet.SyncResultInfo> syncAndAwait() async {
    _checkBusy();
    if (useNewEngine) {
      await rust_engine.engineStartSync();
      int lastHeight = 0;
      while (true) {
        await Future.delayed(const Duration(seconds: 2));
        final p = await rust_engine.engineGetSyncProgress();
        lastHeight = p.syncedHeight;
        if (!p.isSyncing) break;
      }
      await snapshotAfterSync();
      return rust_wallet.SyncResultInfo(
        startHeight: 0,
        endHeight: lastHeight,
        blocksScanned: lastHeight,
      );
    }
    final result = await rust_wallet.syncWallet();
    await snapshotAfterSync();
    return result;
  }

  Future<void> startSync() async {
    _checkBusy();
    if (useNewEngine) {
      await rust_engine.engineStartSync();
      return;
    }
    await rust_wallet.startSync();
  }

  Future<void> pauseSync() async {
    _checkBusy();
    if (useNewEngine) return;
    await rust_wallet.pauseSync();
  }

  Future<void> resumeSync() async {
    _checkBusy();
    if (useNewEngine) return;
    await rust_wallet.resumeSync();
  }

  Future<void> stopSync() async {
    if (useNewEngine) {
      await rust_engine.engineStopSync();
      return;
    }
    await rust_wallet.stopSync();
  }

  Future<rust_wallet.SyncResultInfo> rescan() async {
    _checkBusy();
    if (useNewEngine) {
      await rust_engine.engineStartSync();
      int lastHeight = 0;
      while (true) {
        await Future.delayed(const Duration(seconds: 2));
        final p = await rust_engine.engineGetSyncProgress();
        lastHeight = p.syncedHeight;
        if (!p.isSyncing) break;
      }
      await snapshotAfterSync();
      return rust_wallet.SyncResultInfo(
        startHeight: 0,
        endHeight: lastHeight,
        blocksScanned: lastHeight,
      );
    }
    final result = await rust_wallet.rescanWallet();
    await snapshotAfterSync();
    return result;
  }

  Future<rust_wallet.SyncStatusInfo> getSyncStatus() async {
    if (useNewEngine) {
      final p = await rust_engine.engineGetSyncProgress();
      final mode = p.isSyncing ? 'syncing' : 'idle';
      return rust_wallet.SyncStatusInfo(mode: mode);
    }
    return rust_wallet.getSyncStatus();
  }

  /// New engine sync progress (richer type, available regardless of toggle).
  Future<rust_engine.EngineSyncProgress> getEngineSyncProgress() async {
    return rust_engine.engineGetSyncProgress();
  }

  // -----------------------------------------------------------------------
  // Balance
  // -----------------------------------------------------------------------

  Future<rust_wallet.WalletBalance> getBalance() async {
    _checkBusy();
    if (useNewEngine) {
      return rust_engine.engineGetWalletBalance();
    }
    return rust_wallet.getWalletBalance();
  }

  // -----------------------------------------------------------------------
  // Addresses
  // -----------------------------------------------------------------------

  Future<List<rust_wallet.AddressInfo>> getAddresses() async {
    _checkBusy();
    if (useNewEngine) {
      return rust_engine.engineGetAddresses();
    }
    return rust_wallet.getAddresses();
  }

  Future<List<String>> getTransparentAddresses() async {
    _checkBusy();
    if (useNewEngine) {
      return rust_engine.engineGetTransparentAddresses();
    }
    return rust_wallet.getTransparentAddresses();
  }

  // -----------------------------------------------------------------------
  // Transactions
  // -----------------------------------------------------------------------

  Future<List<rust_wallet.TransactionRecord>> getTransactions() async {
    _checkBusy();
    if (useNewEngine) {
      final engineTxs = await rust_engine.engineGetTransactions();
      return engineTxs.map((etx) {
        final v = etx.value.toInt();
        return rust_wallet.TransactionRecord(
          txid: etx.txid,
          height: etx.height,
          timestamp: BigInt.from(etx.timestamp),
          value: etx.value,
          kind: etx.kind,
          fee: etx.fee,
          status: etx.height > 0 ? 'confirmed' : 'pending',
          rawValue: BigInt.from(v < 0 ? -v : v),
        );
      }).toList();
    }
    return rust_wallet.getTransactions();
  }

  Future<List<rust_wallet.ValueTransferRecord>> getValueTransfers() async {
    _checkBusy();
    return rust_wallet.getValueTransfers();
  }

  Future<List<rust_wallet.ValueTransferRecord>> getMessages({
    String? filter,
  }) async {
    _checkBusy();
    return rust_wallet.getMessages(filter: filter);
  }

  Future<List<rust_wallet.TransactionRecord>> getPendingTransactions() async {
    _checkBusy();
    final all = await getTransactions();
    return all
        .where((tx) =>
            tx.status == 'mempool' ||
            tx.status == 'transmitted' ||
            tx.status == 'calculated')
        .toList();
  }

  // -----------------------------------------------------------------------
  // Send
  // -----------------------------------------------------------------------

  /// Ask the proposal engine for the exact maximum sendable amount to [address],
  /// accounting for the real ZIP-317 fee instead of guessing.
  Future<int> getMaxSendable(String address) async {
    final result = await rust_engine.engineGetMaxSendable(address: address);
    return result.toInt();
  }

  /// Step 1: Create a proposal and return exact fee info.
  /// When [isMax] is true, [amount] is ignored and the SDK computes the max.
  Future<({int sendAmount, int fee, bool isExact})> proposeSend(
    String address,
    int amount, {
    String? memo,
    bool isMax = false,
  }) async {
    final result = await rust_engine.engineProposeSend(
      address: address,
      amount: BigInt.from(amount),
      memo: memo,
      isMax: isMax,
    );
    return (
      sendAmount: result.sendAmount.toInt(),
      fee: result.fee.toInt(),
      isExact: result.isExact,
    );
  }

  /// Step 2: Confirm and broadcast the previously proposed transaction.
  Future<String> confirmSend() async {
    final seed = await _getSeedForSend();
    return rust_engine.engineConfirmSend(seedPhrase: seed);
  }

  Future<String> send(List<rust_wallet.PaymentRecipient> recipients) async {
    _checkBusy();
    if (useNewEngine) {
      final r = recipients.first;
      final seed = await _getSeedForSend();
      return rust_engine.engineSendPayment(
        seedPhrase: seed,
        address: r.address,
        amount: r.amount,
        memo: r.memo,
      );
    }
    return rust_wallet.sendPayment(recipients: recipients);
  }

  Future<String> sendFromAccount(
    int accountIndex,
    List<rust_wallet.PaymentRecipient> recipients,
  ) async {
    _checkBusy();
    return rust_wallet.sendFromAccount(
      accountIndex: accountIndex,
      recipients: recipients,
    );
  }

  Future<String> shieldFunds() async {
    _checkBusy();
    if (useNewEngine) {
      final seed = await _getSeedForSend();
      return rust_engine.engineShieldFunds(seedPhrase: seed);
    }
    return rust_wallet.shieldFunds();
  }

  Future<String> _getSeedForSend() async {
    if (_activeWalletId == null) throw Exception('No active wallet');
    final seed = await SecureKeyStore.getSeedForWallet(_activeWalletId!);
    if (seed == null) throw Exception('Seed not found in secure storage');
    return seed;
  }

  Future<String> shieldAccount(int accountIndex) async {
    _checkBusy();
    return rust_wallet.shieldAccount(accountIndex: accountIndex);
  }

  // -----------------------------------------------------------------------
  // Multi-account (within a single wallet)
  // -----------------------------------------------------------------------

  Future<int> createAccount() async {
    _checkBusy();
    return rust_wallet.createAccount();
  }

  Future<int> getAccountCount() async {
    _checkBusy();
    return rust_wallet.getAccountCount();
  }

  Future<rust_wallet.WalletBalance> getAccountBalance(int accountIndex) async {
    _checkBusy();
    return rust_wallet.getAccountBalance(accountIndex: accountIndex);
  }

  // -----------------------------------------------------------------------
  // Diversified addresses
  // -----------------------------------------------------------------------

  Future<String> generateDiversifiedAddress({
    int accountIndex = 0,
    bool includeOrchard = true,
    bool includeSapling = true,
  }) async {
    _checkBusy();
    return rust_wallet.generateDiversifiedAddress(
      accountIndex: accountIndex,
      includeOrchard: includeOrchard,
      includeSapling: includeSapling,
    );
  }

  // -----------------------------------------------------------------------
  // Payment URI (ZIP-321)
  // -----------------------------------------------------------------------

  Future<List<rust_wallet.PaymentRecipient>> parsePaymentUri(String uri) async {
    _checkBusy();
    return rust_wallet.parsePaymentUri(uri: uri);
  }

  Future<String> buildPaymentUri(
    String address,
    int amount, {
    String? memo,
  }) async {
    _checkBusy();
    return rust_wallet.buildPaymentUri(
      address: address,
      amount: BigInt.from(amount),
      memo: memo,
    );
  }

  // -----------------------------------------------------------------------
  // Validation
  // -----------------------------------------------------------------------

  Future<rust_wallet.AddressValidation> validateAddress(String address) async {
    if (useNewEngine) {
      return rust_engine.engineValidateAddress(address: address);
    }
    return rust_wallet.validateAddress(address: address);
  }

  Future<bool> validateSeed(String seed) async {
    if (useNewEngine) {
      return rust_engine.engineValidateSeed(seed: seed);
    }
    return rust_wallet.validateSeed(seed: seed);
  }

  // -----------------------------------------------------------------------
  // Backup / Export
  // -----------------------------------------------------------------------

  Future<String?> getSeedPhrase() async {
    _checkBusy();
    if (useNewEngine) {
      if (_activeWalletId == null) return null;
      return SecureKeyStore.getSeedForWallet(_activeWalletId!);
    }
    return rust_wallet.getSeedPhrase();
  }

  Future<int> getBirthday() async {
    _checkBusy();
    if (useNewEngine) {
      return rust_engine.engineGetBirthday();
    }
    return rust_wallet.getBirthday();
  }

  Future<int> getWalletSyncedHeight() async {
    _checkBusy();
    if (useNewEngine) {
      return rust_engine.engineGetWalletSyncedHeight();
    }
    return rust_wallet.getWalletSyncedHeight();
  }

  Future<String?> exportUfvk() async {
    _checkBusy();
    if (useNewEngine) {
      return rust_engine.engineExportUfvk();
    }
    return rust_wallet.exportUfvk();
  }

  Future<bool> hasSpendingKey() async {
    _checkBusy();
    if (useNewEngine) {
      return rust_engine.engineHasSpendingKey();
    }
    return rust_wallet.hasSpendingKey();
  }

  // -----------------------------------------------------------------------
  // Server
  // -----------------------------------------------------------------------

  Future<void> setServer(String url) async {
    _checkBusy();
    await rust_wallet.setServer(serverUrl: url);
  }

  Future<String> getServerInfo() async {
    _checkBusy();
    return rust_wallet.getServerInfo();
  }
}
