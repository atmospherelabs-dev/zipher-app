import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:zipher/main.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:binary/binary.dart';
import 'package:collection/collection.dart';
import 'package:another_flushbar/flushbar_helper.dart';
import 'package:decimal/decimal.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reflectable/reflectable.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import 'avatar.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'dart:convert' as convert;

import '../accounts.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../router.dart';
import '../sent_memos_db.dart';
import '../store2.dart';
import '../zipher_theme.dart';
import 'widgets.dart';

var logger = Logger();

const APP_NAME = "Zipher";
const ZECUNIT = 100000000.0;
const ZECUNIT_INT = 100000000;
const MAX_PRECISION = 8;

/// Minimum amount (in zatoshis) for a message or memo-bearing transaction.
/// Ensures the recipient's wallet reliably detects the note.
const MIN_MEMO_AMOUNT = 10000; // 0.0001 ZEC

/// Max characters for message body when reply-to address is included.
/// Zcash memos are 512 bytes; ~150 bytes for 🛡MSG header + UA address.
const MAX_MESSAGE_CHARS_WITH_REPLY = 350;

/// Max characters for message body without reply-to address.
/// Nearly the full 512-byte memo minus the small 🛡MSG header (~10 bytes).
const MAX_MESSAGE_CHARS_NO_REPLY = 500;

/// Parse a raw Zcash memo that may contain the 🛡MSG header + reply-to
/// address and return just the human-readable message body.
/// Format: "🛡MSG\n{address}\n\n{body}" or "🛡MSG\n{address}\n{subject}\n{body}"
String parseMemoBody(String raw) {
  final trimmed = raw.trim();
  // Check for the MSG prefix (shield emoji + MSG)
  if (!trimmed.startsWith('\u{1F6E1}') && !trimmed.startsWith('🛡')) {
    return trimmed; // Not a MSG-formatted memo, return as-is
  }
  // Find the double-newline that separates header from body
  final idx = trimmed.indexOf('\n\n');
  if (idx >= 0) {
    return trimmed.substring(idx + 2).trim();
  }
  // Fallback: try single newline separation (subject\nbody after address)
  final lines = trimmed.split('\n');
  if (lines.length >= 3) {
    return lines.sublist(2).join('\n').trim();
  }
  return trimmed;
}

final DateFormat noteDateFormat = DateFormat("yy-MM-dd HH:mm");
final DateFormat txDateFormat = DateFormat("MM-dd HH:mm");
final DateFormat msgDateFormat = DateFormat("MM-dd HH:mm");
final DateFormat msgDateFormatFull = DateFormat("yy-MM-dd HH:mm:ss");

class Amount {
  int value;
  bool deductFee;
  Amount(this.value, this.deductFee);

  @override
  String toString() => 'Amount($value, $deductFee)';
}

int decimalDigits(bool fullPrec) => fullPrec ? MAX_PRECISION : 3;
String decimalFormat(double x, int decimalDigits, {String symbol = ''}) {
  return NumberFormat.currency(
    locale: Platform.localeName,
    decimalDigits: decimalDigits,
    symbol: symbol,
  ).format(x).trimRight();
}

String decimalToString(double x) {
  final defaultD = decimalDigits(appSettings.fullPrec);
  final abs = x.abs();
  int d = defaultD;
  if (abs > 0 && abs < 0.001) d = d.clamp(5, 8);
  else if (abs > 0 && abs < 0.01) d = d.clamp(4, 8);
  return decimalFormat(x, d);
}

Future<bool> showMessageBox2(BuildContext context, String title, String content,
    {String? label, bool dismissable = true}) async {
  final s = S.of(context);
  final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: dismissable,
      builder: (context) => Dialog(
            backgroundColor: ZipherColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: ZipherColors.borderSubtle,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: ZipherColors.cyan.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 22,
                      color: ZipherColors.cyan.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: ZipherColors.text90,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    content,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: ZipherColors.text40,
                      height: 1.4,
                    ),
                  ),
                  if (dismissable) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: GestureDetector(
                        onTap: () => GoRouter.of(context).pop(true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: ZipherColors.cyan.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              label ?? s.ok,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: ZipherColors.cyan,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ));
  return confirm ?? false;
}

mixin WithLoadingAnimation<T extends StatefulWidget> on State<T> {
  bool loading = false;

  Widget wrapWithLoading(Widget child) {
    return LoadingWrapper(loading, child: child);
  }

  Future<U> load<U>(Future<U> Function() calc) async {
    try {
      setLoading(true);
      return await calc();
    } finally {
      setLoading(false);
    }
  }

  setLoading(bool v) {
    if (mounted) setState(() => loading = v);
  }
}

Future<void> showSnackBar(String msg) async {
  final bar = FlushbarHelper.createInformation(
      message: msg, duration: Duration(seconds: 4));
  await bar.show(rootNavigatorKey.currentContext!);
}

void openTxInExplorer(String txId) {
  final base = isTestnet ? 'https://testnet.cipherscan.app' : 'https://cipherscan.app';
  launchUrl(
    Uri.parse('$base/tx/$txId'),
    mode: LaunchMode.externalApplication,
  );
}

String? addressValidator(String? v) {
  final s = S.of(rootNavigatorKey.currentContext!);
  if (v == null || v.isEmpty) return s.addressIsEmpty;
  try {
    WarpApi.parseTexAddress(aa.coin, v);
    return null;
  } on String {}
  final valid = WarpApi.validAddress(aa.coin, v);
  if (!valid) return s.invalidAddress;
  return null;
}

String? paymentURIValidator(String? v) {
  final s = S.of(rootNavigatorKey.currentContext!);
  if (v == null || v.isEmpty) return s.required;
  if (WarpApi.decodePaymentURI(aa.coin, v) == null) return s.invalidPaymentURI;
  return null;
}

/// Generate a list of [n] colors based on [color] with hue variation.
List<Color> getPalette(Color color, int n) {
  final count = max(n, 1);
  final hsl = HSLColor.fromColor(color);
  return List.generate(count, (i) {
    final hueShift = (i * 360.0 / count) + hsl.hue;
    return HSLColor.fromAHSL(
      1.0,
      hueShift % 360.0,
      (hsl.saturation * 0.9).clamp(0.0, 1.0),
      (hsl.lightness * 0.85 + 0.1).clamp(0.0, 1.0),
    ).toColor();
  });
}

int numPoolsOf(int v) => Uint8(v).bitsSet;

int poolOf(int v) {
  switch (v) {
    case 1:
      return 0;
    case 2:
      return 1;
    case 4:
      return 2;
    default:
      return 0;
  }
}

Future<bool> authBarrier(BuildContext context,
    {bool dismissable = false}) async {
  final s = S.of(context);
  while (true) {
    final authed = await authenticate(context, s.pleaseAuthenticate);
    if (authed) return true;
    if (dismissable) return false;
  }
}

Future<bool> authenticate(BuildContext context, String reason) async {
  final localAuth = LocalAuthentication();
  try {
    final bool didAuthenticate = await localAuth.authenticate(
          localizedReason: reason, options: AuthenticationOptions());
    if (didAuthenticate) {
      return true;
    }
  } on PlatformException catch (e) {
    await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (context) => AlertDialog(
            title: Text(S.of(context).noAuthenticationMethod),
            content: Text(e.message ?? '')));
  }
  return false;
}

void handleAccel(AccelerometerEvent event) {
  final n = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
  final inclination = acos(event.z / n) / pi * 180 * event.y.sign;
  final flat = inclination < 20
      ? true
      : inclination > 40
          ? false
          : null;
  flat?.let((f) {
    if (f != appStore.flat) appStore.flat = f;
  });
}

double getScreenSize(BuildContext context) {
  final size = MediaQuery.of(context).size;
  return min(size.height - 200, size.width);
}

Future<FilePickerResult?> pickFile() async {
  await FilePicker.platform.clearTemporaryFiles();
  final result = await FilePicker.platform.pickFiles();
  return result;
}

Future<void> saveFileBinary(
    List<int> data, String filename, String title) async {
  final context = rootNavigatorKey.currentContext!;
  Size size = MediaQuery.of(context).size;
  final tempDir = await getTempPath();
  final path = p.join(tempDir, filename);
  final xfile = XFile(path);
  final file = File(path);
  await file.writeAsBytes(data);
  await Share.shareXFiles([xfile],
      subject: title,
      sharePositionOrigin: Rect.fromLTWH(0, 0, size.width, size.height / 2));
}

int getSpendable(int pools, PoolBalanceT balances) {
  return (pools & 1 != 0 ? balances.transparent : 0) +
      (pools & 2 != 0 ? balances.sapling : 0) +
      (pools & 4 != 0 ? balances.orchard : 0);
}

class MemoData {
  bool reply;
  String subject;
  String memo;
  MemoData(this.reply, this.subject, this.memo);

  MemoData clone() => MemoData(reply, subject, memo);
}

extension ScopeFunctions<T> on T {
  R let<R>(R Function(T) block) => block(this);
}

Future<bool> showConfirmDialog(
    BuildContext context, String title, String body,
    {bool isDanger = false}) async {
  final s = S.of(context);
  final accentColor = isDanger ? ZipherColors.red : ZipherColors.cyan;

  final confirmation = await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (context) => Dialog(
                backgroundColor: ZipherColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: ZipherColors.borderSubtle,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.08),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isDanger
                              ? Icons.warning_amber_rounded
                              : Icons.help_outline_rounded,
                          size: 22,
                          color: accentColor.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: ZipherColors.text90,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        body,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: ZipherColors.text40,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () =>
                                  GoRouter.of(context).pop<bool>(false),
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color:
                                      ZipherColors.cardBg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: ZipherColors.borderSubtle,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    s.cancel,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: ZipherColors.text40,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GestureDetector(
                              onTap: () =>
                                  GoRouter.of(context).pop<bool>(true),
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color:
                                      accentColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Center(
                                  child: Text(
                                    s.ok,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: accentColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )) ??
      false;
  return confirmation;
}

Decimal parseNumber(String? sn) {
  if (sn == null || sn.isEmpty) return Decimal.zero;
  // There is no API to parse directly from intl string
  final v = NumberFormat.currency(locale: Platform.localeName).parse(sn);
  return Decimal.parse(v.toStringAsFixed(8));
}

int stringToAmount(String? s) {
  final v = parseNumber(s);
  return (ZECUNIT_DECIMAL * v).toBigInt().toInt();
}

String amountToString2(int amount, {int? digits}) {
  final dd = digits ?? smartDigits(amount);
  return decimalFormat(amount / ZECUNIT, dd);
}

/// Return enough decimal places so the value isn't displayed as zero
/// and small balances always show meaningful precision.
int smartDigits(int amountZat) {
  final defaultD = decimalDigits(appSettings.fullPrec);
  if (amountZat == 0) return defaultD;
  final abs = amountZat.abs();
  if (abs < 1000) return 8.clamp(defaultD, 8);          // < 0.00001 ZEC
  if (abs < 10000) return 5.clamp(defaultD, 8);         // < 0.0001 ZEC
  if (abs < 100000) return 5.clamp(defaultD, 8);        // < 0.001 ZEC
  if (abs < 100000000) return 4.clamp(defaultD, 8);     // < 1 ZEC
  return defaultD;
}

Future<void> saveFile(String data, String filename, String title) async {
  await saveFileBinary(utf8.encode(data), filename, title);
}

String centerTrim(String v, {int leading = 2, int length = 16}) {
  if (v.length <= length) return v;
  final e = v.length - length + leading;
  return v.substring(0, leading) + '...' + v.substring(e);
}

// String trailing(String v, int n) {
//   final len = min(n, v.length);
//   return v.substring(v.length - len);
// }

String getPrivacyLevel(BuildContext context, int level) {
  final s = S.of(context);
  final privacyLevels = [s.veryLow, s.low, s.medium, s.high];
  return privacyLevels[level];
}

bool isMobile() => Platform.isAndroid || Platform.isIOS;

Future<String> getDataPath() async {
  if (Platform.isAndroid) {
    return (await getApplicationDocumentsDirectory()).parent.path;
  }
  return (await getApplicationDocumentsDirectory()).path;
}

Future<String> getTempPath() async {
  final d = await getTemporaryDirectory();
  return d.path;
}

Future<String> getDbPath() async {
  if (Platform.isIOS) return (await getApplicationDocumentsDirectory()).path;
  final h = await getDataPath();
  return "$h/databases";
}

abstract class HasHeight {
  int height = 0;
}

class Reflector extends Reflectable {
  const Reflector() : super(instanceInvokeCapability);
}

const reflector = const Reflector();

@reflector
class Note extends HasHeight {
  int id;
  int height;
  int? confirmations;
  DateTime timestamp;
  double value;
  bool orchard;
  bool excluded;
  bool selected;

  factory Note.from(int? latestHeight, int id, int height, DateTime timestamp,
      double value, bool orchard, bool excluded, bool selected) {
    final confirmations = latestHeight?.let((h) => h - height + 1);
    return Note(id, height, confirmations, timestamp, value, orchard, excluded,
        selected);
  }
  factory Note.fromShieldedNote(ShieldedNoteT n) => Note(n.id, n.height, 0,
      toDateTime(n.timestamp), n.value / ZECUNIT, n.orchard, n.excluded, false);

  Note(this.id, this.height, this.confirmations, this.timestamp, this.value,
      this.orchard, this.excluded, this.selected);

  Note get invertExcluded => Note(id, height, confirmations, timestamp, value,
      orchard, !excluded, selected);

  Note clone() => Note(
      id, height, confirmations, timestamp, value, orchard, excluded, selected);
}

@reflector
class Tx extends HasHeight {
  int id;
  int height;
  int? confirmations;
  DateTime timestamp;
  String txId;
  String fullTxId;
  double value;
  String? address;
  String? contact;
  String? memo;
  List<TxMemo> memos;

  factory Tx.from(
    int? latestHeight,
    int id,
    int height,
    DateTime timestamp,
    String txid,
    String fullTxId,
    double value,
    String? address,
    String? contact,
    String? memo,
    List<Memo> memos,
  ) {
    final confirmations = latestHeight?.let((h) => h - height + 1);
    final memos2 =
        memos.map((m) => TxMemo(address: m.address!, memo: m.memo!)).toList();
    return Tx(id, height, confirmations, timestamp, txid, fullTxId, value,
        address, contact, memo, memos2);
  }

  Tx(
      this.id,
      this.height,
      this.confirmations,
      this.timestamp,
      this.txId,
      this.fullTxId,
      this.value,
      this.address,
      this.contact,
      this.memo,
      this.memos);
}

class ZMessage extends HasHeight {
  final int id;
  final int txId;
  final bool incoming;
  final String? fromAddress;
  final String? sender;
  final String recipient;
  final String subject;
  final String body;
  final DateTime timestamp;
  final int height;
  final bool read;

  ZMessage(
      this.id,
      this.txId,
      this.incoming,
      this.fromAddress,
      this.sender,
      this.recipient,
      this.subject,
      this.body,
      this.timestamp,
      this.height,
      this.read);

  ZMessage withRead(bool v) {
    return ZMessage(id, txId, incoming, fromAddress, sender, recipient, subject,
        body, timestamp, height, v);
  }

  String fromto() => incoming
      ? "\u{21e6} ${sender != null ? centerTrim(sender!) : ''}"
      : "\u{21e8} ${centerTrim(recipient)}";
}

class PnL {
  final DateTime timestamp;
  final double price;
  final double amount;
  final double realized;
  final double unrealized;

  PnL(this.timestamp, this.price, this.amount, this.realized, this.unrealized);

  @override
  String toString() {
    return "$timestamp $price $amount $realized $unrealized";
  }
}

Color amountColor(BuildContext context, num a) {
  if (a < 0) return ZipherColors.red;
  if (a > 0) return ZipherColors.green;
  return ZipherColors.textPrimary;
}

TextStyle weightFromAmount(TextStyle style, num v) {
  final value = v.abs();
  final coin = coins[aa.coin];
  final style2 = style.copyWith(fontFeatures: [FontFeature.tabularFigures()]);
  if (value >= coin.weights[2])
    return style2.copyWith(fontWeight: FontWeight.w800);
  else if (value >= coin.weights[1])
    return style2.copyWith(fontWeight: FontWeight.w600);
  else if (value >= coin.weights[0])
    return style2.copyWith(fontWeight: FontWeight.w400);
  return style2.copyWith(fontWeight: FontWeight.w200);
}

final DateFormat todayDateFormat = DateFormat("HH:mm");
final DateFormat monthDateFormat = DateFormat("MMMd");
final DateFormat longAgoDateFormat = DateFormat("yy-MM-dd");

String humanizeDateTime(BuildContext context, DateTime datetime) {
  final messageDate = datetime.toLocal();
  final now = DateTime.now();
  final justNow = now.subtract(Duration(minutes: 1));
  final midnight = DateTime(now.year, now.month, now.day);
  final year = DateTime(now.year, 1, 1);

  String dateString;
  if (justNow.isBefore(messageDate))
    dateString = S.of(context).now;
  else if (midnight.isBefore(messageDate))
    dateString = todayDateFormat.format(messageDate);
  else if (year.isBefore(messageDate))
    dateString = monthDateFormat.format(messageDate);
  else
    dateString = longAgoDateFormat.format(messageDate);
  return dateString;
}

Future<double?> getFxRate(String coin, String fiat) async {
  final base = "api.coingecko.com";
  final uri = Uri.https(
      base, '/api/v3/simple/price', {'ids': coin, 'vs_currencies': fiat});
  try {
    final rep = await http.get(uri);
    if (rep.statusCode == 200) {
      final json = convert.jsonDecode(rep.body) as Map<String, dynamic>;
      final coinData = json[coin];
      if (coinData == null) return null;
      final p = coinData[fiat.toLowerCase()];
      if (p == null) return null;
      return (p is double) ? p : (p as int).toDouble();
    }
  } catch (e) {
    logger.e(e);
  }
  return null;
}

class TimeSeriesPoint<V> {
  final int day;
  final V value;

  TimeSeriesPoint(this.day, this.value);

  @override
  String toString() => '($day, $value)';
}

class AccountBalance {
  final DateTime time;
  final double balance;

  AccountBalance(this.time, this.balance);
  @override
  String toString() => "($time $balance)";
}

List<TimeSeriesPoint<V>> sampleDaily<T, Y, V>(
    Iterable<T> timeseries,
    int start,
    int end,
    int Function(T) getDay,
    Y Function(T) getY,
    V Function(V, Y) accFn,
    V initial) {
  assert(start % DAY_SEC == 0);
  final s = start ~/ DAY_SEC;
  final e = end ~/ DAY_SEC;

  List<TimeSeriesPoint<V>> ts = [];
  var acc = initial;

  var tsIterator = timeseries.iterator;
  var next = tsIterator.moveNext() ? tsIterator.current : null;
  var nextDay = next?.let((n) => getDay(n));

  for (var day = s; day <= e; day++) {
    while (nextDay != null && day == nextDay) {
      // accumulate
      acc = accFn(acc, getY(next!));
      next = tsIterator.moveNext() ? tsIterator.current : null;
      nextDay = next?.let((n) => getDay(n));
    }
    ts.add(TimeSeriesPoint(day, acc));
  }
  return ts;
}

class Quote {
  final DateTime dt;
  final price;

  Quote(this.dt, this.price);
}

class Trade {
  final DateTime dt;
  final qty;

  Trade(this.dt, this.qty);
}

FormFieldValidator<T> composeOr<T>(List<FormFieldValidator<T>> validators) {
  return (v) {
    String? first;
    for (var validator in validators) {
      final res = validator.call(v);
      if (res == null) return null;
      if (first == null) first = res;
    }
    return first;
  };
}

class PoolBitSet {
  static Set<int> toSet(int pools) {
    return List.generate(3, (index) => pools & (1 << index) != 0 ? index : null)
        .whereNotNull()
        .toSet();
  }

  static int fromSet(Set<int> poolSet) => poolSet.map((p) => 1 << p).sum;
}

List<Account> getAllAccounts() =>
    WarpApi.getAccountList(activeCoin.coin).toList();

void showLocalNotification({required int id, String? title, String? body}) {
  AwesomeNotifications().createNotification(
      content: NotificationContent(
    channelKey: APP_NAME,
    id: id,
    title: title,
    body: body,
  ));
}

extension PoolBalanceExtension on PoolBalanceT {
  int get total => transparent + sapling + orchard;
}

String? isValidUA(int uaType) {
  if (uaType == 1) return GetIt.I<S>().invalidAddress;
  return null;
}

// ═══════════════════════════════════════════════════════════
// CONTACT AUTOCOMPLETE OVERLAY
// ═══════════════════════════════════════════════════════════

/// An overlay that shows contact suggestions as the user types in an address
/// field. Wrap any address TextField with this widget.
class ContactAutocomplete extends StatefulWidget {
  final TextEditingController controller;
  final Widget child;
  final void Function(String address, String name) onSelected;

  const ContactAutocomplete({
    super.key,
    required this.controller,
    required this.child,
    required this.onSelected,
  });

  @override
  State<ContactAutocomplete> createState() => _ContactAutocompleteState();
}

class _ContactAutocompleteState extends State<ContactAutocomplete> {
  final _link = LayerLink();
  OverlayEntry? _overlay;
  List<Contact> _matches = [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _removeOverlay();
    super.dispose();
  }

  void _onChanged() {
    final query = widget.controller.text.trim().toLowerCase();
    if (query.isEmpty || query.length > 60) {
      _removeOverlay();
      return;
    }
    final contacts = WarpApi.getContacts(aa.coin);
    _matches = contacts.where((c) {
      if (c.name == null || c.address == null) return false;
      return c.name!.toLowerCase().contains(query) ||
          c.address!.toLowerCase().startsWith(query);
    }).toList();

    if (_matches.isEmpty) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    _removeOverlay();
    _overlay = OverlayEntry(builder: (context) {
      return Positioned(
        width: 300,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          offset: const Offset(0, 56),
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: ZipherColors.borderSubtle,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: _matches.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: ZipherColors.cardBg,
                  ),
                  itemBuilder: (context, index) {
                    final c = _matches[index];
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor:
                            initialToColor(c.name![0].toUpperCase())
                                .withValues(alpha: 0.15),
                        child: Text(
                          c.name![0].toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: initialToColor(c.name![0].toUpperCase()),
                          ),
                        ),
                      ),
                      title: Text(
                        c.name!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: ZipherColors.text90,
                        ),
                      ),
                      subtitle: Text(
                        centerTrim(c.address!, length: 16),
                        style: TextStyle(
                          fontSize: 10,
                          color: ZipherColors.text20,
                        ),
                      ),
                      onTap: () {
                        widget.onSelected(c.address!, c.name!);
                        _removeOverlay();
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    });
    Overlay.of(context).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: widget.child,
    );
  }
}

// ═══════════════════════════════════════════════════════════
// OUTGOING MEMO STORE  (backed by zipher_app.db)
// The Rust backend doesn't store outgoing memos in the
// transactions table, so we store them on the Dart side
// in a dedicated SQLite database.
// ═══════════════════════════════════════════════════════════

/// A cached outgoing message with full metadata.
class CachedOutgoingMemo {
  final String memo;
  final String recipient;
  final int timestampMs;

  /// True when the message was sent without a reply-to address,
  /// meaning the recipient won't know who sent it.
  final bool anonymous;

  CachedOutgoingMemo({
    required this.memo,
    required this.recipient,
    required this.timestampMs,
    this.anonymous = false,
  });
}

/// Pending message waiting to be associated with the next broadcast tx.
String? pendingOutgoingMemo;
String? pendingOutgoingRecipient;
bool pendingOutgoingAnonymous = false;

/// In-memory cache: full tx hash → CachedOutgoingMemo (per-account).
/// Loaded from SQLite on account switch for fast synchronous reads.
Map<String, CachedOutgoingMemo> _outgoingMemos = {};
int _loadedCoin = -1;
int _loadedAccount = -1;

/// Load (or reload) sent memos for the given account from the DB.
/// Call at startup and on every account switch.
Future<void> loadOutgoingMemos({int? coin, int? accountId}) async {
  final c = coin ?? aa.coin;
  final id = accountId ?? aa.id;
  if (c == _loadedCoin && id == _loadedAccount) return;
  _loadedCoin = c;
  _loadedAccount = id;
  _outgoingMemos = await SentMemosDb.getAllForAccount(c, id);
}

/// Call after signAndBroadcast returns the full tx hash.
Future<void> commitOutgoingMemo(String fullTxHash) async {
  if (pendingOutgoingMemo != null && pendingOutgoingMemo!.isNotEmpty) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final memo = pendingOutgoingMemo!;
    final recipient = pendingOutgoingRecipient ?? '';
    final anonymous = pendingOutgoingAnonymous;

    // Write to DB
    await SentMemosDb.insert(
      coin: aa.coin,
      accountId: aa.id,
      txHash: fullTxHash,
      memo: memo,
      recipient: recipient,
      timestampMs: now,
      anonymous: anonymous,
    );

    // Update in-memory cache
    _outgoingMemos[fullTxHash] = CachedOutgoingMemo(
      memo: memo,
      recipient: recipient,
      timestampMs: now,
      anonymous: anonymous,
    );

    pendingOutgoingMemo = null;
    pendingOutgoingRecipient = null;
    pendingOutgoingAnonymous = false;
  }
}

/// Retrieve a cached outgoing memo by full tx hash (synchronous, from memory).
String? getOutgoingMemo(String fullTxHash) {
  return _outgoingMemos[fullTxHash]?.memo;
}

/// Get all cached outgoing messages for the current account (for Messages page).
Map<String, CachedOutgoingMemo> get outgoingMemoCache => _outgoingMemos;
