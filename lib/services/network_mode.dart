import 'package:shared_preferences/shared_preferences.dart';

import '../appsettings.dart';
import '../coin/coins.dart';
import '../store2.dart';

/// Switches the app between mainnet and testnet.
///
/// Everything that belongs to one network is replaced here, in one place:
/// the persisted flag, [isTestnet], the per-network coin settings (server
/// choice, custom server URL, fee and address preferences) and the fiat
/// price. Without this, the previous network's server selection was used to
/// open the new network's wallet, and the mainnet ZEC price was shown next
/// to testnet TAZ.
///
/// [reinitCoins] re-points the coin database paths; callers pass `initCoins`.
Future<void> applyNetworkMode(bool testnet,
    {required Future<void> Function() reinitCoins}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('testnet', testnet);
  isTestnet = testnet;
  testnetNotifier.value = testnet;
  // A price fetched for the other network never describes this one.
  marketPrice.clear();
  coinSettings = await CoinSettingsExtension.loadAsync(activeCoin.coin);
  await reinitCoins();
}
