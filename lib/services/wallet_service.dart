import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

import '../coin/coins.dart';
import '../src/rust/api/wallet.dart' as rust_wallet;
import '../src/rust/api/engine_api.dart' as rust_engine;
import '../src/rust/frb_generated.dart';
import 'wallet_registry.dart';
import 'secure_key_store.dart';
import 'market_venue.dart' show polymarketGammaMarketPassesQuality;

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
    // Store seed for both networks so the wallet is available after toggling.
    await SecureKeyStore.storeSeedForWallet(profile.id, seed);
    await SecureKeyStore.storeSeedForWallet('${profile.id}_testnet', seed);
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
    // Store seed for both networks so the wallet is available after toggling.
    await SecureKeyStore.storeSeedForWallet(profile.id, seedPhrase);
    await SecureKeyStore.storeSeedForWallet('${profile.id}_testnet', seedPhrase);
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
  /// If the target wallet doesn't exist on the current network (e.g. testnet),
  /// a fresh wallet is auto-created with an independent seed.
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

      final exists = await walletExists(walletId: targetWalletId);
      if (exists) {
        final hasSeed = await hasSeedForCurrentNetwork(targetWalletId);
        if (!hasSeed) {
          _log.w('[WS] wallet DB exists but seed missing from keychain — '
              'opening as-is (may be watch-only)');
        }
      } else {
        final hasSeed = await hasSeedForCurrentNetwork(targetWalletId);
        if (hasSeed) {
          _log.i('[WS] seed found but no DB — restoring wallet...');
          final seed = await SecureKeyStore.getSeedForWallet(
              _networkSeedKey(targetWalletId));
          if (seed != null) {
            final dir = await walletDir(walletId: targetWalletId);
            final dbKey = await _getDbCipherKey();
            await rust_engine.engineRestoreFromSeed(
              dataDir: dir,
              serverUrl: serverUrl,
              chainType: _chainType,
              seedPhrase: seed,
              birthday: 0,
              dbCipherKey: dbKey,
            );
            await rust_engine.engineCloseWallet();
          }
        } else {
          _log.i('[WS] no wallet or seed — creating fresh wallet');
          await createNetworkWalletForProfile(targetWalletId);
        }
      }

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

  /// Create a fresh wallet for the current network (e.g. testnet) under an
  /// existing WalletProfile.  Uses a brand-new seed so that testnet keys are
  /// completely independent of mainnet — preventing accidental seed leakage.
  Future<void> createNetworkWalletForProfile(String walletId) async {
    final dir = await walletDir(walletId: walletId);
    int height = 0;
    try {
      height = await getLatestBlockHeight();
    } catch (e) {
      _log.w('[WS] failed to get chain height for network wallet, using 0: $e');
    }
    _log.i('[WS] creating fresh network wallet for $walletId in $dir at height $height');
    final dbKey = await _getDbCipherKey();
    final seed = await rust_engine.engineCreateWallet(
      dataDir: dir,
      serverUrl: serverUrl,
      chainType: _chainType,
      chainHeight: height,
      dbCipherKey: dbKey,
    );
    await SecureKeyStore.storeSeedForWallet(_networkSeedKey(walletId), seed);
    await rust_engine.engineCloseWallet();
    _log.i('[WS] network wallet created (independent seed), ready for openWalletById');
  }

  /// Returns the SecureKeyStore key for the active network's seed.
  /// Mainnet uses the wallet UUID directly; testnet appends '_testnet'
  /// so the two seeds are never confused.
  String _networkSeedKey(String walletId) =>
      isTestnet ? '${walletId}_testnet' : walletId;

  /// Whether a seed exists in SecureKeyStore for [walletId] on the current network.
  Future<bool> hasSeedForCurrentNetwork(String walletId) =>
      SecureKeyStore.hasSeedForWallet(_networkSeedKey(walletId));

  /// Delete a wallet's on-disk data for the current network without touching
  /// the engine state. Used to clean up seedless testnet wallets.
  Future<void> deleteWalletDir({required String walletId}) async {
    final dir = await walletDir(walletId: walletId);
    final d = Directory(dir);
    if (await d.exists()) {
      await d.delete(recursive: true);
      _log.i('[WS] deleted wallet dir: $dir');
    }
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

  Future<void> startSync() async {
    _checkBusy();
    if (useNewEngine) {
      await rust_engine.engineStartSync();
      return;
    }
    await rust_wallet.startSync();
  }

  Future<void> stopSync() async {
    if (useNewEngine) {
      await rust_engine.engineStopSync();
      return;
    }
    await rust_wallet.stopSync();
  }

  /// Trigger a full rescan from the wallet's birthday height.
  /// Stops sync, truncates the DB, and restarts.
  Future<void> rescanFromBirthday() async {
    _checkBusy();
    if (useNewEngine) {
      await rust_engine.engineRescanFromBirthday();
      return;
    }
    await rust_wallet.rescanWallet();
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

  /// Like [getBalance] but returns an all-zero balance (instead of throwing)
  /// when the engine has no wallet summary yet (fresh wallet open / mid-init).
  ///
  /// Use this in wallet/account-switch flows where "balance not ready" is a
  /// normal startup state — the next sync poll will fill in the real value.
  /// **Do not** use this in the polling balance refresh; there we want the
  /// thrown error so [ActiveAccount2.updateBalance] preserves the previous
  /// (last known good) balance instead of overwriting with zero.
  Future<rust_wallet.WalletBalance> getBalanceOrZero() async {
    try {
      return await getBalance();
    } catch (e) {
      _log.w('[WalletService] getBalance failed during init, '
          'falling back to zero: $e');
      return rust_wallet.WalletBalance.default_();
    }
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
        final status = etx.expiredUnmined
            ? 'expired'
            : etx.height > 0
                ? 'confirmed'
                : 'pending';
        return rust_wallet.TransactionRecord(
          txid: etx.txid,
          height: etx.height,
          timestamp: BigInt.from(etx.timestamp),
          value: etx.value,
          kind: etx.kind,
          fee: etx.fee,
          status: status,
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
    final key = _networkSeedKey(_activeWalletId!);
    final seed = await SecureKeyStore.getSeedForWallet(key);
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
      return SecureKeyStore.getSeedForWallet(_networkSeedKey(_activeWalletId!));
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

  // -----------------------------------------------------------------------
  // Prediction Markets (Myriad API — direct HTTP until engine FFI is ready)
  // -----------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> searchMarkets(String? keyword) async {
    final uri = Uri.parse(
      'https://api-v2.myriadprotocol.com/markets'
      '?network_id=56&limit=20&state=open'
      '${keyword != null && keyword.isNotEmpty ? '&keyword=${Uri.encodeComponent(keyword)}' : ''}',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) return [];

    final body = json.decode(utf8.decode(response.bodyBytes));
    final List<dynamic> data = body is Map ? (body['data'] ?? []) : (body is List ? body : []);
    return data.map((m) => m as Map<String, dynamic>).toList();
  }

  /// Polymarket open positions for a Polygon `0x…` address (Data API via Rust engine).
  Future<List<Map<String, dynamic>>> getPolymarketPortfolio(String polygonAddress) async {
    try {
      final jsonStr =
          await rust_engine.enginePolymarketGetPositions(address: polygonAddress);
      final decoded = json.decode(jsonStr);
      if (decoded is! List) return [];
      return decoded.map<Map<String, dynamic>>((e) {
        final raw = e as Map<String, dynamic>;
        return <String, dynamic>{
          '_provider': 'polymarket',
          'market_title': raw['title'],
          'title': raw['title'],
          'outcome': raw['outcome'],
          'outcome_title': raw['outcome'],
          'shares': (raw['size'] as num?)?.toDouble() ?? 0.0,
          'current_price': (raw['curPrice'] as num?)?.toDouble() ?? 0.0,
          'cur_price': raw['curPrice'],
          'condition_id': raw['conditionId'],
          'conditionId': raw['conditionId'],
          'asset': raw['asset'],
          'negative_risk': raw['negativeRisk'],
          'negativeRisk': raw['negativeRisk'],
          'cash_pnl': raw['cashPnl'],
          'percent_pnl': raw['percentPnl'],
          'current_value': raw['currentValue'],
          'avg_price': raw['avgPrice'],
          'market_id': 0,
        };
      }).toList();
    } catch (e, st) {
      _log.e('[Polymarket] portfolio failed: $e\n$st');
      return [];
    }
  }

  /// Fetch the user's open prediction market positions.
  Future<List<Map<String, dynamic>>> getPortfolio(String bscAddress) async {
    final uri = Uri.parse(
      'https://api-v2.myriadprotocol.com/users/$bscAddress/portfolio?network_id=56&min_shares=0&limit=100',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) return [];

    final body = json.decode(utf8.decode(response.bodyBytes));
    final List<dynamic> data = body is Map ? (body['data'] ?? []) : (body is List ? body : []);
    return data.map((m) => m as Map<String, dynamic>).toList();
  }

  /// Fetch a single market's details including all outcomes.
  Future<Map<String, dynamic>?> getMarketDetails(int marketId) async {
    final uri = Uri.parse(
      'https://api-v2.myriadprotocol.com/markets/$marketId?network_id=56',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) return null;

    final body = json.decode(utf8.decode(response.bodyBytes));
    if (body is Map<String, dynamic>) {
      // API may wrap in {"data": ...} or return directly
      return (body.containsKey('data') && body['data'] is Map)
          ? body['data'] as Map<String, dynamic>
          : body;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Polymarket — Gamma API (public, unauthenticated)
  // -------------------------------------------------------------------------

  static const _gammaApi = 'https://gamma-api.polymarket.com';

  static double _gammaF64(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  /// Polymarket discovery rows (same grouping/quality as CLI `polymarket list`).
  ///
  /// Returns `PolymarketListRow`-shaped maps: `kind`, `title`, `market_count`,
  /// `volume_24hr`, `neg_risk`, `top_runners` (each runner: `label`, `price`,
  /// `volume_24hr`, `condition_id`).
  Future<List<Map<String, dynamic>>> polymarketDiscoveryRows({
    String? keyword,
    int limit = 20,
  }) async {
    try {
      final jsonStr = await rust_engine.enginePolymarketDiscover(
        keyword: keyword,
        limit: limit,
      );
      final decoded = json.decode(jsonStr) as Map<String, dynamic>;
      final rows = decoded['rows'];
      if (rows is! List) return [];
      _log.i('[Polymarket] Discovery ${decoded['events_fetched']} events → ${rows.length} rows');
      return rows
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      _log.e('[Polymarket] discovery failed: $e\n$st');
      return [];
    }
  }

  /// Normalize a Polymarket market/event to unified format.
  Map<String, dynamic> _normalizePolymarket(Map<String, dynamic> m) {
    final conditionId = m['condition_id'] ?? m['conditionId'] ?? '';
    final question = m['question'] ?? m['title'] ?? '';
    final outcomePricesRaw = m['outcomePrices'] ?? m['outcome_prices'];
    final outcomePrices = outcomePricesRaw is String ? outcomePricesRaw : (outcomePricesRaw != null ? json.encode(outcomePricesRaw) : '[]');
    final outcomeLabelsRaw = m['outcomes'];
    final outcomeLabels = outcomeLabelsRaw is String ? outcomeLabelsRaw : (outcomeLabelsRaw != null ? json.encode(outcomeLabelsRaw) : '["Yes","No"]');
    final tokenIdsRaw = m['clobTokenIds'] ?? m['clob_token_ids'];
    final tokenIds = tokenIdsRaw is String ? tokenIdsRaw : (tokenIdsRaw != null ? json.encode(tokenIdsRaw) : '[]');
    final negRiskRaw = m['neg_risk'] ?? m['negRisk'];
    final negRisk = negRiskRaw is bool ? negRiskRaw : (negRiskRaw?.toString() == 'true');

    List<dynamic> prices = [];
    List<dynamic> labels = [];
    List<dynamic> tokens = [];
    try { prices = json.decode(outcomePrices) as List; } catch (_) {}
    try { labels = json.decode(outcomeLabels) as List; } catch (_) {}
    try { tokens = json.decode(tokenIds) as List; } catch (_) {}

    final outcomes = <Map<String, dynamic>>[];
    for (var i = 0; i < labels.length; i++) {
      outcomes.add({
        'title': labels[i]?.toString() ?? 'Outcome $i',
        'price': i < prices.length
            ? (double.tryParse(prices[i].toString()) ?? 0)
            : 0.0,
        'outcome_id': i,
        'token_id': i < tokens.length ? tokens[i].toString() : '',
      });
    }

    final volumeRaw = m['volume'];
    final volume = volumeRaw is num ? volumeRaw.toDouble() : (double.tryParse(volumeRaw?.toString() ?? '') ?? 0);
    final volume24 = _gammaF64(m['volume24hr'] ?? m['volume24Hr']);
    final acceptingOrders = m['acceptingOrders'] == true || m['accepting_orders'] == true;
    final bestBid = m['bestBid'] ?? m['best_bid'];
    final bestAsk = m['bestAsk'] ?? m['best_ask'];
    final spread = m['spread'];
    final groupTitle = m['groupItemTitle'] ?? m['group_item_title'];

    return {
      'id': conditionId,
      'conditionId': conditionId,
      'condition_id': conditionId,
      'title': question,
      'state': 'open',
      'outcomes': outcomes,
      'volume': volume,
      'volume24hr': volume24,
      'accepting_orders': acceptingOrders,
      'best_bid': bestBid is num ? bestBid : double.tryParse(bestBid?.toString() ?? ''),
      'best_ask': bestAsk is num ? bestAsk : double.tryParse(bestAsk?.toString() ?? ''),
      'spread': spread is num ? spread : double.tryParse(spread?.toString() ?? ''),
      'group_item_title': groupTitle?.toString(),
      'neg_risk': negRisk,
      '_provider': 'polymarket',
      '_condition_id': conditionId,
    };
  }

  /// Search Polymarket markets directly by text query.
  Future<List<Map<String, dynamic>>> searchPolymarketMarkets(String query) async {
    final uri = Uri.parse('$_gammaApi/markets').replace(queryParameters: {
      'active': 'true',
      'closed': 'false',
      'limit': '20',
      'order': 'volume24hr',
      'ascending': 'false',
      if (query.isNotEmpty) 'tag_slug': query,
    });
    _log.d('[Polymarket] GET $uri');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      _log.e('[Polymarket] Markets API returned ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
      return [];
    }

    final body = json.decode(utf8.decode(response.bodyBytes));
    if (body is List) {
      final normalized = <Map<String, dynamic>>[];
      for (final e in body) {
        final mm = e as Map<String, dynamic>;
        if (await polymarketGammaMarketPassesQuality(mm)) {
          normalized.add(_normalizePolymarket(mm));
        }
      }
      _log.i('[Polymarket] Markets returned ${normalized.length} results (quality-filtered)');
      return normalized;
    }
    return [];
  }

  /// Fetch a single Polymarket event by slug or ID.
  Future<Map<String, dynamic>?> getPolymarketEvent(String slug) async {
    final uri = Uri.parse('$_gammaApi/events/$slug');
    final response = await http.get(uri);
    if (response.statusCode != 200) return null;

    final body = json.decode(utf8.decode(response.bodyBytes));
    if (body is Map<String, dynamic>) return body;
    return null;
  }

  /// Fetch a single Polymarket market by condition_id (Gamma `condition_ids` query).
  Future<Map<String, dynamic>?> getPolymarketMarket(String conditionId) async {
    var hex = conditionId.trim();
    if (!hex.startsWith('0x')) hex = '0x$hex';
    final uri = Uri.parse('$_gammaApi/markets').replace(queryParameters: {'condition_ids': hex});
    _log.d('[Polymarket] GET $uri');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      _log.e('[Polymarket] getPolymarketMarket HTTP ${response.statusCode}');
      return null;
    }

    final body = json.decode(utf8.decode(response.bodyBytes));
    if (body is! List || body.isEmpty) return null;
    final first = body.first;
    if (first is! Map<String, dynamic>) return null;
    return _normalizePolymarket(first);
  }
}
