/// ParaSwap / Velora placeholder for the chain native asset (ETH, POL, BNB, …).
///
/// Used by [FundingResolver] when quoting same-chain native-to-ERC-20 swaps.
/// The actual swap execution happens in Rust (`zipher_engine::evm_swap`) via
/// `engineEvmSwapExecute`; this file holds only the shared constant so Dart
/// callers don't need to hard-code the magic address inline.
///
/// See https://developers.velora.xyz/api/velora-api/velora-market-api/get-rate-for-a-token-pair.md
const String paraswapNativeToken =
    '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';

/// Returns true if [tokenAddress] is the ParaSwap native-asset placeholder
/// (in any casing) or the zero address.
bool evmSwapIsNativeToken(String tokenAddress) {
  final a = tokenAddress.toLowerCase();
  return a == paraswapNativeToken.toLowerCase() ||
      a == '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ||
      a == '0x0000000000000000000000000000000000000000';
}
