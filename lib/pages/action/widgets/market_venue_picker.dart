import 'package:flutter/material.dart';
import 'package:gap/gap.dart';

import '../../../services/market_venue.dart';
import '../../../zipher_theme.dart';

/// Two-tap venue choice: Polymarket vs Myriad (no [MarketVenue.unset] button).
class MarketVenuePickerRow extends StatelessWidget {
  const MarketVenuePickerRow({
    super.key,
    required this.onPick,
    this.polymarketAccent = const Color(0xFF6366F1),
  });

  final void Function(MarketVenue venue) onPick;
  final Color polymarketAccent;

  @override
  Widget build(BuildContext context) {
    Widget btn(MarketVenue venue, String label, IconData icon, Color accent) {
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onPick(venue),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent.withValues(alpha: 0.25)),
              ),
              child: Column(
                children: [
                  Icon(icon, color: accent, size: 24),
                  const Gap(8),
                  Text(
                    label,
                    style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const Gap(2),
                  Text(
                    venue.chainCollateralHint,
                    style: TextStyle(color: ZipherColors.text40, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          btn(MarketVenue.polymarket, 'Polymarket', Icons.public_rounded, polymarketAccent),
          const Gap(12),
          btn(MarketVenue.myriad, 'Myriad', Icons.casino_rounded, ZipherColors.purple),
        ],
      ),
    );
  }
}
