import 'package:flutter/foundation.dart';

import 'coin.dart';
import 'zcash.dart';
import 'zcashtest.dart';

CoinBase zcash = ZcashCoin();
CoinBase zcashtest = ZcashTestCoin();

/// Whether the app is running in testnet mode.
/// Loaded from SharedPreferences at startup, before initCoins().
bool isTestnet = false;

/// Reactive notifier so cached UI (e.g. swap tab) rebuilds on toggle.
final testnetNotifier = ValueNotifier<bool>(false);

/// Both coins indexed by their native coin id (0 = mainnet, 1 = testnet).
/// Use this for lookups like coins[aa.coin].
final coins = <CoinBase>[zcash, zcashtest];

/// The currently active coin based on network mode.
CoinBase get activeCoin => isTestnet ? zcashtest : zcash;

/// Activation date for the restore-from-seed date picker.
final activationDate = DateTime(2018, 10, 29);
