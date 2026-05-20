import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class CipherPayInvoice {
  final String id;
  final String status;
  final double amount;
  final String currency;
  final double priceZec;
  final double priceEur;
  final int? priceZatoshis;
  final String paymentAddress;
  final String memoCode;
  final double? receivedZec;
  final String? detectedTxid;
  final String expiresAt;
  final String createdAt;
  final String? productName;
  final String? merchantName;
  final String? merchantOrigin;

  const CipherPayInvoice({
    required this.id,
    required this.status,
    required this.amount,
    required this.currency,
    required this.priceZec,
    required this.priceEur,
    required this.priceZatoshis,
    required this.paymentAddress,
    required this.memoCode,
    required this.receivedZec,
    required this.detectedTxid,
    required this.expiresAt,
    required this.createdAt,
    required this.productName,
    required this.merchantName,
    required this.merchantOrigin,
  });

  factory CipherPayInvoice.fromJson(Map<String, dynamic> json) {
    return CipherPayInvoice(
      id: (json['id'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'pending',
      amount: _asDouble(json['amount']),
      currency: ((json['currency'] as String?) ?? 'EUR').toUpperCase(),
      priceZec: _asDouble(json['price_zec']),
      priceEur: _asDouble(json['price_eur']),
      priceZatoshis: _asInt(json['price_zatoshis']),
      paymentAddress: (json['payment_address'] as String?) ?? '',
      memoCode: (json['memo_code'] as String?) ?? '',
      receivedZec: _asNullableDouble(json['received_zec']),
      detectedTxid: json['detected_txid'] as String?,
      expiresAt: (json['expires_at'] as String?) ?? '',
      createdAt: (json['created_at'] as String?) ?? '',
      productName: json['product_name'] as String?,
      merchantName: json['merchant_name'] as String?,
      merchantOrigin: json['merchant_origin'] as String?,
    );
  }

  static double _asDouble(Object? value) => _asNullableDouble(value) ?? 0;

  static double? _asNullableDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// Customer-side helper around CipherPay invoices.
///
/// Privacy: we only contact `api.cipherpay.app` in response to an explicit
/// user action (scanning a QR, opening a checkout link, tapping refresh).
/// We never poll silently — that would leak the buyer's IP on a timer.
class CipherPayClient {
  CipherPayClient._();

  /// Matches the canonical memo code shape `CP-XXXXXXXX` (8 base32-ish chars).
  static final RegExp _memoCodeRegex = RegExp(r'\bCP-[A-Z0-9]{6,12}\b');
  static final RegExp _memoCodeExactRegex = RegExp(r'^CP-[A-Z0-9]{6,12}$');

  /// Matches a v4 UUID anywhere in a string.
  static final RegExp _uuidRegex = RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
  );

  /// Pull a CipherPay invoice id from arbitrary scanned/pasted input.
  ///
  /// Recognised shapes (in priority order):
  ///  1. `https://cipherpay.app/pay/<uuid>` (checkout link)
  ///  2. `cipherpay:<uuid>` or `cipherpay:CP-XXXXXXXX` (deep link, future)
  ///  3. A bare `CP-XXXXXXXX` memo code
  ///  4. A base64url-encoded `CP-XXXXXXXX` memo code
  ///  5. A `zcash:` URI whose memo decodes to `CP-XXXXXXXX`
  ///  6. A bare UUID v4
  ///
  /// Returns `null` when nothing matches.
  static String? extractInvoiceRef(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // Hosted checkout: https://cipherpay.app/pay/<uuid> (or http for local dev)
    if (trimmed.startsWith('https://cipherpay.app/pay/') ||
        trimmed.startsWith('http://cipherpay.app/pay/') ||
        trimmed.startsWith('https://www.cipherpay.app/pay/')) {
      final uuid = _uuidRegex.firstMatch(trimmed)?.group(0);
      if (uuid != null) return uuid;
    }

    // Custom scheme (not yet emitted but reserved).
    if (trimmed.startsWith('cipherpay:')) {
      final after = trimmed.substring('cipherpay:'.length);
      final memo = _memoCodeRegex.firstMatch(after)?.group(0);
      if (memo != null) return memo;
      final uuid = _uuidRegex.firstMatch(after)?.group(0);
      if (uuid != null) return uuid;
    }

    // Bare memo code.
    final bareMemo = _memoCodeRegex.firstMatch(trimmed)?.group(0);
    if (bareMemo != null) return bareMemo;

    // Some CipherPay QR codes encode only the memo as base64url (ZIP-321
    // memo format) instead of wrapping it in a full zcash: URI. Decode before
    // falling through to generic Send, otherwise the app opens an empty Send
    // form with the encoded memo and no recipient address.
    final decodedMemo = _decodeBase64Url(trimmed);
    if (decodedMemo != null) {
      final decoded = decodedMemo.trim();
      if (_memoCodeExactRegex.hasMatch(decoded)) return decoded;
    }

    // zcash:<address>?...&memo=<base64url-encoded CP-...>
    if (trimmed.startsWith('zcash:') || trimmed.startsWith('zcash-test:')) {
      final memoCode = _memoCodeFromZcashUri(trimmed);
      if (memoCode != null) return memoCode;
    }

    // Bare UUID (last resort).
    final uuid = _uuidRegex.firstMatch(trimmed)?.group(0);
    if (uuid != null) return uuid;

    return null;
  }

  /// Decode the `memo` query param of a ZIP-321 URI and look for `CP-XXXX`.
  /// Returns null if no memo, or memo doesn't decode to a CipherPay code.
  static String? _memoCodeFromZcashUri(String puri) {
    try {
      final qIndex = puri.indexOf('?');
      if (qIndex < 0) return null;
      final params = Uri.splitQueryString(puri.substring(qIndex + 1));
      for (final entry in params.entries) {
        if (entry.key != 'memo' && !entry.key.startsWith('memo.')) continue;
        final candidates = <String>[entry.value];
        // ZIP-321 uses base64url without padding.
        try {
          final decoded = _decodeBase64Url(entry.value);
          if (decoded != null) candidates.add(decoded);
        } catch (_) {}
        for (final c in candidates) {
          final m = _memoCodeRegex.firstMatch(c);
          if (m != null) return m.group(0);
        }
      }
    } catch (_) {}
    return null;
  }

  static String? _decodeBase64Url(String input) {
    try {
      var s = input.replaceAll('-', '+').replaceAll('_', '/');
      while (s.length % 4 != 0) {
        s += '=';
      }
      final bytes = Uri.parse('data:application/octet-stream;base64,$s')
          .data
          ?.contentAsBytes();
      if (bytes == null) return null;
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Fetch a CipherPay invoice. Performs one anonymous GET.
  ///
  /// Throws on network failure / non-2xx — caller is responsible for
  /// presenting a clean error message.
  static Future<CipherPayInvoice> getInvoice(String idOrMemo) async {
    final uri = Uri.https(
      'api.cipherpay.app',
      '/api/invoices/${Uri.encodeComponent(idOrMemo)}',
    );
    final resp = await http.get(uri);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
          'Invoice check failed (${resp.statusCode}): ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return CipherPayInvoice.fromJson(json);
  }

  /// Poll an invoice every [interval] until [status] is reached or [timeout]
  /// elapses. Yields each fetched status; closes when terminal.
  ///
  /// Use this only after the user has explicitly broadcast a payment for the
  /// invoice — never as background discovery.
  static Stream<CipherPayInvoice> pollInvoice(
    String idOrMemo, {
    Set<String> terminalStatuses = const {'confirmed', 'expired', 'cancelled'},
    Duration interval = const Duration(seconds: 5),
    Duration? timeout = const Duration(minutes: 30),
  }) async* {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (deadline == null || DateTime.now().isBefore(deadline)) {
      try {
        final invoice = await getInvoice(idOrMemo);
        yield invoice;
        if (terminalStatuses.contains(invoice.status)) return;
      } catch (_) {
        // Transient errors are swallowed — we will retry on the next tick.
        // The UI can detect a stall by tracking how long it's been since the
        // last successful yield.
      }
      await Future.delayed(interval);
    }
  }
}
