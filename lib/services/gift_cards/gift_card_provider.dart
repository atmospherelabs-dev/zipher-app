import 'gift_card_math.dart';
import 'gift_card_order.dart';
import 'gift_card_store.dart';

/// A card in the provider's catalog.
class GiftCardProduct {
  const GiftCardProduct({
    required this.id,
    required this.name,
    required this.currency,
    required this.denominations,
    this.country,
    this.category,
    this.logoUrl,
    this.description,
    this.redeemInstructions,
    this.discountBps,
  });

  final String id;
  final String name;
  final String currency;
  final Denominations denominations;

  /// ISO-3166 alpha-2, or null for global cards.
  final String? country;
  final String? category;
  final String? logoUrl;
  final String? description;
  final String? redeemInstructions;

  /// Provider-advertised discount (negative markup) in basis points.
  final int? discountBps;
}

/// The provider's invoice: an exact amount of ZEC to a deposit address.
class GiftCardInvoice {
  const GiftCardInvoice({
    required this.orderId,
    required this.priceZatoshis,
    required this.paymentAddress,
    this.paymentUri,
    this.memo,
    this.expiresAt,
  });

  final String orderId;
  final int priceZatoshis;
  final String paymentAddress;
  final String? paymentUri;
  final String? memo;
  final DateTime? expiresAt;
}

/// What the provider says about an order.
class GiftCardProviderStatus {
  const GiftCardProviderStatus({required this.event, this.redemption, this.note});

  /// The transition this status implies, or null when nothing changed.
  final GiftCardEvent? event;
  final GiftCardRedemption? redemption;
  final String? note;
}

class GiftCardProviderException implements Exception {
  GiftCardProviderException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One gift-card vendor. Implementations talk to the network only when the
/// user acts (opens the catalog, buys, refreshes an order screen).
abstract class GiftCardProvider {
  String get id;
  String get name;

  /// Shown under the buy button: who issues the card and what they see.
  String get privacyNote;

  /// Whether the provider can create orders (keys / partner access present).
  bool get canPurchase;

  Future<List<GiftCardProduct>> catalog({String? country});

  Future<GiftCardInvoice> createOrder(GiftCardProduct product, Fiat amount);

  Future<GiftCardProviderStatus> status(GiftCardOrder order);
}
