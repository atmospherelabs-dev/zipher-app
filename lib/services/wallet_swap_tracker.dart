import 'dart:async';
import 'package:flutter/foundation.dart';
import 'app_log.dart';
import 'near_intents.dart';

class WalletSwapActivity {
  WalletSwapActivity(this.swap)
      : status = swap.status == null
            ? null
            : NearSwapStatus(status: swap.status!, raw: const {});
  StoredSwap swap;
  NearSwapStatus? status;
  bool unavailable = false;
  bool get isLive => status?.isTerminal != true;
  String get label {
    if (unavailable) return 'Status unavailable · retrying';
    final current = status;
    if (current == null) return 'Checking status…';
    if (current.isSuccess) return 'Completed';
    if (current.isRefunded) return 'Refunded';
    if (current.isFailed)
      return current.status == 'EXPIRED' ? 'Expired' : 'Needs attention';
    return switch (current.status) {
      'CONFIRMING' || 'KNOWN_DEPOSIT_TX' => 'Confirming deposit',
      'PROCESSING' => 'Swapping',
      'PENDING' || 'PENDING_DEPOSIT' => 'Waiting for deposit',
      _ => 'Checking status…',
    };
  }
}

/// Restores only this wallet's swaps. Unknown legacy ownership requires an
/// exact funding-transaction match; it is never inferred from a wallet label.
class WalletSwapTracker extends ChangeNotifier {
  WalletSwapTracker(
      {required this.walletId,
      required this.testnet,
      required this.transactionIds,
      required this.canPoll,
      required this.readStatus,
      this.load = SwapStore.load,
      this.saveStatus = SwapStore.updateStatus});
  final String? walletId;
  final bool testnet;
  final Set<String> Function() transactionIds;
  final bool Function() canPoll;
  final Future<NearSwapStatus> Function(String) readStatus;
  final Future<List<StoredSwap>> Function() load;
  final Future<void> Function(String, String) saveStatus;
  final _entries = <String, WalletSwapActivity>{};
  List<WalletSwapActivity> get entries => _entries.values.toList()
    ..sort((a, b) => b.swap.timestamp.compareTo(a.swap.timestamp));
  Timer? _timer;
  bool _disposed = false;
  bool _refreshing = false;

  bool _belongs(StoredSwap swap) {
    if (swap.provider != 'near_intents' ||
        swap.depositAddress.isEmpty ||
        testnet) return false;
    if (swap.walletId != null) {
      return walletId != null &&
          swap.walletId == walletId &&
          swap.testnet == testnet;
    }
    return swap.testnet != true &&
        swap.txId != null &&
        transactionIds().contains(swap.txId);
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => refresh());
    unawaited(refresh());
  }

  void track(StoredSwap swap) {
    if (_disposed || !_belongs(swap)) return;
    final entry = _entries[swap.depositAddress];
    if (entry == null) {
      _entries[swap.depositAddress] = WalletSwapActivity(swap);
    } else {
      entry.swap = swap;
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed || _refreshing || !canPoll()) return;
    _refreshing = true;
    try {
      final saved = await load();
      if (_disposed || !canPoll()) return;
      for (final swap in saved.where(_belongs)) {
        final entry = _entries.putIfAbsent(
            swap.depositAddress, () => WalletSwapActivity(swap));
        entry.swap = swap;
      }
      notifyListeners();
      for (final entry in entries.where((entry) => entry.isLive)) {
        if (_disposed || !canPoll()) return;
        try {
          final status = await readStatus(entry.swap.depositAddress)
              .timeout(const Duration(seconds: 12));
          if (_disposed || !canPoll()) return;
          if (entry.status?.status != status.status) {
            AppLog.instance.event('swap', 'status_changed',
                detail: 'status=${status.status}');
          }
          entry.status = status;
          entry.unavailable = false;
          notifyListeners();
          try {
            await saveStatus(entry.swap.depositAddress, status.status);
          } catch (error) {
            AppLog.instance.event('swap', 'status_save_failed', error: error);
          }
        } catch (error) {
          if (_disposed || !canPoll()) return;
          entry.unavailable = true;
          notifyListeners();
          AppLog.instance.event('swap', 'status_retry', error: error);
        }
      }
    } catch (error) {
      AppLog.instance.event('swap', 'history_load_failed', error: error);
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
