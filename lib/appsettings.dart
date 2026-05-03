import 'dart:convert';
import 'dart:math' as m;

import 'package:shared_preferences/shared_preferences.dart';

import 'settings.pb.dart';
import 'coin/coins.dart';

var appSettings = AppSettings();
var coinSettings = CoinSettings();

extension AppSettingsExtension on AppSettings {
  void defaults() {
    if (!hasConfirmations()) confirmations = 3;
    if (!hasRowsPerPage()) rowsPerPage = 10;
    if (!hasDeveloperMode()) developerMode = 5;
    if (!hasCurrency()) currency = 'USD';
    if (!hasAutoHide()) autoHide = 1;
    if (!hasPalette()) {
      palette = ColorPalette(
        name: 'mandyRed',
        dark: true,
      );
    }
    // memo is initialized later because we don't have S yet
    if (!hasNoteView()) noteView = 2;
    if (!hasTxView()) txView = 2;
    if (!hasMessageView()) messageView = 2;
    if (!hasCustomSendSettings())
      customSendSettings = CustomSendSettings()..defaults();
    if (!hasBackgroundSync()) backgroundSync = 1;
    if (!hasLanguage()) language = 'en';
  }

  static AppSettings load(SharedPreferences prefs) {
    final setting = prefs.getString('settings') ?? '';
    final settingBytes = base64Decode(setting);
    return AppSettings.fromBuffer(settingBytes)..defaults();
  }

  Future<void> save(SharedPreferences prefs) async {
    final bytes = this.writeToBuffer();
    final settings = base64Encode(bytes);
    await prefs.setString('settings', settings);
  }

  int chartRangeDays() => 365;
  int get anchorOffset => m.max(confirmations, 1) - 1;
}

extension CoinSettingsExtension on CoinSettings {
  void defaults(int coin) {
    int defaultUAType = coins[coin].defaultUAType;
    if (!hasUaType()) uaType = defaultUAType;
    if (!hasReplyUa()) replyUa = defaultUAType;
    if (!hasSpamFilter()) spamFilter = true;
    if (!hasReceipientPools()) receipientPools = 7;
  }

  static CoinSettings load(int coin) {
    // Synchronous load not available - use loadAsync or defaults
    return CoinSettings()..defaults(coin);
  }

  static Future<CoinSettings> loadAsync(int coin) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('coin_settings_$coin') ?? '';
    if (stored.isEmpty) {
      return CoinSettings()..defaults(coin);
    }
    final settings = CoinSettings.fromBuffer(base64Decode(stored));
    return settings..defaults(coin);
  }

  void save(int coin) {
    // Persists via SharedPreferences - fire and forget
    final bytes = writeToBuffer();
    final settings = base64Encode(bytes);
    SharedPreferences.getInstance().then((prefs) =>
        prefs.setString('coin_settings_$coin', settings));
  }

  FeeT get feeT => FeeT(scheme: manualFee ? 1 : 0, fee: fee.toInt());

  String resolveBlockExplorer(int coin) {
    final explorers = coins[coin].blockExplorers;
    int idx = explorer.index;
    if (idx >= 0) return explorers[idx];
    return explorer.customURL;
  }
}

/// Local fee type (replaces warp_api FeeT).
class FeeT {
  final int scheme;
  final int fee;
  FeeT({required this.scheme, required this.fee});
}

/// Resolve the lightwalletd URL from the user's saved coin settings.
/// Returns the built-in server URL if a valid index is set, otherwise
/// the custom URL entered by the user.
String resolveURL(CoinBase c, CoinSettings settings) {
  if (settings.lwd.index >= 0 && settings.lwd.index < c.lwd.length) {
    return c.lwd[settings.lwd.index].url;
  }
  return settings.lwd.customURL;
}

extension CustomSendSettingsExtension on CustomSendSettings {
  void defaults() {
    contacts = true;
    accounts = true;
    pools = true;
    recipientPools = true;
    amountCurrency = true;
    amountSlider = true;
    max = true;
    deductFee = true;
    replyAddress = true;
    memoSubject = true;
    memo = true;
  }
}
