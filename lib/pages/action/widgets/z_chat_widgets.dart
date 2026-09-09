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
                    maxWidth: MediaQuery.sizeOf(context).width * .85),
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
                            child: Text(text,
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
  final String label;
  final VoidCallback? onTap;
  const ZChatShortcut(
      {super.key,
      required this.icon,
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
                borderRadius: BorderRadius.circular(20),
                child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                        color: ZipherColors.cardBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: ZipherColors.borderSubtle)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon,
                          size: 14,
                          color: onTap == null
                              ? ZipherColors.text40
                              : ZipherColors.cyan),
                      const SizedBox(width: 6),
                      Text(label,
                          style: TextStyle(
                              color: onTap == null
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
  const ZChatComposer(
      {super.key,
      required this.controller,
      this.focusNode,
      required this.hint,
      required this.busy,
      required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none);
    return Container(
      decoration: BoxDecoration(
          color: ZipherColors.surface,
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
  const ZChatTypingIndicator({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Processing request',
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                        color: ZipherColors.cardBg,
                        borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(16)),
                        border: Border.all(color: ZipherColors.borderSubtle)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      _PulsingDot(delayMs: 0),
                      SizedBox(width: 4),
                      _PulsingDot(delayMs: 150),
                      SizedBox(width: 4),
                      _PulsingDot(delayMs: 300),
                    ])))),
      );
}

class _PulsingDot extends StatefulWidget {
  final int delayMs;
  const _PulsingDot({required this.delayMs});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.3, end: 1.0)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 50),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.3)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 50),
    ]).animate(_controller);
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _controller.repeat();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, child) => Opacity(
        opacity: _opacity.value,
        child: child,
      ),
      child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
              color: ZipherColors.text40, shape: BoxShape.circle)),
    );
  }
}
