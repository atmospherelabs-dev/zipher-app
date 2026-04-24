import 'package:flutter/material.dart';

import 'intent.dart';

class SuggestionItem {
  final IconData icon;
  final String label;
  final String command;
  final ParsedIntent? intent;
  const SuggestionItem(this.icon, this.label, this.command, {this.intent});
}

class SweepableToken {
  final String symbol;
  final double balance;
  final double sweepAmount;
  final double usdValue;
  final String? contractAddress;
  final String? defuseAssetId;
  final int decimals;

  const SweepableToken({
    required this.symbol,
    required this.balance,
    required this.sweepAmount,
    required this.usdValue,
    this.contractAddress,
    this.defuseAssetId,
    required this.decimals,
  });

  bool get isNative => contractAddress == null;
  bool get isSupported => defuseAssetId != null || isNative;
}

class ActionMessage {
  final String text;
  final bool isUser;
  final DateTime time;
  final Widget? card;
  final IntentType? intentType;

  ActionMessage({
    required this.text,
    required this.isUser,
    DateTime? time,
    this.card,
    this.intentType,
  }) : time = time ?? DateTime.now();
}
