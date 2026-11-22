import 'package:intl/intl.dart';

/// Display formatting for token amounts. Never used for accounting: exact
/// integers stay with the wallet engine and the provider quote.
abstract final class WalletAmounts {
  /// Base-unit [amount] as a decimal, truncated (never rounded up, so a
  /// displayed minimum is never more than the guaranteed one) and grouped.
  static String token(BigInt amount, int decimals, {int? fractionDigits}) {
    final negative = amount.isNegative;
    final value = amount.abs();
    final scale = BigInt.from(10).pow(decimals);
    final whole = value ~/ scale;
    final keep = (fractionDigits ?? _digitsFor(whole)).clamp(0, decimals);
    var fraction = decimals == 0
        ? ''
        : (value % scale).toString().padLeft(decimals, '0').substring(0, keep);
    fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
    final grouped = whole
        .toString()
        .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final text = fraction.isEmpty ? grouped : '$grouped.$fraction';
    // A positive amount must not read as zero after truncation.
    if (value > BigInt.zero && whole == BigInt.zero && fraction.isEmpty) {
      return '${negative ? '-' : ''}<${keep == 0 ? '1' : '0.${'0' * (keep - 1)}1'}';
    }
    return negative ? '-$text' : text;
  }

  static int _digitsFor(BigInt whole) => whole >= BigInt.from(1000)
      ? 2
      : whole >= BigInt.one
          ? 4
          : 8;

  /// "1 ZEC ≈ 790.55 USDC". An indication only.
  static String? rate(
      {required int zatoshis,
      required BigInt amountOut,
      required int decimals,
      required String symbol}) {
    if (zatoshis <= 0 || amountOut <= BigInt.zero) return null;
    // Output base units for exactly one ZEC, in integers.
    final perZec = amountOut * BigInt.from(100000000) ~/ BigInt.from(zatoshis);
    return '1 ZEC ≈ ${token(perZec, decimals)} $symbol';
  }

  static String dollars(double amount) => amount < 0.01 && amount > 0
      ? '<\$0.01'
      : NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(amount);

  /// "about 2 min", "about 45 sec".
  static String duration(Duration d) => d.inSeconds < 90
      ? 'about ${d.inSeconds < 60 ? d.inSeconds : 60} sec'
      : d.inMinutes < 90
          ? 'about ${d.inMinutes} min'
          : 'about ${(d.inMinutes / 60).round()} h';

  /// Middle-truncated address for one line; the full value stays available.
  static String shortAddress(String address, {int head = 8, int tail = 8}) =>
      address.length <= head + tail + 1
          ? address
          : '${address.substring(0, head)}…${address.substring(address.length - tail)}';
}
