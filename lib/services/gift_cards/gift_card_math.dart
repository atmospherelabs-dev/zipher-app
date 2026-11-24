/// Exact money arithmetic for gift-card orders.
///
/// ZEC amounts are integer zatoshis and fiat amounts are integer minor units
/// (cents). Doubles never enter accounting: provider strings are parsed
/// digit by digit, and display-only ratios are computed last.
library;

const int zatoshisPerZec = 100000000;

/// Parses a non-negative decimal string into base units with [decimals]
/// fraction digits. Extra precision rounds **up** so a parsed payment amount
/// is never less than what the provider asked for.
///
/// Returns null for anything that is not a plain decimal (no signs, no
/// exponents, no grouping).
int? parseDecimalUnits(String input, int decimals, {bool roundUp = true}) {
  final text = input.trim();
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final whole = parts[0];
  var fraction = parts.length == 2 ? parts[1] : '';
  var bump = false;
  if (fraction.length > decimals) {
    final dropped = fraction.substring(decimals);
    fraction = fraction.substring(0, decimals);
    bump = roundUp && dropped.contains(RegExp('[1-9]'));
  }
  final digits = '$whole${fraction.padRight(decimals, '0')}'
      .replaceFirst(RegExp(r'^0+(?=\d)'), '');
  // 2^63 has 19 digits; refuse anything that could overflow.
  if (digits.length > 18) return null;
  final value = int.parse(digits);
  return bump ? value + 1 : value;
}

/// "0.12345678" → 12345678. See [parseDecimalUnits].
int? parseZatoshis(String zec) => parseDecimalUnits(zec, 8);

/// Formats base units with [decimals] digits, trimming trailing zeros unless
/// [fixed] is set (fiat is shown with all its digits: "25.00").
String formatUnits(int units, int decimals, {bool fixed = false}) {
  final negative = units < 0;
  final value = units.abs();
  if (decimals == 0) return '${negative ? '-' : ''}$value';
  final scale = _pow10(decimals);
  var fraction = (value % scale).toString().padLeft(decimals, '0');
  if (!fixed) fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  final whole = value ~/ scale;
  return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
}

String formatZatoshis(int zatoshis) => formatUnits(zatoshis, 8);

int _pow10(int n) {
  var v = 1;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

/// Minor units per major unit for common ISO-4217 codes.
int currencyDecimals(String currency) =>
    const {'JPY': 0, 'KRW': 0, 'VND': 0, 'CLP': 0, 'ISK': 0, 'HUF': 0}[
        currency.toUpperCase()] ??
    2;

/// Fiat face value of a card, in minor units of [currency].
class Fiat {
  const Fiat(this.minor, this.currency);
  final int minor;
  final String currency;

  int get decimals => currencyDecimals(currency);

  static Fiat? parse(String amount, String currency) {
    final minor = parseDecimalUnits(amount, currencyDecimals(currency),
        roundUp: false);
    return minor == null ? null : Fiat(minor, currency.toUpperCase());
  }

  /// "25.00 USD"
  @override
  String toString() =>
      '${formatUnits(minor, decimals, fixed: true)} $currency';

  @override
  bool operator ==(Object other) =>
      other is Fiat && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);
}

/// Which face values a card can be bought at.
sealed class Denominations {
  const Denominations();

  /// Why [minor] cannot be bought, or null when it can.
  String? reject(int minor);

  /// Values to offer as one-tap chips.
  List<int> suggestions();
}

class FixedDenominations extends Denominations {
  FixedDenominations(List<int> values)
      : values = List.unmodifiable(values.toSet().toList()..sort());
  final List<int> values;

  @override
  String? reject(int minor) =>
      values.contains(minor) ? null : 'Choose one of the listed amounts.';

  @override
  List<int> suggestions() => values;
}

class RangeDenominations extends Denominations {
  const RangeDenominations(
      {required this.min, required this.max, this.step = 1})
      : assert(min > 0 && max >= min && step > 0);
  final int min;
  final int max;
  final int step;

  @override
  String? reject(int minor) {
    if (minor < min) return 'The minimum for this card is lower than that.';
    if (minor > max) return 'That is more than this card allows.';
    if ((minor - min) % step != 0) {
      return 'This card is sold in fixed steps.';
    }
    return null;
  }

  @override
  List<int> suggestions() {
    // Round values a person would pick: about five spread across the range.
    final out = <int>{min};
    for (final major in const [10, 25, 50, 100, 200, 500]) {
      for (final d in const [1, 100]) {
        final v = major * d;
        if (reject(v) == null) out.add(v);
      }
    }
    out.add(max);
    final sorted = out.toList()..sort();
    return sorted.length <= 6 ? sorted : [...sorted.take(5), max];
  }
}

/// What a payment costs, all integers. [priceZatoshis] is what the provider
/// asks for the card (its fees and discount already applied); the network
/// fee is the wallet's exact proposal fee.
class GiftCardCost {
  const GiftCardCost({
    required this.faceValue,
    required this.priceZatoshis,
    required this.networkFeeZatoshis,
  })  : assert(priceZatoshis > 0),
        assert(networkFeeZatoshis >= 0);

  final Fiat faceValue;
  final int priceZatoshis;
  final int networkFeeZatoshis;

  int get totalZatoshis => priceZatoshis + networkFeeZatoshis;

  /// Provider markup over the market rate in basis points: positive is a fee,
  /// negative a discount. [fiatMinorPerZec] is the market price of one ZEC in
  /// the card's currency minor units. Display only; null without a rate.
  int? markupBps(int? fiatMinorPerZec) {
    if (fiatMinorPerZec == null || fiatMinorPerZec <= 0) return null;
    if (faceValue.minor <= 0) return null;
    // market value of the ZEC paid, in fiat minor units × 1e8
    final paidScaled = BigInt.from(priceZatoshis) * BigInt.from(fiatMinorPerZec);
    final faceScaled = BigInt.from(faceValue.minor) * BigInt.from(zatoshisPerZec);
    final diff = paidScaled - faceScaled;
    // Round half away from zero.
    final num = diff * BigInt.from(10000);
    final q = num ~/ faceScaled;
    final r = (num.remainder(faceScaled)).abs() * BigInt.two;
    final adjust = r >= faceScaled ? (num.isNegative ? -1 : 1) : 0;
    return q.toInt() + adjust;
  }
}

/// Zatoshis needed to buy [fiatMinor] at [fiatMinorPerZec], rounded up.
/// For an estimate before the provider's exact invoice exists.
int estimateZatoshis(int fiatMinor, int fiatMinorPerZec) {
  if (fiatMinor <= 0 || fiatMinorPerZec <= 0) {
    throw ArgumentError('Amounts must be positive');
  }
  final n = BigInt.from(fiatMinor) * BigInt.from(zatoshisPerZec);
  final d = BigInt.from(fiatMinorPerZec);
  return ((n + d - BigInt.one) ~/ d).toInt();
}

/// "+2.5%" / "−3%" / "0%" from basis points.
String formatBps(int bps) {
  if (bps == 0) return '0%';
  final sign = bps > 0 ? '+' : '−';
  final text = formatUnits(bps.abs(), 2);
  return '$sign$text%';
}
