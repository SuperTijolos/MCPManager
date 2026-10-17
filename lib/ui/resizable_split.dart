import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Two panes with a draggable divider. The left pane's width is controlled
/// by the user (mouse drag, or ←/→ when the divider has focus) and reported
/// through [onChanged] so it can be remembered.
class ResizableSplit extends StatefulWidget {
  const ResizableSplit({
    super.key,
    required this.left,
    required this.right,
    required this.initialWidth,
    this.minLeft = 240,
    this.minRight = 360,
    this.onChanged,
    this.semanticLabel = 'Resize list',
  });

  final Widget left;
  final Widget right;
  final double initialWidth;
  final double minLeft;
  final double minRight;
  final ValueChanged<double>? onChanged;
  final String semanticLabel;

  @override
  State<ResizableSplit> createState() => _ResizableSplitState();
}

class _ResizableSplitState extends State<ResizableSplit> {
  late double _width = widget.initialWidth;
  bool _hover = false;
  bool _drag = false;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  double _clamp(double w, double total) {
    final max = (total - widget.minRight - _handle).clamp(
      widget.minLeft,
      double.infinity,
    );
    return w.clamp(widget.minLeft, max);
  }

  static const _handle = 12.0;

  void _set(double w, double total, {bool commit = false}) {
    final next = _clamp(w, total);
    if (next != _width) setState(() => _width = next);
    if (commit) widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        final width = _clamp(_width, total);
        final active = _hover || _drag || _focus.hasFocus;
        return Row(
          children: [
            SizedBox(width: width, child: widget.left),
            Semantics(
              label: widget.semanticLabel,
              child: Focus(
                focusNode: _focus,
                onFocusChange: (_) => setState(() {}),
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final step = HardwareKeyboard.instance.isShiftPressed
                      ? 64.0
                      : 16.0;
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _set(width - step, total, commit: true);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    _set(width + step, total, commit: true);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  onEnter: (_) => setState(() => _hover = true),
                  onExit: (_) => setState(() => _hover = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _focus.requestFocus,
                    onDoubleTap: () =>
                        _set(widget.initialWidth, total, commit: true),
                    onHorizontalDragStart: (_) => setState(() => _drag = true),
                    onHorizontalDragUpdate: (d) =>
                        _set(width + d.delta.dx, total),
                    onHorizontalDragEnd: (_) {
                      setState(() => _drag = false);
                      widget.onChanged?.call(_width);
                    },
                    child: SizedBox(
                      width: _handle,
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: active ? 3 : 1,
                          height: double.infinity,
                          color: active
                              ? scheme.primary.withValues(alpha: 0.8)
                              : scheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: widget.right),
          ],
        );
      },
    );
  }
}
