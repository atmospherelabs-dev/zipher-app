/// Real mainnet block heights by calendar month, for starting a restore from
/// a date the user remembers instead of a block height.
///
/// Each value is the height of the first block whose timestamp falls in that
/// UTC month, taken from verified canonical chain records (ZecBlock public
/// blocks dataset, retrieved 2026-11-23, indexed through 2026-11-23). These are
/// observed heights, not estimates from block spacing, so they stay correct
/// across upgrades that changed the block time (NU7 halved it in Nov 2026).
library;

/// First mainnet block of each UTC month since Sapling activation.
const Map<(int, int), int> mainnetMonthStarts = {
  (2018, 10): 419200,
  (2018, 11): 420880,
  (2018, 12): 438080,
  (2019, 1): 455853,
  (2019, 2): 473624,
  (2019, 3): 489671,
  (2019, 4): 507443,
  (2019, 5): 524660,
  (2019, 6): 542421,
  (2019, 7): 559618,
  (2019, 8): 577390,
  (2019, 9): 595174,
  (2019, 10): 612373,
  (2019, 11): 630136,
  (2019, 12): 647341,
  (2020, 1): 676616,
  (2020, 2): 712168,
  (2020, 3): 745412,
  (2020, 4): 780960,
  (2020, 5): 815361,
  (2020, 6): 850899,
  (2020, 7): 885293,
  (2020, 8): 920828,
  (2020, 9): 956365,
  (2020, 10): 990764,
  (2020, 11): 1026296,
  (2020, 12): 1060688,
  (2021, 1): 1096214,
  (2021, 2): 1131715,
  (2021, 3): 1163805,
  (2021, 4): 1199330,
  (2021, 5): 1233700,
  (2021, 6): 1269195,
  (2021, 7): 1303557,
  (2021, 8): 1339076,
  (2021, 9): 1374585,
  (2021, 10): 1408931,
  (2021, 11): 1444459,
  (2021, 12): 1478816,
  (2022, 1): 1514349,
  (2022, 2): 1549884,
  (2022, 3): 1581971,
  (2022, 4): 1617507,
  (2022, 5): 1651890,
  (2022, 6): 1687395,
  (2022, 7): 1721778,
  (2022, 8): 1757283,
  (2022, 9): 1792835,
  (2022, 10): 1827230,
  (2022, 11): 1862761,
  (2022, 12): 1897184,
  (2023, 1): 1932712,
  (2023, 2): 1968236,
  (2023, 3): 2000347,
  (2023, 4): 2035876,
  (2023, 5): 2070255,
  (2023, 6): 2105786,
  (2023, 7): 2140172,
  (2023, 8): 2175702,
  (2023, 9): 2211222,
  (2023, 10): 2245597,
  (2023, 11): 2281120,
  (2023, 12): 2315509,
  (2024, 1): 2351032,
  (2024, 2): 2386576,
  (2024, 3): 2419816,
  (2024, 4): 2455337,
  (2024, 5): 2489716,
  (2024, 6): 2525244,
  (2024, 7): 2559634,
  (2024, 8): 2595160,
  (2024, 9): 2630702,
  (2024, 10): 2665103,
  (2024, 11): 2700642,
  (2024, 12): 2735020,
  (2025, 1): 2770557,
  (2025, 2): 2806078,
  (2025, 3): 2838189,
  (2025, 4): 2873734,
  (2025, 5): 2908110,
  (2025, 6): 2943651,
  (2025, 7): 2978030,
  (2025, 8): 3013574,
  (2025, 9): 3049113,
  (2025, 10): 3083519,
  (2025, 11): 3119072,
  (2025, 12): 3153474,
  (2026, 1): 3189008,
  (2026, 2): 3224541,
  (2026, 3): 3256652,
  (2026, 4): 3292201,
  (2026, 5): 3326582,
  (2026, 6): 3362124,
  (2026, 7): 3396509,
  (2026, 8): 3432060,
  (2026, 9): 3467591,
  (2026, 10): 3501996,
  (2026, 11): 3537547,
};

/// The restore anchor (prior tree-state height) for a wallet first used at
/// [start], or null to scan full history.
///
/// To be safe against a misremembered date and timezone edges, scanning
/// starts at the beginning of the month BEFORE the chosen month: the anchor is
/// the last block before that month. A wallet first used in March 2025 is
/// scanned from 1 February 2025. Dates before the table, or on testnet, use
/// full history. Dates after the table use its last month.
int? restoreAnchorForDate(DateTime start, {bool testnet = false}) {
  if (testnet) return null;
  var year = start.year;
  var month = start.month - 1;
  if (month == 0) {
    month = 12;
    year -= 1;
  }
  final first = mainnetMonthStarts.keys.first;
  if (year < first.$1 || (year == first.$1 && month <= first.$2)) return null;
  final last = mainnetMonthStarts.keys.last;
  if (year > last.$1 || (year == last.$1 && month > last.$2)) {
    year = last.$1;
    month = last.$2;
  }
  final height = mainnetMonthStarts[(year, month)];
  return height == null ? null : height - 1;
}
