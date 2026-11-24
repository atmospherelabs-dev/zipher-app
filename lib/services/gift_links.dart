import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ZEC gift links (ZIP 324 "liberated payments"), interoperable with the
/// Zodl and Vizor formats.
///
/// A gift is a tiny wallet whose key travels in a link. The sender funds it
/// through the normal reviewed and authenticated send; whoever holds the link
/// sweeps it into a wallet of their own. Links are bearer secrets: they live
/// in the Keychain only and are never logged.
abstract final class GiftMath {
  static const zatoshisPerZec = 100000000;

  /// Funded on top of the face value so claiming costs the recipient nothing
  /// (the ZIP 317 fee of a one-note claim).
  static const claimFeeReserve = 10000;

  static const minGift = 100000; // 0.001 ZEC
  static const maxGift = 100 * zatoshisPerZec;
  static const maxMessageBytes = 512;
  static const maxMessageChars = 128;

  /// What the sender sends to the gift wallet.
  static int fundingAmount(int face) {
    if (face <= 0) throw ArgumentError('Gift amount must be positive');
    return face + claimFeeReserve;
  }

  /// The sender's total cost: funding plus the wallet's exact network fee.
  static int senderTotal(int face, int networkFee) =>
      fundingAmount(face) + networkFee;

  /// Exact decimal ZEC → zatoshis. Rejects more than 8 fraction digits.
  static int? parseZec(String input) {
    final t = input.trim();
    if (!RegExp(r'^\d+(\.\d{1,8})?$').hasMatch(t) &&
        !RegExp(r'^\.\d{1,8}$').hasMatch(t)) {
      return null;
    }
    final parts = (t.startsWith('.') ? '0$t' : t).split('.');
    if (parts[0].length > 9) return null;
    final whole = int.parse(parts[0]);
    final frac = parts.length == 2 ? int.parse(parts[1].padRight(8, '0')) : 0;
    return whole * zatoshisPerZec + frac;
  }

  static String formatZec(int zat) {
    final frac = (zat.abs() % zatoshisPerZec)
        .toString()
        .padLeft(8, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${zat < 0 ? '-' : ''}${zat.abs() ~/ zatoshisPerZec}'
        '${frac.isEmpty ? '' : '.$frac'}';
  }

  /// Why [face] cannot be gifted from [spendable] (both zatoshis), or null.
  /// The network fee is checked by the wallet's exact proposal.
  static String? reject(int? face, {int? spendable}) {
    if (face == null) return 'Enter an amount like 0.25.';
    if (face < minGift) return 'The smallest gift is 0.001 ZEC.';
    if (face > maxGift) return 'Gifts are limited to 100 ZEC.';
    if (spendable != null && fundingAmount(face) > spendable) {
      return 'That is more than your spendable balance.';
    }
    return null;
  }

  static String? rejectMessage(String? message) {
    if (message == null || message.trim().isEmpty) return null;
    if (message.characters > maxMessageChars ||
        utf8.encode(message).length > maxMessageBytes) {
      return 'Keep the message under $maxMessageChars characters.';
    }
    return null;
  }
}

extension on String {
  int get characters => runes.length;
}

// ---------------------------------------------------------------------------
// Sent gifts
// ---------------------------------------------------------------------------

enum SentGiftStatus {
  /// Minted and saved; nothing signed. Funding may be (re)tried.
  draft,

  /// Approved; the wallet is signing / broadcasting.
  funding,

  /// The funding transaction exists (sync resubmits it if needed).
  funded,

  /// The wallet stopped mid-send: a transaction may exist. Never re-fund.
  uncertain,

  /// A check found the gift empty after it was funded.
  claimed,

  /// The sender claimed it back into their own wallet.
  reclaimed,

  /// Abandoned before anything was sent.
  discarded,
}

enum SentGiftEvent { approve, notSent, broadcast, sendUncertain, foundEmpty, reclaimed, discard }

class IllegalGiftTransition implements Exception {
  IllegalGiftTransition(this.from, this.event);
  final Object from;
  final Object event;
  @override
  String toString() => 'Gift cannot ${(event as Enum).name} while ${(from as Enum).name}';
}

extension SentGiftStatusX on SentGiftStatus {
  bool get canFund => this == SentGiftStatus.draft;

  /// Money may have left the wallet for this gift.
  bool get mayBeFunded => const {
        SentGiftStatus.funding,
        SentGiftStatus.funded,
        SentGiftStatus.uncertain,
        SentGiftStatus.claimed,
        SentGiftStatus.reclaimed,
      }.contains(this);

  /// The link is worth sharing (and must not be lost).
  bool get shareable =>
      this == SentGiftStatus.funded || this == SentGiftStatus.uncertain;

  String get label => switch (this) {
        SentGiftStatus.draft => 'Not funded',
        SentGiftStatus.funding => 'Funding',
        SentGiftStatus.funded => 'Ready to claim',
        SentGiftStatus.uncertain => 'Check history',
        SentGiftStatus.claimed => 'Claimed',
        SentGiftStatus.reclaimed => 'Reclaimed',
        SentGiftStatus.discarded => 'Discarded',
      };
}

/// Pure transition table. Once funding may have happened, a gift can never
/// go back to a state that offers to fund it again.
SentGiftStatus nextSentGiftStatus(SentGiftStatus from, SentGiftEvent e) {
  final next = switch ((from, e)) {
    (SentGiftStatus.draft, SentGiftEvent.approve) => SentGiftStatus.funding,
    (SentGiftStatus.draft, SentGiftEvent.discard) => SentGiftStatus.discarded,
    // Nothing was created: the same draft (and link) may be funded again.
    (SentGiftStatus.funding, SentGiftEvent.notSent) => SentGiftStatus.draft,
    (SentGiftStatus.funding, SentGiftEvent.broadcast) => SentGiftStatus.funded,
    (SentGiftStatus.funding, SentGiftEvent.sendUncertain) =>
      SentGiftStatus.uncertain,
    (SentGiftStatus.funded || SentGiftStatus.uncertain,
        SentGiftEvent.foundEmpty) =>
      SentGiftStatus.claimed,
    (SentGiftStatus.funded || SentGiftStatus.uncertain || SentGiftStatus.claimed,
        SentGiftEvent.reclaimed) =>
      SentGiftStatus.reclaimed,
    (SentGiftStatus.claimed, SentGiftEvent.foundEmpty) => SentGiftStatus.claimed,
    _ => null,
  };
  if (next == null) throw IllegalGiftTransition(from, e);
  return next;
}

class SentGift {
  const SentGift({
    required this.id,
    required this.link,
    required this.fundingAddress,
    required this.amount,
    required this.birthday,
    required this.createdAt,
    required this.status,
    required this.testnet,
    this.message,
    this.networkFee,
    this.txid,
  });

  /// Stable id: the funding address (public; reveals nothing spendable).
  final String id;

  /// Bearer secret.
  final String link;
  final String fundingAddress;

  /// Face value in zatoshis: what the recipient receives.
  final int amount;
  final int birthday;
  final DateTime createdAt;
  final SentGiftStatus status;
  final bool testnet;
  final String? message;
  final int? networkFee;
  final String? txid;

  int get fundingAmount => GiftMath.fundingAmount(amount);

  SentGift apply(SentGiftEvent e, {String? txid, int? networkFee}) => SentGift(
        id: id,
        link: link,
        fundingAddress: fundingAddress,
        amount: amount,
        birthday: birthday,
        createdAt: createdAt,
        status: nextSentGiftStatus(status, e),
        testnet: testnet,
        message: message,
        networkFee: networkFee ?? this.networkFee,
        txid: txid ?? this.txid,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'link': link,
        'address': fundingAddress,
        'amount': amount,
        'birthday': birthday,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'status': status.name,
        'testnet': testnet,
        if (message != null) 'message': message,
        if (networkFee != null) 'fee': networkFee,
        if (txid != null) 'txid': txid,
      };

  static SentGift fromJson(Map<String, dynamic> j) => SentGift(
        id: j['id'] as String,
        link: j['link'] as String,
        fundingAddress: j['address'] as String,
        amount: j['amount'] as int,
        birthday: j['birthday'] as int,
        createdAt: DateTime.parse(j['createdAt'] as String),
        status: SentGiftStatus.values.byName(j['status'] as String),
        testnet: j['testnet'] as bool? ?? false,
        message: j['message'] as String?,
        networkFee: j['fee'] as int?,
        txid: j['txid'] as String?,
      );
}

abstract class GiftSecrets {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class KeychainGiftSecrets implements GiftSecrets {
  const KeychainGiftSecrets();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions:
        IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Sent gifts per wallet and network, entirely in the Keychain (each record
/// holds its link). Written before funding so a gift is never lost to a
/// crash between signing and saving.
class SentGiftStore {
  SentGiftStore({GiftSecrets? secrets})
      : _secrets = secrets ?? const KeychainGiftSecrets();
  static final instance = SentGiftStore();
  final GiftSecrets _secrets;

  static String _key(String walletId, bool testnet) =>
      'gift_links_v1_${walletId}_${testnet ? 'test' : 'main'}';

  Future<List<SentGift>> list(String walletId, bool testnet) async {
    final raw = await _secrets.read(_key(walletId, testnet));
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => SentGift.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> save(String walletId, SentGift gift) async {
    final all = await list(walletId, gift.testnet);
    all.removeWhere((g) => g.id == gift.id);
    all.add(gift);
    await _secrets.write(_key(walletId, gift.testnet),
        jsonEncode(all.map((g) => g.toJson()).toList()));
  }
}

// ---------------------------------------------------------------------------
// Claiming
// ---------------------------------------------------------------------------

/// What a synced gift holds (zatoshis), and what to tell the user.
class GiftBalance {
  const GiftBalance(
      {required this.spendable,
      required this.pending,
      required this.fee,
      required this.redeemable,
      this.seenFunding = false});
  final int spendable;
  /// The gift wallet saw its funding transaction.
  final bool seenFunding;
  final int pending;
  final int fee;
  final int redeemable;

  GiftClaimState get state {
    if (spendable > 0 && redeemable > 0) return GiftClaimState.ready;
    if (pending > 0) return GiftClaimState.pending;
    if (spendable > 0) return GiftClaimState.dust;
    return GiftClaimState.empty;
  }

  /// Funded once and now empty: someone claimed it.
  bool get claimed => seenFunding && spendable == 0 && pending == 0;
}

enum GiftClaimState {
  /// Link read, wallet not synced yet.
  unchecked,
  checking,
  ready,

  /// Funds found, waiting for confirmations (up to 10 for another wallet's
  /// funds, about 13 minutes).
  pending,

  /// Nothing found: already claimed, or the funding has not been mined yet.
  empty,

  /// Holds less than the fee a claim would cost.
  dust,
  claiming,

  /// A server accepted the claim.
  claimed,

  /// The claim transaction exists but no server confirmed it; resend only.
  unconfirmed,
  failed,
}

enum GiftClaimEvent { check, found, approve, accepted, unconfirmed, notSent, error }

/// Claim screen transitions. After [GiftClaimState.claiming] the only way
/// forward is a resend of the same transaction, never a new claim.
GiftClaimState nextClaimState(GiftClaimState from, GiftClaimEvent e,
    {GiftBalance? balance}) {
  const checkable = {
    GiftClaimState.unchecked,
    GiftClaimState.ready,
    GiftClaimState.pending,
    GiftClaimState.empty,
    GiftClaimState.dust,
    GiftClaimState.failed,
  };
  final next = switch ((from, e)) {
    (_, GiftClaimEvent.check) when checkable.contains(from) =>
      GiftClaimState.checking,
    (GiftClaimState.checking, GiftClaimEvent.found) when balance != null =>
      balance.state,
    (GiftClaimState.checking, GiftClaimEvent.error) => GiftClaimState.failed,
    (GiftClaimState.ready, GiftClaimEvent.approve) => GiftClaimState.claiming,
    (GiftClaimState.claiming, GiftClaimEvent.accepted) => GiftClaimState.claimed,
    (GiftClaimState.claiming, GiftClaimEvent.unconfirmed) =>
      GiftClaimState.unconfirmed,
    (GiftClaimState.claiming, GiftClaimEvent.notSent) => GiftClaimState.ready,
    (GiftClaimState.unconfirmed, GiftClaimEvent.accepted) =>
      GiftClaimState.claimed,
    (GiftClaimState.unconfirmed, GiftClaimEvent.unconfirmed) =>
      GiftClaimState.unconfirmed,
    _ => null,
  };
  if (next == null) throw IllegalGiftTransition(from, e);
  return next;
}

/// Cheap check before handing text to the engine parser (which validates).
/// Mirrors the engine's routing test so the scanner can decide synchronously.
bool looksLikeGiftLink(String text) {
  final t = text.trim();
  final hash = t.indexOf('#');
  if (hash < 0 || !t.toLowerCase().startsWith('https://')) return false;
  final fragment = t.substring(hash + 1);
  return (fragment.startsWith('v=1&') && fragment.contains('key=zgift')) ||
      (RegExp(r'^v[123]=').hasMatch(fragment) && t.contains('/payment-links/'));
}
