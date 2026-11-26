import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 悬停跑马灯文本：标题放不下、被省略号截断时，鼠标移上去会自动横向循环滚动。
///
/// 用法尽量贴近 [Text]：
/// `HoverMarqueeText(title, maxLines: 1, style: ...)`。
/// - 未悬停 / 文本放得下：和普通 Text 一样（超出按 [overflow] 省略）。
/// - 悬停且被截断：保持原文本块高度，改为单行循环滚动显示完整标题。
/// - 移动端没有鼠标悬停，保持普通 Text 行为。
class HoverMarqueeText extends StatefulWidget {
  const HoverMarqueeText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
    this.overflow = TextOverflow.ellipsis,
    this.speed = 36,
    this.gap = 36,
    this.externalHover,
  });

  final String text;
  final TextStyle? style;
  final int maxLines;
  final TextAlign textAlign;
  final TextOverflow overflow;

  /// 滚动速度（逻辑像素/秒）。
  final double speed;

  /// 首尾循环之间的空白间距。
  final double gap;

  /// 由父级卡片传入的悬停状态。
  ///
  /// 不传时只监听标题文字本身的 MouseRegion；传了以后由外层卡片
  /// （海报卡 / 频道卡 / 选集按钮）统一触发，鼠标移到整张卡上就会滚动。
  final bool? externalHover;

  @override
  State<HoverMarqueeText> createState() => _HoverMarqueeTextState();
}

class _HoverMarqueeTextState extends State<HoverMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  bool _hover = false;
  double _textWidth = 0;
  double _availableWidth = 0;

  bool get _isHovered => widget.externalHover ?? _hover;

  @override
  void didUpdateWidget(HoverMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (!_isHovered || _textWidth <= _availableWidth + 0.5) {
      _controller.stop();
      if (_controller.value != 0) _controller.value = 0;
      return;
    }
    final distance = _textWidth + widget.gap;
    final ms = math.max(1200, (distance / widget.speed * 1000).round());
    final duration = Duration(milliseconds: ms);
    if (_controller.duration != duration || !_controller.isAnimating) {
      _controller.duration = duration;
      _controller.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.isEmpty) return const SizedBox.shrink();
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        // `Text` widget 默认带一个和字号等大的 strut（强制行高），而裸
        // `TextPainter` 不会带。高度校准统一在下面用 `_textStyleHeight` 处理。
        final normalPainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textAlign: widget.textAlign,
          textDirection: textDirection,
          textScaler: textScaler,
          maxLines: widget.maxLines,
          ellipsis: '…',
        )..layout(maxWidth: available);
        final fullPainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textAlign: widget.textAlign,
          textDirection: textDirection,
          textScaler: textScaler,
          maxLines: 1,
        )..layout();
        final textWidth = fullPainter.width;
        final truncated =
            normalPainter.didExceedMaxLines || textWidth > available + 0.5;
        // 高度完全交给 `Text` 自己决定，不再用 `TextPainter.height` 撑
        // `SizedBox`。painter 只算字体的 em 高度（字号 13 → 13px），而 `Text`
        // 走 `RenderParagraph`，会把行距与 ascent/descent 一并算进去
        // （同例实测 19px）。之前用 painter 的高度限制外层，多出来的 6px 没有
        // 位置，文字的 descender 就被裁掉——表现正是「分类名 / 集数文字下半截
        // 看不见」。`_textWidth` 仍用 painter 量，它跟高度无关。
        _textWidth = textWidth;
        _availableWidth = available.isFinite ? available : textWidth;

        if (!truncated) {
          return Text(
            widget.text,
            maxLines: widget.maxLines,
            overflow: widget.overflow,
            style: widget.style,
            textAlign: widget.textAlign,
          );
        }

        final hovering = _isHovered;
        if (hovering) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncAnimation();
          });
        } else if (_controller.isAnimating) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncAnimation();
          });
        }

        // 悬停滚动分支同样不钳高度：`OverflowBox` 内部本身不受约束，
        // 这里若用 painter 估算的高度反而会把文字裁掉一截。
        final content = hovering && textWidth > _availableWidth + 0.5
            ? ClipRect(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final shift = _controller.value * (textWidth + widget.gap);
                    return OverflowBox(
                      alignment: Alignment.topLeft,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: Transform.translate(
                        offset: Offset(-shift, 0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.text,
                              maxLines: 1,
                              softWrap: false,
                              style: widget.style,
                            ),
                            SizedBox(width: widget.gap),
                            Text(
                              widget.text,
                              maxLines: 1,
                              softWrap: false,
                              style: widget.style,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              )
            : Text(
                widget.text,
                maxLines: widget.maxLines,
                overflow: widget.overflow,
                style: widget.style,
                textAlign: widget.textAlign,
              );

        if (widget.externalHover != null) {
          return Semantics(
            label: widget.text,
            excludeSemantics: true,
            child: content,
          );
        }
        return Semantics(
          label: widget.text,
          excludeSemantics: true,
          child: MouseRegion(
            onEnter: (_) {
              setState(() => _hover = true);
              _syncAnimation();
            },
            onExit: (_) {
              setState(() => _hover = false);
              _syncAnimation();
            },
            child: content,
          ),
        );
      },
    );
  }
}
