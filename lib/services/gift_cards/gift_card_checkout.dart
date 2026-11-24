import '../app_log.dart';
import '../wallet_service.dart';
import 'gift_card_math.dart';
import 'gift_card_order.dart';
import 'gift_card_provider.dart';
import 'gift_card_store.dart';

/// The wallet operations checkout needs; [WalletService] in the app.
abstract class GiftCardWallet {
  String? get activeWalletId;
  int get proposalRevision;
  Future<bool> isValidAddress(String address);
  Future<({int sendAmount, int fee, bool isExact})> proposeSend(
      String address, int zatoshis,
      {String? memo, bool priority = false});
  Future<SendOutcome> confirmSendDetailed(
      {required int expectedRevision,
      required String expectedWalletId,
      required bool expectedTestnet});
}

class WalletServiceGiftCardWallet implements GiftCardWallet {
  const WalletServiceGiftCardWallet();
  WalletService get _w => WalletService.instance;
  @override
  String? get activeWalletId => _w.activeWalletId;
  @override
  int get proposalRevision => _w.proposalRevision;
  @override
  Future<bool> isValidAddress(String address) async =>
      (await _w.validateAddress(address)).isValid;
  @override
  Future<({int sendAmount, int fee, bool isExact})> proposeSend(
          String address, int zatoshis,
          {String? memo, bool priority = false}) =>
      _w.proposeSend(address, zatoshis, memo: memo, priority: priority);
  @override
  Future<SendOutcome> confirmSendDetailed(
          {required int expectedRevision,
          required String expectedWalletId,
          required bool expectedTestnet}) =>
      _w.confirmSendDetailed(
          expectedRevision: expectedRevision,
          expectedWalletId: expectedWalletId,
          expectedTestnet: expectedTestnet);
}

class GiftCardCheckoutException implements Exception {
  GiftCardCheckoutException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An exact, signable proposal for an order. Valid only while
/// [revision] is the wallet's current proposal revision.
class GiftCardProposal {
  const GiftCardProposal(
      {required this.order, required this.cost, required this.revision});
  final GiftCardOrder order;
  final GiftCardCost cost;
  final int revision;
}

/// Drives one purchase: provider order → exact wallet proposal → (user
/// reviews; the UI asks for device authentication) → signed payment →
/// provider delivery. Signing happens only in [pay], which the UI calls after
/// the review card's confirm **and** [requireSigningAuthorization].
class GiftCardCheckout {
  GiftCardCheckout({
    required this.provider,
    required this.store,
    required this.wallet,
    required this.testnet,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final GiftCardProvider provider;
  final GiftCardStore store;
  final GiftCardWallet wallet;
  final bool testnet;
  final DateTime Function() _now;

  /// Creates the provider order and saves it before anything is signed.
  Future<GiftCardOrder> createOrder(GiftCardProduct product, Fiat amount,
      {required String walletId}) async {
    final why = product.denominations.reject(amount.minor);
    if (why != null) throw GiftCardCheckoutException(why);
    if (amount.currency != product.currency.toUpperCase()) {
      throw GiftCardCheckoutException('That card is sold in ${product.currency}.');
    }
    final invoice = await provider.createOrder(product, amount);
    if (invoice.priceZatoshis <= 0) {
      throw GiftCardCheckoutException('The provider returned an invalid price.');
    }
    if (invoice.memo != null && invoice.memo!.length > 512) {
      throw GiftCardCheckoutException('The provider returned an invalid memo.');
    }
    final order = GiftCardOrder(
      id: invoice.orderId,
      provider: provider.id,
      productId: product.id,
      productName: product.name,
      faceValue: amount,
      priceZatoshis: invoice.priceZatoshis,
      paymentAddress: invoice.paymentAddress,
      paymentUri: invoice.paymentUri,
      memo: invoice.memo,
      expiresAt: invoice.expiresAt,
      status: GiftCardStatus.awaitingPayment,
      createdAt: _now().toUtc(),
      walletId: walletId,
      testnet: testnet,
      logoUrl: product.logoUrl,
    );
    await store.save(order);
    AppLog.instance.event('giftcard', 'order_created');
    return order;
  }

  /// Builds the exact proposal the review card shows.
  Future<GiftCardProposal> propose(GiftCardOrder order,
      {bool priority = false}) async {
    _requirePayable(order);
    if (!await wallet.isValidAddress(order.paymentAddress)) {
      throw GiftCardCheckoutException(
          'The provider returned a payment address this wallet cannot pay. Nothing was sent.');
    }
    final p = await wallet.proposeSend(order.paymentAddress, order.priceZatoshis,
        memo: order.memo, priority: priority);
    if (!p.isExact || p.sendAmount != order.priceZatoshis) {
      throw GiftCardCheckoutException(
          'This wallet can’t send that exact amount right now. Check your spendable balance.');
    }
    return GiftCardProposal(
        order: order,
        cost: GiftCardCost(
            faceValue: order.faceValue,
            priceZatoshis: order.priceZatoshis,
            networkFeeZatoshis: p.fee),
        revision: wallet.proposalRevision);
  }

  void _requirePayable(GiftCardOrder order) {
    if (!order.status.canPay) {
      throw GiftCardCheckoutException('This order can no longer be paid.');
    }
    if (order.isExpiredAt(_now().toUtc().add(const Duration(minutes: 1)))) {
      throw GiftCardCheckoutException(
          'This order expired before payment. Nothing was sent.');
    }
    if (order.testnet != testnet || order.walletId != wallet.activeWalletId) {
      throw GiftCardCheckoutException(
          'The wallet or network changed. Nothing was sent.');
    }
  }

  /// Signs and broadcasts [proposal]. Call only after the user confirmed the
  /// review and passed device authentication. Returns the updated order;
  /// never throws after a transaction may exist.
  Future<GiftCardOrder> pay(GiftCardProposal proposal) async {
    var order = proposal.order;
    _requirePayable(order);
    final walletId = wallet.activeWalletId;
    if (walletId == null || wallet.proposalRevision != proposal.revision) {
      throw GiftCardCheckoutException(
          'Another transaction replaced this review, so nothing was sent.');
    }
    // Persist "paying" before signing: if the app dies mid-broadcast the
    // order shows as needing attention instead of offering to pay again.
    order = order.apply(GiftCardEvent.approve,
        networkFeeZatoshis: proposal.cost.networkFeeZatoshis);
    await store.save(order);
    final SendOutcome outcome;
    try {
      outcome = await wallet.confirmSendDetailed(
          expectedRevision: proposal.revision,
          expectedWalletId: walletId,
          expectedTestnet: testnet);
    } on SendUncertainException catch (e) {
      AppLog.instance.event('giftcard', 'outcome_unknown', error: e);
      order = order.apply(GiftCardEvent.sendUncertain,
          note: 'The wallet stopped while sending. Check history before contacting support.');
      await store.save(order);
      return order;
    } catch (e) {
      // The engine reports an error only before a transaction exists.
      AppLog.instance.event('giftcard', 'not_sent', error: e);
      order = order.apply(GiftCardEvent.notSent, note: 'Nothing was sent.');
      await store.save(order);
      rethrow;
    }
    AppLog.instance.event('giftcard', 'submitted',
        detail: 'broadcast=${outcome.broadcast.name}');
    // The transaction exists whatever the broadcast says; sync resubmits it.
    order = order.apply(GiftCardEvent.broadcast, txid: outcome.txid);
    await store.save(order);
    return order;
  }

  /// One provider status check, applied through the state machine. Stale or
  /// out-of-order reports are ignored rather than moving the order back.
  Future<GiftCardOrder> refresh(GiftCardOrder order) async {
    final status = await provider.status(order);
    final event = status.event;
    var next = order;
    if (event != null) {
      try {
        next = order.apply(event,
            hasCode: status.redemption != null && !status.redemption!.isEmpty
                ? true
                : null,
            redeemUrl: status.redemption?.url,
            note: status.note);
      } on IllegalGiftCardTransition {
        AppLog.instance.event('giftcard', 'status_ignored',
            detail: '${order.status.name}+${event.name}');
        return order;
      }
    } else if (status.note != null) {
      next = order.copyWith(note: status.note);
    }
    final redemption = status.redemption;
    if (redemption != null && !redemption.isEmpty) {
      await store.saveRedemption(next, redemption);
    }
    if (order.status.canPay &&
        next.status == order.status &&
        order.isExpiredAt(_now().toUtc())) {
      next = next.apply(GiftCardEvent.expired);
    }
    await store.save(next);
    return next;
  }
}
