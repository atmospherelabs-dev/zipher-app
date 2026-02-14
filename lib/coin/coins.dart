import 'coin.dart';
import 'zcash.dart';
import 'zcashtest.dart';

CoinBase zcash = ZcashCoin();
CoinBase zcashtest = ZcashTestCoin();

final coins = [zcash];

final activationDate = DateTime(2018, 10, 29);
