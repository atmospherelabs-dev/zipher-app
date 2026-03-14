import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appsettings.dart';
import 'main.reflectable.dart';
import 'coin/coins.dart';
import 'services/wallet_service.dart';

import 'init.dart';

const ZECUNIT = 100000000.0;
// ignore: non_constant_identifier_names
var ZECUNIT_DECIMAL = Decimal.parse('100000000');
const mZECUNIT = 100000;

final GlobalKey<NavigatorState> navigatorKey = new GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeReflectable();
  await restoreSettings();
  await WalletService.instance.initRustLib();
  await initCoins();
  initNotifications();
  runApp(App());
}

Future<void> loadTestnetPref() async {
  final prefs = await SharedPreferences.getInstance();
  isTestnet = prefs.getBool('testnet') ?? false;
  testnetNotifier.value = isTestnet;
}

Future<void> restoreSettings() async {
  final prefs = await SharedPreferences.getInstance();
  appSettings = AppSettingsExtension.load(prefs);
  await loadTestnetPref();
  coinSettings = await CoinSettingsExtension.loadAsync(activeCoin.coin);
}

final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
