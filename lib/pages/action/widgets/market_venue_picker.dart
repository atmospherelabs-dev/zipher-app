import 'package:flutter/material.dart';
import 'package:gap/gap.dart';

import '../../../services/market_venue.dart';
import '../../../zipher_theme.dart';

/// Venue picker for prediction-market flows. Polymarket is the only active
/// venue as of 2026-05 (Myriad was hidden). The picker auto-confirms
/// Polymarket on first render so the chat doesn't pause on a redundant
/// single-choice card; the message above the card still tells the user
/// which venue they're using, then the chat flow continues.
class MarketVenuePickerRow extends StatefulWidget {
  const MarketVenuePickerRow({
    super.key,
    required this.onPick,
    this.polymarketAccent = const Color(0xFF6366F1),
  });

  final void Function(MarketVenue venue) onPick;
  final Color polymarketAccent;

  @override
  State<MarketVenuePickerRow> createState() => _MarketVenuePickerRowState();
}

class _MarketVenuePickerRowState extends State<MarketVenuePickerRow> {
  @override
  void initState() {
    super.initState();
    // Auto-pick Polymarket right after the first frame so the chat advances
    // without forcing the user through a one-button card. If we add a second
    // venue back (Kalshi, etc.), this widget reverts to a multi-button row.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPick(MarketVenue.polymarket);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.polymarketAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.polymarketAccent.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: widget.polymarketAccent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Image.asset('assets/venues/polymarket.png',
                    width: 20, height: 20),
              ),
              const Gap(10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Polymarket',
                      style: TextStyle(
                          color: widget.polymarketAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                    ),
                    const Gap(2),
                    Text(
                      MarketVenue.polymarket.chainCollateralHint,
                      style:
                          TextStyle(color: ZipherColors.text40, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
