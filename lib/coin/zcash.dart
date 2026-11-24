import 'package:flutter/material.dart';

import 'coin.dart';

class ZcashCoin extends CoinBase {
  int coin = 0;
  String name = "Zcash";
  String app = "Zipher";
  String symbol = "\u24E9";
  String currency = "zcash";
  int coinIndex = 133;
  String ticker = "ZEC";
  String dbName = "zec.db";
  String? marketTicker = "ZECUSDT";
  AssetImage image = AssetImage('assets/zcash.png');
  List<LWInstance> lwd = [
    LWInstance("Zec.rocks (Global)", "https://zec.rocks:443"),
    // Zcash Labs' ztreamer network: answers from a local index per region.
    LWInstance("Fastz.cash (Global)", "https://rpc.fastz.cash:443"),
    LWInstance("ZecBlock (Mainnet)", "https://lightwalletd.mainnet.cipherscan.app:443"),
    LWInstance("Zec.rocks (NA)", "https://na.zec.rocks:443"),
    LWInstance("Zec.rocks (SA)", "https://sa.zec.rocks:443"),
    LWInstance("Zec.rocks (EU)", "https://eu.zec.rocks:443"),
    LWInstance("Zec.rocks (AP)", "https://ap.zec.rocks:443"),
    LWInstance("Fastz.cash (NA)", "https://na.fastz.cash:443"),
    LWInstance("Fastz.cash (SA)", "https://sa.fastz.cash:443"),
    LWInstance("Fastz.cash (EU)", "https://eu.fastz.cash:443"),
    LWInstance("Fastz.cash (AP)", "https://ap.fastz.cash:443"),
  ];
  int defaultAddrMode = 0;
  int defaultUAType = 7; // TSO
  bool supportsUA = true;
  bool supportsMultisig = false;
  bool supportsLedger = true;
  List<double> weights = [0.05, 0.25, 2.50];
  List<String> blockExplorers = [
    "https://zecblock.com/tx",
    "https://blockchair.com/zcash/transaction",
    "https://zecblockexplorer.com/tx"
  ];
}
