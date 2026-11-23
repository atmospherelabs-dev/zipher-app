import 'restore_checkpoints.dart';

/// Restore's existing integer API uses zero for a complete history recovery.
/// The Rust engine resolves that to the selected network's earliest supported
/// shielded chain state. It is distinct from new-wallet creation's tip default.
const fullHistoryRestoreBirthday = 0;

/// A selected date maps to a block height only through the observed mainnet
/// month table in `restore_checkpoints.dart` (real first-block heights, never
/// an estimate from block spacing), starting a full month before the chosen
/// month. Testnet, dates before the table, and no date use complete history.
/// An explicit block height always wins.
int restoreBirthdayFromInput({
  required String blockHeight,
  DateTime? selectedDate,
  bool testnet = false,
}) {
  final input = blockHeight.trim();
  if (input.isEmpty) {
    if (selectedDate == null) return fullHistoryRestoreBirthday;
    return restoreAnchorForDate(selectedDate, testnet: testnet) ??
        fullHistoryRestoreBirthday;
  }
  final height = int.tryParse(input);
  if (height == null || height <= 0 || height > 0xffffffff) {
    throw const FormatException('Enter a positive block height.');
  }
  // Preserve explicit heights; do not advance an older transparent-history
  // boundary to a shielded pool's activation height in Dart.
  return height;
}
