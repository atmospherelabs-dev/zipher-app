import '../src/rust/api/engine_api.dart' as rust;
import 'app_log.dart';
import 'gift_links.dart';
import 'wallet_service.dart';

/// Thin bridge to the engine's gift functions. Links are bearer secrets and
/// are never passed to [AppLog].
class GiftEngine {
  GiftEngine._();
  static final instance = GiftEngine._();

  Future<rust.EngineGiftMint> mint(int amount, {String? message}) {
    AppLog.instance.event('gift', 'mint');
    return rust.engineGiftMint(
        amount: BigInt.from(amount),
        message: (message == null || message.trim().isEmpty) ? null : message.trim());
  }

  bool looksLikeLink(String text) =>
      looksLikeGiftLink(text) || rust.engineGiftLooksLikeLink(text: text);

  Future<rust.EngineGiftSummary> summary(String link) =>
      rust.engineGiftSummary(link: link);

  Future<String> open(String link) => rust.engineGiftOpen(link: link);

  /// Syncs the gift wallet (from its birthday) and prices a claim to
  /// [destination].
  Future<GiftBalance> check(String handle, {String? destination}) async {
    final s = await rust.engineGiftCheck(handle: handle, destination: destination);
    return GiftBalance(
        spendable: s.spendable.toInt(),
        pending: s.pending.toInt(),
        fee: s.fee.toInt(),
        redeemable: s.redeemable.toInt(),
        seenFunding: s.seenFunding);
  }

  /// A fresh shielded address of the open wallet to claim into.
  Future<String> claimAddress() => WalletService.instance.nextShieldedAddress();

  Future<rust.EngineGiftSweep> sweep(String handle, String destination) {
    AppLog.instance.event('gift', 'claim_submitted');
    return rust.engineGiftSweep(handle: handle, destination: destination);
  }

  Future<rust.EngineGiftSweep> resend(String handle) =>
      rust.engineGiftResend(handle: handle);

  Future<void> close(String handle) => rust.engineGiftClose(handle: handle);
}
