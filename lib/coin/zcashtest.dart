import 'package:flutter/material.dart';

import 'coin.dart';

class ZcashTestCoin extends CoinBase {
  int coin = 1; // Rust COIN_CONFIG slot 1 = ZcashTest (Network::TestNetwork)
  String name = "Zcash Testnet";
  String app = "Zipher";
  String symbol = "\u24E9";
  String currency = "zcash-test";
  int coinIndex = 133;
  String ticker = "TAZ";
  String dbName = "zec-test.db";
  String? marketTicker = null; // No market data for testnet
  AssetImage image = AssetImage('assets/zcash.png');
  List<LWInstance> lwd = [
    LWInstance("Zec.rocks Testnet (NU6.3)", "https://testnet.zec.rocks:443"),
    LWInstance("CipherScan Testnet", "https://lightwalletd.testnet.cipherscan.app:443"),
  ];
  int defaultAddrMode = 0;
  int defaultUAType = 7; // TSO
  bool supportsUA = true;
  bool supportsMultisig = false;
  bool supportsLedger = false;
  List<double> weights = [0.05, 0.25, 2.50];
  List<String> blockExplorers = ["https://testnet.cipherscan.app/tx"];
}
