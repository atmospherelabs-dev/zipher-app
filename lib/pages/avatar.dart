import 'package:flutter/material.dart';
import '../zipher_theme.dart';

/// Avatar color palette using Zipher brand colors
final _avatarColors = [
  ZipherColors.cyan,
  ZipherColors.green,
  ZipherColors.purple,
  const Color(0xFF00B0FF),
  const Color(0xFF1DE9B6),
  ZipherColors.orange,
  const Color(0xFF7C3AED),
  const Color(0xFF00E5FF),
  const Color(0xFF64DD17),
  const Color(0xFFF59E0B),
  const Color(0xFF06B6D4),
  const Color(0xFF8B5CF6),
  const Color(0xFF10B981),
  const Color(0xFFEC4899),
  const Color(0xFF3B82F6),
  const Color(0xFFF97316),
  const Color(0xFF14B8A6),
  const Color(0xFFA78BFA),
  const Color(0xFF22D3EE),
  const Color(0xFF34D399),
  const Color(0xFFFBBF24),
  const Color(0xFF818CF8),
  const Color(0xFF2DD4BF),
  const Color(0xFFF472B6),
  const Color(0xFF60A5FA),
  const Color(0xFFA3E635),
];

final _defaultColor = ZipherColors.textMuted;

Color initialToColor(String s) {
  final i = s.toUpperCase().codeUnitAt(0);
  if (i >= 65 && i < 91) {
    return _avatarColors[i - 65];
  }
  return _defaultColor;
}

Widget avatar(String initial) => CircleAvatar(
      backgroundColor: initialToColor(initial).withValues(alpha: 0.2),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: initialToColor(initial),
        ),
      ),
      radius: 22.0,
    );
