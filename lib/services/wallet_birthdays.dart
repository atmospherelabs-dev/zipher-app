import 'package:shared_preferences/shared_preferences.dart';

/// The scan start height of each wallet, per network, kept outside the
/// wallet database.
///
/// When a database is lost (deleted after a failed open, or missing when the
/// seed is still in the keychain), the wallet is rebuilt from its seed. That
/// rebuild used to start at the current chain tip, so every earlier payment
/// was missing from the balance. A stored birthday lets the rebuild start
/// where the wallet did; without one, birthday 0 makes the engine scan from
/// the network's Sapling activation, which is slow but finds everything.
///
/// Keys are the network-scoped seed keys (`<walletId>` on mainnet,
/// `<walletId>_testnet` on testnet), so the two networks never share a value.
class WalletBirthdays {
  static String _key(String seedKey) => 'wallet_birthday_$seedKey';

  static Future<void> remember(String seedKey, int height) async {
    if (height <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key(seedKey), height);
  }

  /// Height to rebuild from: the remembered birthday, else 0 (full history).
  static Future<int> forRestore(String seedKey) async {
    final prefs = await SharedPreferences.getInstance();
    final height = prefs.getInt(_key(seedKey));
    return height != null && height > 0 ? height : 0;
  }

  static Future<void> forget(String seedKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(seedKey));
  }
}
