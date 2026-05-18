// Prediction-market venue model + Polymarket quality (single source: Rust engine via FRB).
//
// Use this module when adding venues (Kalshi, etc.): keep fetch/normalize/copy here
// and keep Action UI thin.
//
// Myriad (BSC) is hidden from the UI as of 2026-05 — liquidity was thin and the
// AMM UX did not land with users. The enum value, the Dart client, and the Rust
// engine module are still present for now so we don't break the build in one
// sitting; they're scheduled for full deletion in a focused follow-up PR.
// Anything user-facing should treat Polymarket as the only venue.

import 'dart:convert';

import '../src/rust/api/engine_api.dart' as rust_engine;

/// Venue for discovery/search and for trading-side actions (bet / portfolio / sell).
enum MarketVenue {
  /// User has not chosen yet — show picker (or auto-pick Polymarket since
  /// it's now the only venue).
  unset,

  /// Polymarket (Gamma + CLOB on Polygon, USDC).
  polymarket,

  /// Myriad on BSC (USDT). **Deprecated — hidden from UI.** Do not surface
  /// this in any picker / suggestion / chat branch. Scheduled for removal.
  myriad;

  bool get isChosen => this != MarketVenue.unset;

  String get label => switch (this) {
        MarketVenue.polymarket => 'Polymarket',
        MarketVenue.myriad => 'Myriad',
        MarketVenue.unset => '',
      };

  String get chainCollateralHint => switch (this) {
        MarketVenue.polymarket => 'Polygon / USDC',
        MarketVenue.myriad => 'BSC / USDT',
        MarketVenue.unset => '',
      };
}

/// Explicit flow state for prediction-market UX (replaces ad-hoc null flags).
///
/// - [discovery]: "find markets" / search — which API to query.
/// - [trading]: bet without id, portfolio, sell — which venue the user says they use.
class PredictionMarketFlowState {
  MarketVenue discovery = MarketVenue.unset;
  MarketVenue trading = MarketVenue.unset;

  void resetDiscovery() => discovery = MarketVenue.unset;

  void resetTrading() => trading = MarketVenue.unset;
}

// --- Polymarket quality (Rust = source of truth) ------------------------------

/// Same tradability rules as `zipher-cli polymarket list` / `polymarket_market_passes_quality`.
Future<bool> polymarketGammaMarketPassesQuality(Map<String, dynamic> raw, {bool relaxed = false}) async {
  try {
    return await rust_engine.enginePolymarketGammaMarketPassesQualityFilter(
      marketJson: jsonEncode(raw),
      relaxed: relaxed,
    );
  } catch (_) {
    return false;
  }
}
