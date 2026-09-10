import 'package:flutter/material.dart';
import '../../../zipher_theme.dart';

/// Presentation shared with the original Z page. Wallet routing stays outside
/// these widgets so improving payment handling does not redesign the chat.
class ZChatMessage extends StatelessWidget {
  final String text;
  final bool isUser;
  final Widget? card;
  final Widget? footer;

  const ZChatMessage(
      {super.key,
      required this.text,
      this.isUser = false,
      this.card,
      this.footer});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: isUser
                        ? MediaQuery.sizeOf(context).width * .85
                        : MediaQuery.sizeOf(context).width - 32),
                child: Column(
                    crossAxisAlignment: isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      if (text.isNotEmpty)
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                                color: isUser
                                    ? ZipherColors.cyan.withValues(alpha: .15)
                                    : ZipherColors.cardBg,
                                borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(16),
                                    topRight: const Radius.circular(16),
                                    bottomLeft:
                                        Radius.circular(isUser ? 16 : 4),
                                    bottomRight:
                                        Radius.circular(isUser ? 4 : 16)),
                                border: Border.all(
                                    color: isUser
                                        ? ZipherColors.cyan
                                            .withValues(alpha: .2)
                                        : ZipherColors.borderSubtle)),
                            child: isUser &&
                                    RegExp(r'^(u1|utest1|t1|t3)[A-Za-z0-9]{40,}$')
                                        .hasMatch(text.trim())
                                ? ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    childrenPadding: EdgeInsets.zero,
                                    title: Text(
                                        '${text.substring(0, 12)}…${text.substring(text.length - 12)}',
                                        style: const TextStyle(
                                            fontFamily: 'JetBrains Mono',
                                            fontSize: 12,
                                            color: ZipherColors.textPrimary)),
                                    children: [
                                        SelectableText(text,
                                            style: const TextStyle(
                                                fontFamily: 'JetBrains Mono',
                                                fontSize: 11,
                                                height: 1.5))
                                      ])
                                : Text(text,
                                    style: TextStyle(
                                        color: isUser
                                            ? ZipherColors.textPrimary
                                            : ZipherColors.textSecondary,
                                        fontSize: 14,
                                        height: 1.5))),
                      if (card != null) card!,
                      if (footer != null) footer!,
                    ]))),
      );
}

class ZChatShortcut extends StatelessWidget {
  final IconData icon;
  final Widget? leading;
  final bool secondary;
  final String label;
  final VoidCallback? onTap;
  const ZChatShortcut(
      {super.key,
      this.icon = Icons.circle_outlined,
      this.leading,
      this.secondary = false,
      required this.label,
      required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        child: Material(
            color: Colors.transparent,
            child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                        color: secondary
                            ? Colors.transparent
                            : ZipherColors.cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: secondary
                                ? Colors.transparent
                                : ZipherColors.borderSubtle)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      leading ??
                          Icon(icon,
                              size: 14,
                              color: onTap == null
                                  ? ZipherColors.text40
                                  : secondary
                                      ? ZipherColors.text40
                                      : ZipherColors.cyan),
                      const SizedBox(width: 6),
                      Text(label,
                          style: TextStyle(
                              color: onTap == null
                                  ? ZipherColors.text40
                                  : secondary
                                      ? ZipherColors.text40
                                      : ZipherColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500)),
                    ])))),
      );
}

class ZChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final bool busy;
  final ValueChanged<String> onSubmit;
  final VoidCallback? onScan;
  const ZChatComposer(
      {super.key,
      required this.controller,
      this.focusNode,
      required this.hint,
      required this.busy,
      required this.onSubmit,
      this.onScan});

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none);
    return Container(
      decoration: BoxDecoration(
          color: ZipherColors.bg,
          border: Border(
              top: BorderSide(color: ZipherColors.borderSubtle, width: .5))),
      child: SafeArea(
          top: false,
          child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(children: [
                Expanded(
                    child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.send,
                        onSubmitted: busy ? null : onSubmit,
                        style: const TextStyle(
                            color: ZipherColors.textPrimary, fontSize: 15),
                        decoration: InputDecoration(
                          hintText: hint,
                          suffixIcon: onScan == null
                              ? null
                              : IconButton(
                                  tooltip: 'Scan QR code',
                                  onPressed: busy ? null : onScan,
                                  icon: const Icon(
                                      Icons.qr_code_scanner_rounded,
                                      size: 20,
                                      color: ZipherColors.textSecondary),
                                ),
                          hintStyle: TextStyle(color: ZipherColors.text40),
                          filled: true,
                          fillColor: ZipherColors.cardBg,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          border: border,
                          enabledBorder: border,
                          disabledBorder: border,
                          focusedBorder: border.copyWith(
                              borderSide: BorderSide(
                                  color:
                                      ZipherColors.cyan.withValues(alpha: .4))),
                        ))),
                const SizedBox(width: 8),
                Container(
                    decoration: BoxDecoration(
                        color: busy ? ZipherColors.text20 : ZipherColors.cyan,
                        shape: BoxShape.circle),
                    child: IconButton(
                        tooltip: busy ? 'Processing request' : 'Send message',
                        onPressed:
                            busy ? null : () => onSubmit(controller.text),
                        icon: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: ZipherColors.textPrimary))
                            : const Icon(Icons.arrow_upward,
                                color: ZipherColors.textOnBrand, size: 20))),
              ]))),
    );
  }
}

class ZChatTypingIndicator extends StatelessWidget {
  const ZChatTypingIndicator({super.key, this.label = 'Working…'});
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      label: label,
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Row(children: [
            const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 10),
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 12, color: ZipherColors.text40))),
          ])));
}
