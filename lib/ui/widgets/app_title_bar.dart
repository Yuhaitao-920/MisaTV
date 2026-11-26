import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/platform/window_service.dart';

/// 自绘窗口标题栏：左侧品牌与拖拽区，右侧最小化 / 最大化 / 关闭。
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key, this.height = 38});

  final double height;

  @override
  Widget build(BuildContext context) {
    if (!hasCustomWindowChrome) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.45),
              width: 0.6,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => startWindowDrag(),
                onDoubleTap: toggleMaximizeAppWindow,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.asset(
                          'assets/images/app_icon.png',
                          width: 21,
                          height: 21,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Text(
                        'MisaTV',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                          color: scheme.onSurface.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _CaptionButton(
              icon: Icons.remove_rounded,
              tooltip: '最小化',
              onTap: minimizeAppWindow,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: windowMaximized,
              builder: (context, maximized, _) {
                return _CaptionButton(
                  icon: maximized
                      ? Icons.filter_none_rounded
                      : Icons.crop_square_rounded,
                  tooltip: maximized ? '还原' : '最大化',
                  onTap: toggleMaximizeAppWindow,
                );
              },
            ),
            _CaptionButton(
              icon: Icons.close_rounded,
              tooltip: '关闭',
              close: true,
              onTap: closeAppWindow,
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.close = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool close;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _showLabel = false;
  Timer? _labelTimer;

  @override
  void dispose() {
    _labelTimer?.cancel();
    super.dispose();
  }

  void _setHover(bool value) {
    _labelTimer?.cancel();
    if (value) {
      _labelTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _showLabel = true);
      });
    }
    setState(() {
      _hover = value;
      if (!value) _showLabel = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hoverColor = widget.close
        ? const Color(0xFFC42B1C)
        : scheme.onSurface.withValues(alpha: 0.09);
    final iconColor = _hover && widget.close
        ? Colors.white
        : scheme.onSurface.withValues(alpha: 0.68);
    // 标题栏在 Navigator 之外，没有 Overlay 可挂 Tooltip，因此自带一个悬停标签。
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 110),
              width: 46,
              height: 38,
              alignment: Alignment.center,
              color: _hover ? hoverColor : Colors.transparent,
              child: Icon(widget.icon, size: 15, color: iconColor),
            ),
            // 标签横向摆在按钮左侧、纵向收在标题栏 38px 内：标题栏下方的内容
            // 是后绘制的，一旦越出就会把标签盖住。
            if (_showLabel)
              Positioned(
                top: 8,
                right: 52,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xF01F231B),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.tooltip,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
