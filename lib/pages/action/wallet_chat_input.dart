import 'dart:convert';
import 'wallet_conversation.dart';

enum ChatManagementStep {
  contactChain,
  contactName,
  contactAddress,
  rename,
  review
}

enum ChatTool {
  addContact,
  contacts,
  accounts,
  renameAccount,
  deleteAccount,
  scan
}

/// Exact commands cannot accidentally interpret a payment memo as an action.
ChatTool? chatTool(String text) {
  final command = text.trim().toLowerCase().replaceFirst(RegExp(r'^/'), '');
  return switch (command) {
    'add contact' || 'new contact' || 'save contact' => ChatTool.addContact,
    'contacts' || 'show contacts' || 'my contacts' => ChatTool.contacts,
    'accounts' || 'switch account' || 'change account' => ChatTool.accounts,
    'rename account' || 'rename wallet' => ChatTool.renameAccount,
    'delete account' ||
    'remove account' ||
    'delete wallet' =>
      ChatTool.deleteAccount,
    'scan' || 'scan qr' || 'scan qr code' => ChatTool.scan,
    _ => null,
  };
}

/// Supported QR payloads are plain Zcash addresses or single-recipient payment
/// requests. Reject unsupported fields rather than silently changing a request.
WalletRequest scannedPayment(String payload, {required bool testnet}) {
  final text = payload.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) {
    if (!WalletConversation.looksLikeAddress(text)) {
      throw const FormatException('Scan a Zcash address or payment request.');
    }
    return WalletRequest(WalletCommand.send, recipient: text);
  }
  if (uri.scheme != (testnet ? 'zcash-test' : 'zcash') ||
      uri.hasAuthority ||
      uri.hasFragment) {
    throw const FormatException('This QR code is not for this Zcash network.');
  }
  final params = uri.queryParametersAll;
  if (params.keys
          .any((k) => !{'amount', 'memo', 'label', 'message'}.contains(k)) ||
      params.values.any((v) => v.length != 1)) {
    throw const FormatException(
        'This payment request has unsupported or multiple payments.');
  }
  if (!WalletConversation.looksLikeAddress(uri.path)) {
    throw const FormatException(
        'The payment request has no valid Zcash address.');
  }
  final amount = params['amount']?.single;
  final zatoshis =
      amount == null ? null : WalletConversation.parseZatoshis(amount);
  if (amount != null && zatoshis == null) {
    throw const FormatException('The payment amount is invalid.');
  }
  String? memo;
  if (params.containsKey('memo')) {
    try {
      final bytes =
          base64Url.decode(base64Url.normalize(params['memo']!.single));
      if (bytes.length > 512) throw const FormatException();
      memo = utf8.decode(bytes);
    } catch (_) {
      throw const FormatException('This QR memo is not a supported text memo.');
    }
  }
  return WalletRequest(WalletCommand.send,
      recipient: uri.path, zatoshis: zatoshis, memo: memo);
}
