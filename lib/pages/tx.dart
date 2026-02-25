import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../accounts.dart';
import '../zipher_theme.dart';
import '../generated/intl/messages.dart';
import '../services/near_intents.dart';
import '../store2.dart';
import '../tablelist.dart';
import 'utils.dart';

// ─── CipherScan tx cache (for shielding amounts) ────────────

const _csApi = 'https://api.mainnet.cipherscan.app/api';

/// Cached shielding amounts: txId → totalInput (in ZEC as double).
/// Populated lazily from CipherScan API.
final Map<String, double> _shieldAmountCache = {};

/// Fetch the totalInput for a shielding tx from CipherScan.
/// Returns cached value immediately if available, otherwise fetches
/// and calls [onLoaded] when done.
double? getShieldAmount(String txId, {VoidCallback? onLoaded}) {
  if (_shieldAmountCache.containsKey(txId)) return _shieldAmountCache[txId];
  // Fire async fetch
  _fetchShieldAmount(txId, onLoaded);
  return null;
}

Future<void> _fetchShieldAmount(String txId, VoidCallback? onLoaded) async {
  try {
    final resp = await http.get(Uri.parse('$_csApi/tx/$txId'));
    if (resp.statusCode == 200) {
      final json = jsonDecode(resp.body);
      final totalInput = (json['totalInput'] as num?)?.toDouble();
      if (totalInput != null) {
        _shieldAmountCache[txId] = totalInput;
        onLoaded?.call();
      }
    }
  } catch (e) {
    logger.e('[Activity] Shield amount fetch error: $e');
  }
}

// ─── Helpers ────────────────────────────────────────────────

const _cipherScanBase = 'https://cipherscan.app';

void _openOnCipherScan(String txId) {
  launchUrl(
    Uri.parse('$_cipherScanBase/tx/$txId'),
    mode: LaunchMode.externalApplication,
  );
}

String _fiatStr(double zecValue) {
  final price = marketPrice.price;
  if (price == null) return '';
  final fiat = zecValue.abs() * price;
  return '\$${fiat.toStringAsFixed(2)}';
}

/// Human-readable date like "Dec 5 at 12:49 AM" or "Yesterday"
String _humanDate(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final txDay = DateTime(local.year, local.month, local.day);
  final timeFmt = DateFormat.jm(); // "12:49 AM"

  if (txDay == today) {
    return 'Today at ${timeFmt.format(local)}';
  } else if (txDay == yesterday) {
    return 'Yesterday at ${timeFmt.format(local)}';
  } else if (local.year == now.year) {
    return '${DateFormat.MMMd().format(local)} at ${timeFmt.format(local)}';
  } else {
    return '${DateFormat.yMMMd().format(local)} at ${timeFmt.format(local)}';
  }
}

/// Month group header: "February 2026", "December 2025", etc.
String _monthGroup(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final txDay = DateTime(local.year, local.month, local.day);

  if (txDay == today) return 'Today';
  if (txDay == yesterday) return 'Yesterday';
  return DateFormat.yMMMM().format(local); // "December 2025"
}

// ─── Privacy classification ─────────────────────────────────

enum _TxPrivacy { private, transparent, mixed }

_TxPrivacy _classifyTx(Tx tx) {
  final hasMemo = tx.memo?.isNotEmpty == true || tx.memos.isNotEmpty;
  final addr = tx.address ?? '';
  final isTransparentAddr = addr.startsWith('t');

  if (isTransparentAddr && !hasMemo) return _TxPrivacy.transparent;
  if (!isTransparentAddr && hasMemo) return _TxPrivacy.private;
  if (isTransparentAddr && hasMemo) return _TxPrivacy.mixed;
  return _TxPrivacy.private;
}

String _privacyLabel(_TxPrivacy p) {
  switch (p) {
    case _TxPrivacy.private:
      return 'Private';
    case _TxPrivacy.transparent:
      return 'Transparent';
    case _TxPrivacy.mixed:
      return 'Mixed';
  }
}

Color _privacyColor(_TxPrivacy p) {
  switch (p) {
    case _TxPrivacy.private:
      return ZipherColors.purple;
    case _TxPrivacy.transparent:
      return ZipherColors.cyan;
    case _TxPrivacy.mixed:
      return ZipherColors.orange;
  }
}

IconData _privacyIcon(_TxPrivacy p) {
  switch (p) {
    case _TxPrivacy.private:
      return Icons.shield_rounded;
    case _TxPrivacy.transparent:
      return Icons.visibility_outlined;
    case _TxPrivacy.mixed:
      return Icons.swap_vert_rounded;
  }
}

// ─── Invoice detection ──────────────────────────────────────

class _InvoiceData {
  final String reference;
  final String description;
  _InvoiceData({required this.reference, required this.description});
}

_InvoiceData? _parseInvoice(String? memo) {
  if (memo == null || memo.isEmpty) return null;
  final pattern = RegExp(r'^\[zipher:inv:([^\]]+)\]\s*(.*)$', dotAll: true);
  final match = pattern.firstMatch(memo);
  if (match == null) return null;
  return _InvoiceData(
    reference: match.group(1)!.trim(),
    description: match.group(2)?.trim() ?? '',
  );
}

/// Detect shielding: self-transfer with no destination address,
/// or our auto-shield memo pattern
bool _isShielding(Tx tx) =>
    (tx.value <= 0 && (tx.address == null || tx.address!.isEmpty)) ||
    (tx.memo?.contains('Auto-shield') ?? false);

/// Subtitle parts for activity row: (prefix, value, shouldColorValue)
({String prefix, String value, bool colorValue}) _txSubtitleParts(
    Tx tx, bool isReceive, _TxPrivacy privacy) {
  if (_isShielding(tx)) {
    return (prefix: '', value: 'Transparent → Private', colorValue: true);
  }
  final addr = tx.address ?? '';
  if (isReceive) {
    if (addr.isEmpty || !addr.startsWith('t')) {
      return (prefix: 'From: ', value: 'Private', colorValue: true);
    }
    return (
      prefix: 'From: ',
      value: centerTrim(addr, length: 16),
      colorValue: false
    );
  } else {
    if (addr.isEmpty) {
      return (prefix: 'To: ', value: _privacyLabel(privacy), colorValue: true);
    }
    return (
      prefix: 'To: ',
      value: tx.contact ?? centerTrim(addr, length: 16),
      colorValue: false
    );
  }
}

// ─── Activity page ──────────────────────────────────────────

class TxPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => TxPageState();
}

class _TxSwapEntry {
  final StoredSwap swap;
  NearSwapStatus? status;
  _TxSwapEntry(this.swap, [this.status]);
}

class TxPageState extends State<TxPage> {
  Map<String, _TxSwapEntry> _swapsByDepositAddr = {};
  Timer? _swapPollTimer;
  final _nearApi = NearIntentsService();
  int _lastTxCount = -1;

  @override
  void initState() {
    super.initState();
    _loadSwapsAndPoll();
    syncStatus2.latestHeight?.let((height) {
      Future(() async {
        final txListUpdated =
            await WarpApi.transparentSync(aa.coin, aa.id, height);
        if (txListUpdated) aa.update(height);
      });
    });
  }

  @override
  void dispose() {
    _swapPollTimer?.cancel();
    super.dispose();
  }

  void _reloadSwapsIfNeeded(int currentTxCount) {
    if (currentTxCount != _lastTxCount) {
      _lastTxCount = currentTxCount;
      _loadSwapsAndPoll();
    }
  }

  void _loadSwapsAndPoll() async {
    try {
      final lookupMap = await SwapStore.loadLookupMap();
      _swapsByDepositAddr = lookupMap.map((k, v) => MapEntry(k, _TxSwapEntry(v)));
      _swapPollTimer?.cancel();
      final depositKeys = _swapsByDepositAddr.entries
          .where((e) => e.key == e.value.swap.depositAddress)
          .toList();
      if (depositKeys.isNotEmpty) {
        _pollSwapStatuses();
        _swapPollTimer = Timer.periodic(
          const Duration(seconds: 15), (_) => _pollSwapStatuses(),
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      logger.e('[Activity] Error loading swap data: $e');
    }
  }

  Future<void> _pollSwapStatuses() async {
    final depositEntries = _swapsByDepositAddr.entries
        .where((e) => e.key == e.value.swap.depositAddress)
        .toList();
    for (final entry in depositEntries) {
      if (entry.value.status != null && entry.value.status!.isTerminal) continue;
      if (entry.value.swap.provider != 'near_intents') continue;
      try {
        final status = await _nearApi.getStatus(entry.key);
        if (mounted) {
          setState(() {
            for (final e in _swapsByDepositAddr.values) {
              if (e.swap.depositAddress == entry.value.swap.depositAddress) {
                e.status = status;
              }
            }
          });
          if (depositEntries
              .where((e) => e.value.swap.provider == 'near_intents')
              .every((e) => e.value.status?.isTerminal == true)) {
            _swapPollTimer?.cancel();
          }
        }
      } catch (e) {
        logger.e('[Activity] Swap status poll error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SortSetting(
        child: Observer(
          builder: (context) {
            aaSequence.seqno;
            aaSequence.settingsSeqno;
            syncStatus2.changed;
            final txs = aa.txs.items;
            _reloadSwapsIfNeeded(txs.length);

            if (txs.isEmpty) return _EmptyActivity(topPad: topPad);

            // Group txs by month
            final groups = <String, List<_IndexedTx>>{};
            for (var i = 0; i < txs.length; i++) {
              final key = _monthGroup(txs[i].timestamp);
              groups.putIfAbsent(key, () => []);
              groups[key]!.add(_IndexedTx(i, txs[i]));
            }

            return ListView.builder(
              padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, 24),
              itemCount: _countItems(groups) + 1, // +1 for header
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 20, 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.arrow_back_rounded,
                              color: ZipherColors.text60),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        Text(
                          'Activity',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: ZipherColors.text90,
                            ),
                        ),
                      ],
                    ),
                  );
                }
                return _buildGroupedItem(context, groups, i - 1);
              },
            );
          },
        ),
      ),
    );
  }

  int _countItems(Map<String, List<_IndexedTx>> groups) {
    int count = 0;
    for (final g in groups.values) {
      count += 1 + g.length; // header + items
    }
    return count;
  }

  Widget _buildGroupedItem(
      BuildContext context, Map<String, List<_IndexedTx>> groups, int index) {
    int cursor = 0;
    for (final entry in groups.entries) {
      if (index == cursor) {
        // Month header
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Text(
            entry.key,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: ZipherColors.text40,
              letterSpacing: 0.3,
            ),
          ),
        );
      }
      cursor++;
      if (index < cursor + entry.value.length) {
        final itx = entry.value[index - cursor];
        ZMessage? message;
        try {
          message =
              aa.messages.items.firstWhere((m) => m.txId == itx.tx.id);
        } on StateError {
          message = null;
        }
        final swapEntry = _swapsByDepositAddr[itx.tx.address]
            ?? _swapsByDepositAddr[itx.tx.fullTxId]
            ?? _swapsByDepositAddr[itx.tx.txId];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _TxRow(tx: itx.tx, message: message, index: itx.index,
              swapInfo: swapEntry?.swap, swapStatus: swapEntry?.status),
        );
      }
      cursor += entry.value.length;
    }
    return const SizedBox.shrink();
  }
}

class _IndexedTx {
  final int index;
  final Tx tx;
  _IndexedTx(this.index, this.tx);
}

// ─── Empty state ────────────────────────────────────────────

class _EmptyActivity extends StatelessWidget {
  final double topPad;
  const _EmptyActivity({this.topPad = 0});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(8, topPad + 8, 20, 0),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back_rounded,
                    color: ZipherColors.text60),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Text(
                'Activity',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: ZipherColors.text90,
                            ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: ZipherColors.cardBg,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.receipt_long_outlined,
                size: 28,
                color: ZipherColors.text10,
              ),
            ),
            const Gap(16),
            Text(
              'No activity yet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: ZipherColors.text60,
              ),
            ),
            const Gap(6),
            Text(
              'Your transactions will appear here',
              style: TextStyle(
                fontSize: 13,
                color: ZipherColors.text20,
              ),
            ),
          ],
        ),
      ),
    ),
        ),
      ],
    );
  }
}

// ─── Transaction row (Zashi-inspired) ───────────────────────

class _TxRow extends StatefulWidget {
  final Tx tx;
  final ZMessage? message;
  final int index;
  final StoredSwap? swapInfo;
  final NearSwapStatus? swapStatus;

  const _TxRow(
      {required this.tx, required this.message, required this.index,
       this.swapInfo, this.swapStatus});

  @override
  State<_TxRow> createState() => _TxRowState();
}

class _TxRowState extends State<_TxRow> {
  Tx get tx => widget.tx;
  int get index => widget.index;
  StoredSwap? get swapInfo => widget.swapInfo;
  NearSwapStatus? get swapStatus => widget.swapStatus;

  @override
  Widget build(BuildContext context) {
    final isReceive = tx.value > 0;
    final privacy = _classifyTx(tx);
    final isSwapDeposit = swapInfo != null && !isReceive;

    // Label: "Received", "Sent", "Shielded" (for self-transfers)
    final bool isShielding = !isSwapDeposit && _isShielding(tx);
    final memo = tx.memo ?? '';
    final bool isMessage = !isSwapDeposit &&
        (memo.startsWith('\u{1F6E1}') ||
        memo.startsWith('🛡') ||
        (!isReceive && getOutgoingMemo(tx.fullTxId) != null));

    final String label;
    final String? swapStatusLabel;
    if (isSwapDeposit) {
      label = 'Swap → ${swapInfo!.toCurrency}';
      if (swapStatus == null || swapStatus!.isPending) {
        swapStatusLabel = 'Pending';
      } else if (swapStatus!.isProcessing) {
        swapStatusLabel = 'Processing';
      } else if (swapStatus!.isSuccess) {
        swapStatusLabel = 'Completed';
      } else if (swapStatus!.isFailed) {
        swapStatusLabel = 'Failed';
      } else if (swapStatus!.isRefunded) {
        swapStatusLabel = 'Refunded';
      } else {
        swapStatusLabel = swapStatus!.status;
      }
    } else if (isShielding) {
      label = 'Shielded';
      swapStatusLabel = null;
    } else if (isMessage) {
      label = isReceive ? 'Message received' : 'Message sent';
      swapStatusLabel = null;
    } else if (isReceive) {
      label = 'Received';
      swapStatusLabel = null;
    } else {
      label = 'Sent';
      swapStatusLabel = null;
    }

    final dateStr = _humanDate(tx.timestamp);
    double? shieldedAmount;
    if (isShielding) {
      final match = RegExp(r'Auto-shield ([\d.,]+) ZEC').firstMatch(memo);
      if (match != null) {
        shieldedAmount = double.tryParse(match.group(1)!.replaceAll(',', '.'));
      }
      shieldedAmount ??= getShieldAmount(tx.fullTxId,
          onLoaded: () { if (mounted) setState(() {}); });
    }

    final String amountStr;
    if (isSwapDeposit) {
      amountStr = '${swapInfo!.toAmount} ${swapInfo!.toCurrency}';
    } else if (isShielding && shieldedAmount != null) {
      amountStr = '${decimalToString(shieldedAmount)} ZEC';
    } else if (isShielding) {
      amountStr = '···';
    } else {
      amountStr = '${isReceive ? '+' : ''}${decimalToString(tx.value)} ZEC';
    }

    final amountColor = isReceive
        ? ZipherColors.green
        : isSwapDeposit
            ? ZipherColors.cyan.withValues(alpha: 0.8)
            : isShielding
                ? ZipherColors.purple.withValues(alpha: 0.7)
                : ZipherColors.red;

    final fiatValue = isShielding && shieldedAmount != null
        ? shieldedAmount
        : tx.value.abs();
    final fiat = isSwapDeposit ? '' : _fiatStr(fiatValue);

    // For message transactions, extract a clean memo preview
    final String? memoPreview;
    if (isMessage) {
      final outgoing = getOutgoingMemo(tx.fullTxId);
      final raw = memo.isNotEmpty ? memo : (outgoing ?? '');
      final parsed = parseMemoBody(raw);
      memoPreview = parsed.isNotEmpty ? parsed : null;
    } else {
      memoPreview = null;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: GestureDetector(
        onTap: () {
          if (isSwapDeposit && swapInfo!.provider == 'near_intents') {
            GoRouter.of(context).push('/swap/status', extra: {
              'depositAddress': swapInfo!.depositAddress,
              'fromCurrency': swapInfo!.fromCurrency,
              'fromAmount': swapInfo!.fromAmount,
              'toCurrency': swapInfo!.toCurrency,
              'toAmount': swapInfo!.toAmount,
            });
          } else {
            gotoTx(context, index);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ZipherColors.borderSubtle),
          ),
          foregroundDecoration: isMessage
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border(
                    left: BorderSide(
                      width: 2.5,
                      color: ZipherColors.purple.withValues(alpha: 0.4),
                    ),
                  ),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top line: direction badge + date
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: isSwapDeposit
                          ? ZipherColors.cyan.withValues(alpha: 0.10)
                          : isShielding
                              ? ZipherColors.purple.withValues(alpha: 0.10)
                              : isMessage
                                  ? ZipherColors.purple.withValues(alpha: 0.08)
                                  : ZipherColors.cardBgElevated,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSwapDeposit
                              ? Icons.swap_horiz_rounded
                              : isShielding
                                  ? Icons.shield_rounded
                                  : isMessage
                                      ? (isReceive
                                          ? Icons.chat_bubble_rounded
                                          : Icons.send_rounded)
                                      : isReceive
                                          ? Icons.south_west_rounded
                                          : Icons.north_east_rounded,
                          size: 10,
                          color: isSwapDeposit
                              ? ZipherColors.cyan.withValues(alpha: 0.7)
                              : (isShielding || isMessage)
                                  ? ZipherColors.purple.withValues(alpha: 0.7)
                                  : ZipherColors.text60,
                        ),
                        const Gap(3),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isSwapDeposit
                                ? ZipherColors.cyan.withValues(alpha: 0.7)
                                : (isShielding || isMessage)
                                    ? ZipherColors.purple.withValues(alpha: 0.7)
                                    : ZipherColors.text60,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSwapDeposit && swapStatusLabel != null) ...[
                    const Gap(6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (swapStatus?.isSuccess == true)
                            ? ZipherColors.green.withValues(alpha: 0.10)
                            : (swapStatus?.isFailed == true || swapStatus?.isRefunded == true)
                                ? ZipherColors.red.withValues(alpha: 0.10)
                                : ZipherColors.orange.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 5, height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: (swapStatus?.isSuccess == true)
                                  ? ZipherColors.green
                                  : (swapStatus?.isFailed == true || swapStatus?.isRefunded == true)
                                      ? ZipherColors.red
                                      : ZipherColors.orange,
                            ),
                          ),
                          const Gap(4),
                          Text(
                            swapStatusLabel!,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: (swapStatus?.isSuccess == true)
                                  ? ZipherColors.green.withValues(alpha: 0.8)
                                  : (swapStatus?.isFailed == true || swapStatus?.isRefunded == true)
                                      ? ZipherColors.red.withValues(alpha: 0.8)
                                      : ZipherColors.orange.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    dateStr,
                    style: TextStyle(
                      fontSize: 11,
                      color: ZipherColors.text20,
                    ),
                  ),
                ],
              ),
              const Gap(10),
              // Bottom line: logo + primary/subtitle → amount + fiat
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ZEC logo for standard transactions only
                  if (!isMessage) ...[
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: ZipherColors.cardBgElevated,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Image.asset(
                          'assets/zcash_logo.png',
                          width: 28,
                          height: 28,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const Gap(10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Primary text: memo preview for messages, "ZEC" otherwise
                        Text(
                          (isMessage && memoPreview != null)
                              ? memoPreview
                              : 'ZEC',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: ZipherColors.text90,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const Gap(2),
                        // Subtitle: privacy info (messages already labeled in the badge)
                        Builder(builder: (context) {
                          final sub =
                              _txSubtitleParts(tx, isReceive, privacy);
                          final mutedStyle = TextStyle(
                            fontSize: 12,
                            color: ZipherColors.text40,
                          );
                          return RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              children: [
                                if (sub.prefix.isNotEmpty)
                                  TextSpan(
                                      text: sub.prefix, style: mutedStyle),
                                TextSpan(
                                  text: sub.value,
                                  style: sub.colorValue
                                      ? TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: _privacyColor(privacy)
                                              .withValues(alpha: 0.6),
                                        )
                                      : mutedStyle,
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  const Gap(10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        amountStr,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: amountColor,
                        ),
                      ),
                      if (fiat.isNotEmpty) ...[
                        const Gap(2),
                        Text(
                          fiat,
                          style: TextStyle(
                            fontSize: 12,
                            color: ZipherColors.text20,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── TableList metadata (kept for data table view) ──────────

class TableListTxMetadata extends TableListItemMetadata<Tx> {
  @override
  List<Widget>? actions(BuildContext context) => null;

  @override
  Text? headerText(BuildContext context) => null;

  @override
  void inverseSelection() {}

  @override
  Widget toListTile(BuildContext context, int index, Tx tx,
      {void Function(void Function())? setState}) {
    ZMessage? message;
    try {
      message = aa.messages.items.firstWhere((m) => m.txId == tx.id);
    } on StateError {
      message = null;
    }
    return _TxRow(tx: tx, message: message, index: index);
  }

  @override
  List<ColumnDefinition> columns(BuildContext context) {
    final s = S.of(context);
    return [
      ColumnDefinition(field: 'height', label: s.height, numeric: true),
      ColumnDefinition(
          field: 'confirmations', label: s.confs, numeric: true),
      ColumnDefinition(field: 'timestamp', label: s.datetime),
      ColumnDefinition(field: 'value', label: s.amount),
      ColumnDefinition(field: 'fullTxId', label: s.txID),
      ColumnDefinition(field: 'address', label: s.address),
      ColumnDefinition(field: 'memo', label: s.memo),
    ];
  }

  @override
  DataRow toRow(BuildContext context, int index, Tx tx) {
    final t = Theme.of(context);
    final color = amountColor(context, tx.value);
    var style = t.textTheme.bodyMedium!.copyWith(color: color);
    style = weightFromAmount(style, tx.value);
    final a = tx.contact ?? centerTrim(tx.address ?? '');
    final m = tx.memo?.let((m) => m.substring(0, min(m.length, 32))) ?? '';

    return DataRow.byIndex(
        index: index,
        cells: [
          DataCell(Text("${tx.height}")),
          DataCell(Text("${tx.confirmations}")),
          DataCell(Text("${txDateFormat.format(tx.timestamp)}")),
          DataCell(Text(decimalToString(tx.value),
              style: style, textAlign: TextAlign.left)),
          DataCell(Text("${tx.txId}")),
          DataCell(Text("$a")),
          DataCell(Text("$m")),
        ],
        onSelectChanged: (_) => gotoTx(context, index));
  }

  @override
  SortConfig2? sortBy(String field) {
    aa.txs.setSortOrder(field);
    return aa.txs.order;
  }

  @override
  Widget? header(BuildContext context) => null;
}

// ─── Transaction detail page ────────────────────────────────

class TransactionPage extends StatefulWidget {
  final int txIndex;
  TransactionPage(this.txIndex);

  @override
  State<StatefulWidget> createState() => TransactionState();
}

class TransactionState extends State<TransactionPage> {
  late final s = S.of(context);
  late int idx;

  @override
  void initState() {
    super.initState();
    idx = widget.txIndex;
  }

  Tx get tx => aa.txs.items[idx];

  /// Look up the matching ZMessage for this tx (if any).
  /// The messages table has no foreign key to transactions, so we match
  /// by block height + direction.  If multiple messages share the same
  /// height we pick the one whose direction matches.
  ZMessage? get _linkedMessage {
    final isReceive = tx.value > 0;
    final candidates = aa.messages.items
        .where((m) => m.height == tx.height && m.incoming == isReceive)
        .toList();
    if (candidates.length == 1) return candidates.first;
    if (candidates.isNotEmpty) return candidates.first;
    // Fallback: try matching by height alone (ignore direction)
    final byHeight =
        aa.messages.items.where((m) => m.height == tx.height).toList();
    if (byHeight.length == 1) return byHeight.first;
    if (byHeight.isNotEmpty) return byHeight.first;
    return null;
  }

  /// Effective memo: prefer tx.memo, then linked ZMessage body,
  /// then our local outgoing memo cache.
  String? get _effectiveMemo {
    if (tx.memo != null && tx.memo!.isNotEmpty) return tx.memo;
    final msgBody = _linkedMessage?.body;
    if (msgBody != null && msgBody.isNotEmpty) return msgBody;
    return getOutgoingMemo(tx.fullTxId);
  }

  @override
  Widget build(BuildContext context) {
    final isReceive = tx.value > 0;
    final isSelfTransfer = _isShielding(tx);
    final privacy = _classifyTx(tx);
    final pColor = _privacyColor(privacy);
    final invoice = _parseInvoice(_effectiveMemo);

    // For shielding, try memo first, then CipherScan as fallback
    final memo = tx.memo ?? '';
    double? shieldedAmount;
    if (isSelfTransfer) {
      final match = RegExp(r'Auto-shield ([\d.,]+) ZEC').firstMatch(memo);
      if (match != null) {
        shieldedAmount = double.tryParse(match.group(1)!.replaceAll(',', '.'));
      }
      shieldedAmount ??= getShieldAmount(tx.fullTxId,
          onLoaded: () { if (mounted) setState(() {}); });
    }
    final displayValue = isSelfTransfer && shieldedAmount != null
        ? shieldedAmount
        : tx.value.abs();
    final fiat = _fiatStr(displayValue);

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        leading: IconButton(
          onPressed: () => GoRouter.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded, size: 22, color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(20),

              // ── Hero: Jupiter-inspired logo + arrow badge ──
              Center(
                child: Column(
                  children: [
                    // Zcash logo with direction arrow badge
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Main Zcash logo in circle
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: ZipherColors.cardBgElevated,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Image.asset(
                                'assets/zcash_logo.png',
                                width: 48,
                                height: 48,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          // Direction arrow badge (bottom-right)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: isSelfTransfer
                                    ? ZipherColors.purple
                                    : ZipherColors.cyan,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: ZipherColors.bg,
                                  width: 2.5,
                                ),
                              ),
                              child: Icon(
                                isSelfTransfer
                                    ? Icons.shield_rounded
                                    : isReceive
                                        ? Icons.south_west_rounded
                                        : Icons.north_east_rounded,
                                size: 13,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Gap(20),

                    // "You Received" / "You Sent" label
                    Text(
                      isSelfTransfer
                          ? 'You Shielded'
                          : isReceive
                              ? 'You Received'
                              : 'You Sent',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: ZipherColors.text40,
                      ),
                    ),

                    const Gap(10),

                    // Amount — always white on detail page
                    Text(
                      '${decimalToString(displayValue)} ZEC',
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),

                    // USD equivalent — subtle pill
                    if (fiat.isNotEmpty) ...[
                      const Gap(8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: ZipherColors.cardBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          fiat,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: ZipherColors.text40,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const Gap(28),

              // ── Memo / Message section ──
              if (invoice != null) ...[
                _SectionHeader(label: 'Invoice'),
                const Gap(8),
                _InvoiceCard(invoice: invoice),
                const Gap(20),
              ] else if ((_effectiveMemo?.isNotEmpty ?? false) &&
                  !(_effectiveMemo!.contains('Auto-shield'))) ...[
                _SectionHeader(label: 'Message'),
                const Gap(8),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    parseMemoBody(_effectiveMemo!),
                    style: TextStyle(
                      fontSize: 14,
                      color: ZipherColors.text60,
                      height: 1.5,
                    ),
                  ),
                ),
                const Gap(20),
              ],

              // ── Transaction Details (always visible) ──
              _SectionHeader(label: 'Transaction Details'),
              const Gap(8),
              _buildDetails(isReceive, privacy, pColor),

              // Additional memos
              ..._memos(),

              const Gap(24),

              // ── View on CipherScan ──
              SizedBox(
                width: double.infinity,
                child: _BottomAction(
                  label: 'View on CipherScan',
                  icon: Icons.open_in_new_rounded,
                  onTap: () => _openOnCipherScan(tx.fullTxId),
                ),
              ),

              const Gap(32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(
      bool isReceive, _TxPrivacy privacy, Color _) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          if (tx.confirmations != null) ...[
            _DetailRow(
              label: 'Status',
              child: Text(
                tx.confirmations! >= 10
                    ? 'Confirmed'
                    : '${tx.confirmations} confirmations',
                style: TextStyle(
                  fontSize: 13,
                  color: tx.confirmations! >= 10
                      ? ZipherColors.green.withValues(alpha: 0.8)
                      : ZipherColors.orange.withValues(alpha: 0.8),
                ),
              ),
            ),
            _detailDivider(),
          ],

          // From / Sent to — show "Private" for shielded, address for transparent
          Builder(builder: (context) {
            final isSelf = _isShielding(tx);
            final addr = tx.address ?? '';
            final bool isShieldedReceive =
                isReceive && (addr.isEmpty || !addr.startsWith('t'));

            return Column(
              children: [
                _DetailRow(
                  label: isSelf ? 'To' : (isReceive ? 'From' : 'Sent to'),
                  child: isSelf
                      ? Text(
                          'Your shielded wallet',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: ZipherColors.purple.withValues(alpha: 0.8),
                          ),
                        )
                      : isShieldedReceive
                      ? Text(
                          'Private',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: ZipherColors.purple.withValues(alpha: 0.8),
                          ),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                isReceive
                                    ? centerTrim(addr)
                                    : (tx.contact ?? centerTrim(addr)),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: ZipherColors.text60,
                                ),
                              ),
                            ),
                            if (addr.isNotEmpty) ...[
                              const Gap(6),
                              GestureDetector(
                                onTap: () {
                                  Clipboard.setData(
                                      ClipboardData(text: addr));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Address copied'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                },
                                child: Icon(Icons.copy_rounded,
                                    size: 13,
                                    color:
                                        ZipherColors.text20),
                              ),
                            ],
                          ],
                        ),
                ),
                _detailDivider(),
              ],
            );
          }),

          _DetailRow(
            label: 'Transaction ID',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    centerTrim(tx.fullTxId, length: 16),
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: ZipherColors.text60,
                    ),
                  ),
                ),
                const Gap(6),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(
                        ClipboardData(text: tx.fullTxId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('TX ID copied'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Icon(Icons.copy_rounded,
                      size: 13,
                      color: ZipherColors.text20),
                ),
              ],
            ),
          ),
          _detailDivider(),

          _DetailRow(
            label: 'Timestamp',
            child: Text(
              _humanDate(tx.timestamp),
              style: TextStyle(
                fontSize: 13,
                                  color: ZipherColors.text60,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailDivider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Divider(
            height: 1, color: ZipherColors.cardBg),
      );

  List<Widget> _memos() {
    List<Widget> ms = [];
    for (var txm in tx.memos) {
      ms.add(const Gap(8));
      ms.add(Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              centerTrim(txm.address),
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: ZipherColors.text20,
              ),
            ),
            const Gap(4),
            Text(
              parseMemoBody(txm.memo),
              style: TextStyle(
                fontSize: 14,
                color: ZipherColors.text60,
                height: 1.4,
              ),
            ),
          ],
        ),
      ));
    }
    return ms;
  }
}

// ─── Shared widgets ─────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: ZipherColors.text40,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final Widget child;

  const _DetailRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: ZipherColors.text40,
            ),
          ),
          const Spacer(),
          child,
        ],
      ),
    );
  }
}

class _BottomAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _BottomAction(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: ZipherColors.cyan.withValues(alpha: 0.7)),
              const Gap(8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.cyan.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvoiceCard extends StatelessWidget {
  final _InvoiceData invoice;
  const _InvoiceCard({required this.invoice});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZipherColors.purple.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: ZipherColors.purple.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: ZipherColors.purple.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(Icons.receipt_outlined,
                size: 15,
                color: ZipherColors.purple.withValues(alpha: 0.8)),
          ),
          const Gap(10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Invoice',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ZipherColors.purple.withValues(alpha: 0.7),
                      ),
                    ),
                    const Gap(6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: ZipherColors.purple.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '#${invoice.reference}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'monospace',
                          color: ZipherColors.purple
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ],
                ),
                if (invoice.description.isNotEmpty) ...[
                  const Gap(2),
                  Text(
                    invoice.description,
                    style: TextStyle(
                      fontSize: 12,
                      color: ZipherColors.text60,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void gotoTx(BuildContext context, int index) {
  GoRouter.of(context).push('/more/history/details?index=$index');
}
