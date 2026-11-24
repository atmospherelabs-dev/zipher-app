import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zipher/services/gift_cards/gift_card_checkout.dart';
import 'package:zipher/services/gift_cards/gift_card_math.dart';
import 'package:zipher/services/gift_cards/gift_card_order.dart';
import 'package:zipher/services/gift_cards/gift_card_provider.dart';
import 'package:zipher/services/gift_cards/gift_card_store.dart';
import 'package:zipher/services/wallet_service.dart';

class _Secrets implements GiftCardSecrets {
  final map = <String, String>{};
  @override
  Future<void> delete(String key) async => map.remove(key);
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
}

class _Provider implements GiftCardProvider {
  GiftCardProviderStatus next = const GiftCardProviderStatus(event: null);
  int created = 0;
  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  String get privacyNote => '';
  @override
  bool get canPurchase => true;
  @override
  Future<List<GiftCardProduct>> catalog({String? country}) async => [];
  @override
  Future<GiftCardInvoice> createOrder(GiftCardProduct product, Fiat amount) async {
    created++;
    return GiftCardInvoice(
        orderId: 'o$created',
        priceZatoshis: 62500000,
        paymentAddress: 'u1pay',
        memo: 'order o$created',
        expiresAt: DateTime.utc(2026, 11, 24, 13));
  }

  @override
  Future<GiftCardProviderStatus> status(GiftCardOrder order) async => next;
}

class _Wallet implements GiftCardWallet {
  @override
  String? activeWalletId = 'w1';
  @override
  int proposalRevision = 0;
  int proposeExact = 62500000;
  Object? confirmError;
  SendBroadcast broadcast = SendBroadcast.accepted;
  int confirms = 0;
  @override
  Future<bool> isValidAddress(String address) async => address.startsWith('u1');
  @override
  Future<({int sendAmount, int fee, bool isExact})> proposeSend(
      String address, int zatoshis,
      {String? memo, bool priority = false}) async {
    proposalRevision++;
    return (sendAmount: proposeExact, fee: priority ? 100000 : 10000, isExact: true);
  }

  @override
  Future<SendOutcome> confirmSendDetailed(
      {required int expectedRevision,
      required String expectedWalletId,
      required bool expectedTestnet}) async {
    confirms++;
    if (expectedRevision != proposalRevision) throw StateError('stale');
    if (confirmError != null) throw confirmError!;
    return SendOutcome('txid1', broadcast);
  }
}

final _product = GiftCardProduct(
    id: 'p',
    name: 'Card',
    currency: 'USD',
    denominations: const RangeDenominations(min: 500, max: 50000, step: 100));

void main() {
  late _Provider provider;
  late _Wallet wallet;
  late GiftCardStore store;
  late GiftCardCheckout checkout;
  var now = DateTime.utc(2026, 11, 24, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    provider = _Provider();
    wallet = _Wallet();
    store = GiftCardStore(secrets: _Secrets());
    now = DateTime.utc(2026, 11, 24, 12);
    checkout = GiftCardCheckout(
        provider: provider, store: store, wallet: wallet, testnet: false, now: () => now);
  });

  test('rejects invalid amounts before contacting the provider', () async {
    await expectLater(checkout.createOrder(_product, const Fiat(550, 'USD'), walletId: 'w1'),
        throwsA(isA<GiftCardCheckoutException>()));
    await expectLater(checkout.createOrder(_product, const Fiat(2500, 'EUR'), walletId: 'w1'),
        throwsA(isA<GiftCardCheckoutException>()));
    expect(provider.created, 0);
  });

  test('full purchase: order saved before signing, then delivered with code', () async {
    final order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    expect((await store.orders()).single.status, GiftCardStatus.awaitingPayment);
    final proposal = await checkout.propose(order);
    expect(proposal.cost.totalZatoshis, 62510000);
    final paid = await checkout.pay(proposal);
    expect(paid.status, GiftCardStatus.paid);
    expect(paid.txid, 'txid1');
    expect(paid.networkFeeZatoshis, 10000);

    provider.next = const GiftCardProviderStatus(
        event: GiftCardEvent.delivered,
        redemption: GiftCardRedemption(code: 'ABC-123'));
    final done = await checkout.refresh(paid);
    expect(done.status, GiftCardStatus.delivered);
    expect(done.hasCode, isTrue);
    expect((await store.redemption(done))?.code, 'ABC-123');
  });

  test('a proposal replaced by another send cannot be signed', () async {
    final order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    final proposal = await checkout.propose(order);
    wallet.proposalRevision++;
    await expectLater(checkout.pay(proposal), throwsA(isA<GiftCardCheckoutException>()));
    expect(wallet.confirms, 0);
    expect((await store.orders()).single.status, GiftCardStatus.awaitingPayment);
  });

  test('an inexact proposal is refused', () async {
    final order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    wallet.proposeExact = 62400000;
    await expectLater(checkout.propose(order), throwsA(isA<GiftCardCheckoutException>()));
  });

  test('expired or wallet-switched orders are not payable', () async {
    final order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    final proposal = await checkout.propose(order);
    wallet.activeWalletId = 'w2';
    await expectLater(checkout.pay(proposal), throwsA(isA<GiftCardCheckoutException>()));
    wallet.activeWalletId = 'w1';
    now = DateTime.utc(2026, 11, 24, 12, 59, 30); // inside the 1-minute margin
    await expectLater(checkout.pay(proposal), throwsA(isA<GiftCardCheckoutException>()));
    expect(wallet.confirms, 0);
    now = DateTime.utc(2026, 11, 24, 13, 1);
    final refreshed = await checkout.refresh(order);
    expect(refreshed.status, GiftCardStatus.expired);
  });

  test('signing error leaves a not-paid order; uncertain needs support', () async {
    var order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    wallet.confirmError = StateError('insufficient');
    await expectLater(checkout.pay(await checkout.propose(order)), throwsStateError);
    expect((await store.find('fake', order.id))!.status, GiftCardStatus.cancelled);

    order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    wallet.confirmError = SendUncertainException();
    final result = await checkout.pay(await checkout.propose(order));
    expect(result.status, GiftCardStatus.needsSupport);
    expect(result.status.canPay, isFalse);
  });

  test('unreachable broadcast still counts as paid (sync resubmits)', () async {
    final order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    wallet.broadcast = SendBroadcast.unreachable;
    final paid = await checkout.pay(await checkout.propose(order));
    expect(paid.status, GiftCardStatus.paid);
  });

  test('stale provider status never moves an order backwards', () async {
    final order = await checkout.createOrder(_product, const Fiat(2500, 'USD'), walletId: 'w1');
    final paid = await checkout.pay(await checkout.propose(order));
    provider.next = const GiftCardProviderStatus(event: GiftCardEvent.approve);
    expect((await checkout.refresh(paid)).status, GiftCardStatus.paid);
    provider.next = const GiftCardProviderStatus(event: GiftCardEvent.expired);
    expect((await checkout.refresh(paid)).status, GiftCardStatus.needsSupport);
  });
}
