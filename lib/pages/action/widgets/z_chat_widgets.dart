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

  /// One unbroken value too long to read in a bubble, such as an address.
  static bool isLongValue(String text) =>
      RegExp(r'^\S{30,}$').hasMatch(text.trim());

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: isUser ? 10 : 6, bottom: 6),
        child: Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: isUser
                        ? MediaQuery.sizeOf(context).width * .82
                        : MediaQuery.sizeOf(context).width - 32),
                child: Column(
                    crossAxisAlignment: isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      if (text.isNotEmpty && isUser)
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                                color: ZipherColors.cyan.withValues(alpha: .14),
                                borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(18),
                                    topRight: Radius.circular(18),
                                    bottomLeft: Radius.circular(18),
                                    bottomRight: Radius.circular(5))),
                            child: isLongValue(text)
                                ? _LongValue(text.trim())
                                : Text(text,
                                    style: const TextStyle(
                                        color: ZipherColors.textPrimary,
                                        fontSize: 15,
                                        height: 1.4))),
                      // The wallet speaks in plain text; only cards are boxed.
                      if (text.isNotEmpty && !isUser)
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Text(text,
                                style: const TextStyle(
                                    color: ZipherColors.textPrimary,
                                    fontSize: 15,
                                    height: 1.45))),
                      if (card != null) card!,
                      if (footer != null) footer!,
                    ]))),
      );
}

/// The boxed surface for a wallet reply card (reviews, details, status).
class ZChatCard extends StatelessWidget {
  const ZChatCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.only(top: ZipherSpacing.sm),
      padding: const EdgeInsets.all(ZipherSpacing.md),
      decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(ZipherRadius.card),
          border: Border.all(color: ZipherColors.borderSubtle, width: .5)),
      child: child);
}

class _LongValue extends StatefulWidget {
  const _LongValue(this.value);
  final String value;
  @override
  State<_LongValue> createState() => _LongValueState();
}

class _LongValueState extends State<_LongValue> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    return Semantics(
        button: true,
        label: _open ? 'Hide full value' : 'Show full value',
        child: InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Text(
                _open
                    ? v
                    : '${v.substring(0, 12)}…${v.substring(v.length - 12)}',
                style: const TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 12,
                    height: 1.5,
                    color: ZipherColors.textPrimary))));
  }
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
                borderRadius: BorderRadius.circular(ZipherRadius.full),
                child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                        color: secondary
                            ? Colors.transparent
                            : ZipherColors.cardBg,
                        borderRadius: BorderRadius.circular(ZipherRadius.full),
                        border: Border.all(
                            color: secondary
                                ? Colors.transparent
                                : ZipherColors.borderSubtle)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      leading ??
                          Icon(icon,
                              size: 16,
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
                              fontSize: 14,
                              fontWeight: FontWeight.w500)),
                    ])))),
      );
}

/// What is being prepared, pinned above the composer with a way out.
class ZChatDraftBar extends StatelessWidget {
  const ZChatDraftBar(
      {super.key,
      required this.icon,
      required this.label,
      required this.onCancel});
  final IconData icon;
  final String label;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
          color: ZipherColors.cardBg,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          border: Border.all(color: ZipherColors.borderSubtle, width: 0.5)),
      child: Row(children: [
        Icon(icon, size: 14, color: ZipherColors.cyan),
        const SizedBox(width: 8),
        Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: ZipherColors.textSecondary))),
        TextButton(
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: ZipherColors.text40),
            onPressed: onCancel,
            child: const Text('Cancel')),
      ]));
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
        borderRadius: BorderRadius.circular(ZipherRadius.full),
        borderSide: BorderSide.none);
    return Container(
      decoration: BoxDecoration(
          color: ZipherColors.bg,
          border: Border(
              top: BorderSide(color: ZipherColors.separator, width: .5))),
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
                              horizontal: 18, vertical: 12),
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
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                        color: busy ? ZipherColors.surfaceLight : ZipherColors.cyan,
                        shape: BoxShape.circle),
                    child: IconButton(
                        padding: EdgeInsets.zero,
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
