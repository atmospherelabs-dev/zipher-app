/// Restore's existing integer API uses zero for a complete history recovery.
/// The Rust engine resolves that to the selected network's earliest supported
/// shielded chain state. It is distinct from new-wallet creation's tip default.
const fullHistoryRestoreBirthday = 0;

/// A selected date is not a trusted block height. Target block spacing and a
/// wall-clock estimate cannot prove that scanning starts before a payment,
/// especially across network upgrades. Until an authoritative local date/height
/// mapping is available, dates use complete history instead of guessing.
int restoreBirthdayFromInput({
  required String blockHeight,
  DateTime? selectedDate,
}) {
  final input = blockHeight.trim();
  if (input.isEmpty) return fullHistoryRestoreBirthday;
  final height = int.tryParse(input);
  if (height == null || height <= 0 || height > 0xffffffff) {
    throw const FormatException('Enter a positive block height.');
  }
  // Preserve explicit heights; do not advance an older transparent-history
  // boundary to a shielded pool's activation height in Dart.
  return height;
}
