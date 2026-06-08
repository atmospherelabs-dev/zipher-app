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
  /// Stable key for selection, e.g. `BSC:USDT:0x55d3…`.
  final String id;
  final String chainLabel;
  final int chainId;
  final String symbol;
  final double balance;
  final double sweepAmount;
  final double usdValue;
  final String? contractAddress;
  final String? defuseAssetId;
  final int decimals;
  final bool supported;
  final String? unsupportedReason;

  const SweepableToken({
    required this.id,
    required this.chainLabel,
    required this.chainId,
    required this.symbol,
    required this.balance,
    required this.sweepAmount,
    required this.usdValue,
    this.contractAddress,
    this.defuseAssetId,
    required this.decimals,
    this.supported = true,
    this.unsupportedReason,
  });

  bool get isNative => contractAddress == null;
  bool get isSupported => supported && (isNative ? defuseAssetId != null : defuseAssetId != null);
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
