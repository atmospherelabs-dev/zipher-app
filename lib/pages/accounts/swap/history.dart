import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../../zipher_theme.dart';
import '../../../generated/intl/messages.dart';
import '../../../services/near_intents.dart';
import '../../utils.dart';

class SwapHistoryPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => SwapHistoryState();
}

class SwapHistoryState extends State<SwapHistoryPage>
    with WithLoadingAnimation {
  late S s = S.of(context);
  List<StoredSwap> history = [];

  @override
  void initState() {
    super.initState();
    Future(() => load(() async {
          history = await SwapStore.load();
        }));
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return wrapWithLoading(Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Gap(topPad + 14),

            // ── Header ──
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBgElevated,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.arrow_back_rounded,
                        size: 18,
                        color: ZipherColors.text60),
                  ),
                ),
                const Gap(14),
                Text(
                  'Swap History',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.text90,
                  ),
                ),
                const Spacer(),
                if (history.isNotEmpty)
                  GestureDetector(
                    onTap: _clear,
                    child: Container(
                      width: 36,
                      height: 36,
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBgElevated,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.delete_outline_rounded,
                        size: 18,
                        color: ZipherColors.text40),
                    ),
                  ),
              ],
            ),
            const Gap(20),

            // ── List or empty state ──
            Expanded(
              child: history.isEmpty
                  ? _buildEmpty()
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 32),
                      itemCount: history.length,
                      separatorBuilder: (_, __) => const Gap(10),
                      itemBuilder: (_, i) => _buildSwapCard(history[i]),
                    ),
            ),
          ],
        ),
      ),
    ));
  }

  // ─── Empty state ───────────────────────────────────────────

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: ZipherColors.cardBg,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.swap_horiz_rounded,
                size: 26, color: ZipherColors.text10),
          ),
          const Gap(16),
          Text(
            'No swaps yet',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: ZipherColors.text20,
            ),
          ),
          const Gap(6),
          Text(
            'Your swap history will appear here',
            style: TextStyle(
              fontSize: 12,
              color: ZipherColors.text10,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Swap card ─────────────────────────────────────────────

  Widget _buildSwapCard(StoredSwap swap) {
    final ts = DateTime.fromMillisecondsSinceEpoch(swap.timestamp * 1000);
    final when = timeago.format(ts);
    final isNear = swap.provider == 'near_intents';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: provider badge + time
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isNear ? 'NEAR Intents' : swap.provider,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: ZipherColors.cyan.withValues(alpha: 0.6),
                  ),
                ),
              ),
              const Spacer(),
              Text(
                when,
                style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text20,
                ),
              ),
            ],
          ),
          const Gap(14),

          // From → To
          Row(
            children: [
              Expanded(child: _tokenColumn(
                label: 'Sent',
                amount: swap.fromAmount,
                symbol: swap.fromCurrency,
                address: swap.depositAddress,
              )),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward_rounded,
                    size: 16,
                    color: ZipherColors.text10),
              ),

              Expanded(child: _tokenColumn(
                label: 'Received',
                amount: swap.toAmount,
                symbol: swap.toCurrency,
                address: swap.toAddress,
                alignEnd: true,
              )),
            ],
          ),

          if (isNear && swap.depositAddress.isNotEmpty) ...[
            const Gap(12),
            Divider(height: 1, color: ZipherColors.cardBg),
            const Gap(10),
            GestureDetector(
              onTap: () => GoRouter.of(context)
                  .push('/swap/status', extra: {
                    'depositAddress': swap.depositAddress,
                    'fromCurrency': swap.fromCurrency,
                    'fromAmount': swap.fromAmount,
                    'toCurrency': swap.toCurrency,
                    'toAmount': swap.toAmount,
                  }),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.track_changes_rounded,
                      size: 14,
                      color: ZipherColors.cyan.withValues(alpha: 0.5)),
                  const Gap(6),
                  Text(
                    'Check Status',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ZipherColors.cyan.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Token column (from or to) ────────────────────────────

  Widget _tokenColumn({
    required String label,
    required String amount,
    required String symbol,
    String? address,
    bool alignEnd = false,
  }) {
    final cross =
        alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: cross,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: ZipherColors.text20,
          ),
        ),
        const Gap(4),
        Text(
          '$amount $symbol',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: ZipherColors.text90,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (address != null && address.isNotEmpty) ...[
          const Gap(2),
          Text(
            centerTrim(address, length: 16),
            style: TextStyle(
              fontSize: 11,
              color: ZipherColors.text10,
            ),
          ),
        ],
      ],
    );
  }

  // ─── Clear history ─────────────────────────────────────────

  void _clear() async {
    final confirmed = await showConfirmDialog(
        context, s.confirm, s.confirmClearSwapHistory);
    if (confirmed) {
      await SwapStore.clear();
      setState(() => history = []);
    }
  }
}
