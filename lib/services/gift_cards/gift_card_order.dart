import 'gift_card_math.dart';

/// Where a gift-card purchase stands.
///
/// The one rule the machine exists for: once a payment may exist on chain
/// ([paying] onwards) the order can never return to a state that offers to
/// pay again. Every later problem becomes [needsSupport], never a retry.
enum GiftCardStatus {
  /// Provider invoice exists; nothing signed yet. Paying is allowed.
  awaitingPayment,

  /// The user approved and the wallet is signing / broadcasting.
  paying,

  /// The wallet broadcast the payment; the provider has not confirmed it.
  paid,

  /// The provider saw the payment and is issuing the card.
  processing,

  /// The redemption code is stored on this device.
  delivered,

  /// The invoice lapsed before anything was sent.
  expired,

  /// Nothing was sent (declined approval, signing error, provider refused).
  cancelled,

  /// The provider refunded the payment.
  refunded,

  /// Money may have left the wallet but the card is not delivered. The user
  /// needs the order id and txid to contact the provider. Never re-pay.
  needsSupport,
}

enum GiftCardEvent {
  approve,
  notSent,
  broadcast,
  sendUncertain,
  providerPaid,
  delivered,
  expired,
  refunded,
  providerFailed,
}

class IllegalGiftCardTransition implements Exception {
  IllegalGiftCardTransition(this.from, this.event);
  final GiftCardStatus from;
  final GiftCardEvent event;
  @override
  String toString() => 'Gift card order cannot ${event.name} while ${from.name}';
}

extension GiftCardStatusX on GiftCardStatus {
  bool get canPay => this == GiftCardStatus.awaitingPayment;

  /// A transaction may exist for this order.
  bool get paymentMayExist => const {
        GiftCardStatus.paying,
        GiftCardStatus.paid,
        GiftCardStatus.processing,
        GiftCardStatus.delivered,
        GiftCardStatus.refunded,
        GiftCardStatus.needsSupport,
      }.contains(this);

  bool get isTerminal => const {
        GiftCardStatus.delivered,
        GiftCardStatus.expired,
        GiftCardStatus.cancelled,
        GiftCardStatus.refunded,
      }.contains(this);

  /// Worth asking the provider about (only after an explicit user action or
  /// while the order screen is open — never on a background timer).
  bool get pollable => const {
        GiftCardStatus.paid,
        GiftCardStatus.processing,
        GiftCardStatus.needsSupport,
      }.contains(this);

  String get label => switch (this) {
        GiftCardStatus.awaitingPayment => 'Awaiting payment',
        GiftCardStatus.paying => 'Sending payment',
        GiftCardStatus.paid => 'Payment sent',
        GiftCardStatus.processing => 'Issuing card',
        GiftCardStatus.delivered => 'Ready',
        GiftCardStatus.expired => 'Expired',
        GiftCardStatus.cancelled => 'Not paid',
        GiftCardStatus.refunded => 'Refunded',
        GiftCardStatus.needsSupport => 'Needs attention',
      };
}

/// Pure transition table. Throws [IllegalGiftCardTransition] for anything
/// not listed, so a stale or replayed provider status cannot move an order
/// backwards.
GiftCardStatus nextGiftCardStatus(GiftCardStatus from, GiftCardEvent event) {
  final next = switch ((from, event)) {
    (GiftCardStatus.awaitingPayment, GiftCardEvent.approve) =>
      GiftCardStatus.paying,
    (GiftCardStatus.awaitingPayment, GiftCardEvent.expired) =>
      GiftCardStatus.expired,
    (GiftCardStatus.awaitingPayment, GiftCardEvent.providerFailed) =>
      GiftCardStatus.cancelled,
    // A payment from elsewhere (another device) still counts.
    (GiftCardStatus.awaitingPayment, GiftCardEvent.providerPaid) =>
      GiftCardStatus.processing,
    (GiftCardStatus.awaitingPayment, GiftCardEvent.delivered) =>
      GiftCardStatus.delivered,
    (GiftCardStatus.paying, GiftCardEvent.notSent) => GiftCardStatus.cancelled,
    (GiftCardStatus.paying, GiftCardEvent.broadcast) => GiftCardStatus.paid,
    (GiftCardStatus.paying, GiftCardEvent.sendUncertain) =>
      GiftCardStatus.needsSupport,
    (GiftCardStatus.paid ||
          GiftCardStatus.needsSupport ||
          GiftCardStatus.paying,
        GiftCardEvent.providerPaid) =>
      GiftCardStatus.processing,
    (GiftCardStatus.paid ||
          GiftCardStatus.processing ||
          GiftCardStatus.needsSupport ||
          GiftCardStatus.paying,
        GiftCardEvent.delivered) =>
      GiftCardStatus.delivered,
    // Expiry or failure after money may have moved is a support case.
    (GiftCardStatus.paid || GiftCardStatus.processing,
        GiftCardEvent.expired || GiftCardEvent.providerFailed) =>
      GiftCardStatus.needsSupport,
    (GiftCardStatus.needsSupport,
        GiftCardEvent.expired || GiftCardEvent.providerFailed) =>
      GiftCardStatus.needsSupport,
    (GiftCardStatus.paid ||
          GiftCardStatus.processing ||
          GiftCardStatus.needsSupport,
        GiftCardEvent.refunded) =>
      GiftCardStatus.refunded,
    // Repeated reports of the current state are harmless.
    (GiftCardStatus.processing, GiftCardEvent.providerPaid) =>
      GiftCardStatus.processing,
    (GiftCardStatus.delivered, GiftCardEvent.delivered) =>
      GiftCardStatus.delivered,
    _ => null,
  };
  if (next == null) throw IllegalGiftCardTransition(from, event);
  return next;
}

/// A purchase as kept on this device. The redemption code itself is held in
/// secure storage, keyed by [id]; this record only says whether it exists.
class GiftCardOrder {
  const GiftCardOrder({
    required this.id,
    required this.provider,
    required this.productId,
    required this.productName,
    required this.faceValue,
    required this.priceZatoshis,
    required this.paymentAddress,
    required this.status,
    required this.createdAt,
    this.walletId,
    this.testnet = false,
    this.paymentUri,
    this.memo,
    this.expiresAt,
    this.networkFeeZatoshis,
    this.txid,
    this.hasCode = false,
    this.redeemUrl,
    this.logoUrl,
    this.note,
  });

  /// Provider order / invoice id.
  final String id;
  final String provider;
  final String productId;
  final String productName;
  final Fiat faceValue;

  /// Exactly what the provider's invoice asks for.
  final int priceZatoshis;
  final String paymentAddress;
  final String? paymentUri;
  final String? memo;
  final GiftCardStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final String? walletId;
  final bool testnet;
  final int? networkFeeZatoshis;
  final String? txid;
  final bool hasCode;
  final String? redeemUrl;
  final String? logoUrl;

  /// Last provider message worth showing ("Card is being issued").
  final String? note;

  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);

  /// Applies [event]; throws on an illegal transition.
  GiftCardOrder apply(GiftCardEvent event,
          {String? txid,
          int? networkFeeZatoshis,
          bool? hasCode,
          String? redeemUrl,
          String? note}) =>
      copyWith(
          status: nextGiftCardStatus(status, event),
          txid: txid,
          networkFeeZatoshis: networkFeeZatoshis,
          hasCode: hasCode,
          redeemUrl: redeemUrl,
          note: note);

  GiftCardOrder copyWith(
          {GiftCardStatus? status,
          String? txid,
          int? networkFeeZatoshis,
          bool? hasCode,
          String? redeemUrl,
          String? note}) =>
      GiftCardOrder(
          id: id,
          provider: provider,
          productId: productId,
          productName: productName,
          faceValue: faceValue,
          priceZatoshis: priceZatoshis,
          paymentAddress: paymentAddress,
          paymentUri: paymentUri,
          memo: memo,
          status: status ?? this.status,
          createdAt: createdAt,
          expiresAt: expiresAt,
          walletId: walletId,
          testnet: testnet,
          networkFeeZatoshis: networkFeeZatoshis ?? this.networkFeeZatoshis,
          txid: txid ?? this.txid,
          hasCode: hasCode ?? this.hasCode,
          redeemUrl: redeemUrl ?? this.redeemUrl,
          logoUrl: logoUrl,
          note: note ?? this.note);

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider,
        'productId': productId,
        'productName': productName,
        'faceMinor': faceValue.minor,
        'currency': faceValue.currency,
        'priceZat': priceZatoshis,
        'address': paymentAddress,
        if (paymentUri != null) 'uri': paymentUri,
        if (memo != null) 'memo': memo,
        'status': status.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
        if (walletId != null) 'walletId': walletId,
        'testnet': testnet,
        if (networkFeeZatoshis != null) 'feeZat': networkFeeZatoshis,
        if (txid != null) 'txid': txid,
        'hasCode': hasCode,
        if (redeemUrl != null) 'redeemUrl': redeemUrl,
        if (logoUrl != null) 'logo': logoUrl,
        if (note != null) 'note': note,
      };

  static GiftCardOrder fromJson(Map<String, dynamic> j) => GiftCardOrder(
        id: j['id'] as String,
        provider: j['provider'] as String,
        productId: j['productId'] as String,
        productName: j['productName'] as String,
        faceValue: Fiat(j['faceMinor'] as int, j['currency'] as String),
        priceZatoshis: j['priceZat'] as int,
        paymentAddress: j['address'] as String,
        paymentUri: j['uri'] as String?,
        memo: j['memo'] as String?,
        status: GiftCardStatus.values.byName(j['status'] as String),
        createdAt: DateTime.parse(j['createdAt'] as String),
        expiresAt: j['expiresAt'] == null
            ? null
            : DateTime.parse(j['expiresAt'] as String),
        walletId: j['walletId'] as String?,
        testnet: j['testnet'] as bool? ?? false,
        networkFeeZatoshis: j['feeZat'] as int?,
        txid: j['txid'] as String?,
        hasCode: j['hasCode'] as bool? ?? false,
        redeemUrl: j['redeemUrl'] as String?,
        logoUrl: j['logo'] as String?,
        note: j['note'] as String?,
      );
}
