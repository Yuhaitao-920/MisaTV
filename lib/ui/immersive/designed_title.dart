import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hero_title_style.dart';

/// 沉浸模式统一的设计标题：电影海报式排版。
///
/// 不用整块底版压住封面，而是让标题直接落在画面上：
/// 顶部小字、白色主标题、细强调线、原名 / 副标题，再配一层跟着封面主色的
/// 柔和暗角。Hero 与沉浸详情页共用；[scale] 控制详情页的小尺寸版本。
class DesignedTitle extends StatelessWidget {
  const DesignedTitle({
    super.key,
    required this.plan,
    this.scale = 1,
    this.maxWidth = 1100,
    this.maxHeight,
    this.overline = '',
  });

  final HeroTitlePlan plan;

  final double scale;
  final double maxWidth;

  /// 竖排时用于限制单字大小，避免撑出 Hero 区域。
  final double? maxHeight;

  /// 标题上方的小字（类型 / 国家 / 年份），Hero 顶部那行信息用。
  final String overline;

  @override
  Widget build(BuildContext context) {
    if (plan.vertical) {
      final strip = _buildVertical();
      if (overline.trim().isEmpty) return strip;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kicker(overline.trim().toUpperCase()),
          SizedBox(height: 12 * scale),
          strip,
        ],
      );
    }
    final content = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (overline.trim().isNotEmpty)
            _kicker(overline.trim().toUpperCase())
          else
            _ornament(),
          SizedBox(height: 14 * scale),
          _line(plan.lines.first, plan.fontSize * scale, primary: true),
          if (plan.stacked) ...[
            SizedBox(height: 2 * scale),
            Padding(
              padding: EdgeInsets.only(left: 64 * scale),
              child: _line(
                plan.lines[1],
                plan.fontSize * 0.56 * scale,
                primary: false,
              ),
            ),
          ],
          SizedBox(height: 18 * scale),
          _footer(),
        ],
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 跟着封面主色的柔和暗角：让标题像是从画面里长出来的，
        // 而不是贴上去的一整块渐变底板。
        Positioned(
          left: -72 * scale,
          right: -40 * scale,
          top: -56 * scale,
          bottom: -34 * scale,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.55, 0.0),
                  radius: 1.05,
                  colors: [
                    plan.plate.withValues(alpha: 0.58),
                    plan.plate.withValues(alpha: 0.18),
                    plan.plate.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }

  /// 顶部小字：强调色标记 + 宽字距的类型 / 国家信息。
  Widget _kicker(String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ornament(),
        SizedBox(width: 12 * scale),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520 * scale),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.74),
              fontSize: 13 * scale,
              letterSpacing: 2.6 * scale,
              fontWeight: FontWeight.w600,
              shadows: const [Shadow(blurRadius: 12, color: Colors.black87)],
            ),
          ),
        ),
      ],
    );
  }

  /// 类型标记：不再给整块底板，只在标题前留一个小符号。
  Widget _ornament() {
    final color = plan.accent;
    return switch (plan.shape) {
      HeroTitleShape.slanted => Transform(
        alignment: Alignment.center,
        transform: Matrix4.skewX(-0.45),
        child: Container(width: 26 * scale, height: 3.4 * scale, color: color),
      ),
      HeroTitleShape.notched => SizedBox(
        width: 26 * scale,
        height: 10 * scale,
        child: CustomPaint(painter: _BracketPainter(color, 1.6 * scale)),
      ),
      HeroTitleShape.torn => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 4 * scale, height: 10 * scale, color: color),
          SizedBox(width: 3 * scale),
          Container(
            width: 13 * scale,
            height: 3 * scale,
            color: color.withValues(alpha: 0.72),
          ),
          SizedBox(width: 3 * scale),
          Container(
            width: 4 * scale,
            height: 6 * scale,
            color: color.withValues(alpha: 0.5),
          ),
        ],
      ),
      HeroTitleShape.band => Container(
        width: 28 * scale,
        height: 3 * scale,
        color: color,
      ),
    };
  }

  Widget _line(String text, double size, {required bool primary}) {
    final style = TextStyle(
      fontFamily: plan.family,
      fontSize: size,
      height: primary ? 1.02 : 1.08,
      letterSpacing: primary
          ? plan.letterSpacing
          : plan.letterSpacing + 3 * scale,
      fontWeight: plan.family == null ? FontWeight.w800 : FontWeight.w700,
      color: Colors.white,
    );
    final glow = Text(
      text,
      maxLines: 1,
      softWrap: false,
      style: style.copyWith(
        color: const Color(0x00000000),
        shadows: [
          Shadow(
            color: plan.accent.withValues(alpha: primary ? 0.30 : 0.18),
            blurRadius: 46 * scale,
          ),
        ],
      ),
    );
    final shadow = Text(
      text,
      maxLines: 1,
      softWrap: false,
      style: style.copyWith(
        color: const Color(0x00000000),
        shadows: [
          Shadow(blurRadius: 30, color: Colors.black.withValues(alpha: 0.88)),
          Shadow(
            offset: Offset(0, 3 * scale),
            blurRadius: 5,
            color: Colors.black.withValues(alpha: 0.72),
          ),
        ],
      ),
    );
    final Widget fill;
    if (primary) {
      fill = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(plan.titleTop, Colors.white, 0.72)!,
            plan.titleTop,
            plan.titleBottom,
          ],
          stops: const [0, 0.5, 1],
        ).createShader(bounds),
        child: Text(text, maxLines: 1, softWrap: false, style: style),
      );
    } else {
      fill = Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: style.copyWith(
          color: Color.lerp(
            plan.titleBottom,
            Colors.white,
            0.34,
          )?.withValues(alpha: 0.94),
        ),
      );
    }
    return Transform.rotate(
      angle: primary ? plan.tilt : 0,
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Stack(children: [glow, shadow, fill]),
      ),
    );
  }

  /// 底部细强调线 + 原名 / 副标题，像海报底部的 credit line。
  Widget _footer() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 58 * scale,
          height: 1.5 * scale,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [plan.accent, plan.accent.withValues(alpha: 0)],
            ),
          ),
        ),
        if (plan.secondary.isNotEmpty) ...[
          SizedBox(width: 14 * scale),
          Flexible(
            child: Text(
              plan.secondary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 15 * scale,
                letterSpacing: 4.5 * scale,
                fontWeight: FontWeight.w500,
                shadows: const [Shadow(blurRadius: 10, color: Colors.black87)],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildVertical() {
    final count = math.max(1, plan.main.runes.length);
    final base = plan.fontSize * scale;
    var size = base;
    final limit = maxHeight;
    if (limit != null) {
      final available = math.max(120.0, limit - 74 * scale);
      size = math.min(base, available / (count * 1.02));
    }
    return Container(
      padding: EdgeInsets.fromLTRB(
        20 * scale,
        20 * scale,
        24 * scale,
        16 * scale,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            plan.plate.withValues(alpha: 0.56),
            plan.plate.withValues(alpha: 0.16),
          ],
        ),
        border: Border(
          right: BorderSide(
            color: plan.accent.withValues(alpha: 0.85),
            width: 2 * scale,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: plan.accent.withValues(alpha: 0.16),
            blurRadius: 30 * scale,
            offset: Offset(0, 10 * scale),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final rune in plan.main.runes)
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [plan.titleTop, plan.titleBottom],
              ).createShader(bounds),
              child: Text(
                String.fromCharCodes([rune]),
                style: TextStyle(
                  fontFamily: plan.family,
                  fontSize: size,
                  height: 1.0,
                  letterSpacing: plan.letterSpacing,
                  fontWeight: plan.family == null
                      ? FontWeight.w800
                      : FontWeight.w700,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: plan.accent.withValues(alpha: 0.26),
                      blurRadius: 30 * scale,
                    ),
                    const Shadow(blurRadius: 20, color: Colors.black87),
                  ],
                ),
              ),
            ),
          if (plan.secondary.isNotEmpty) ...[
            SizedBox(height: 12 * scale),
            Text(
              plan.secondary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 13 * scale,
                letterSpacing: 3 * scale,
                fontWeight: FontWeight.w500,
                shadows: const [Shadow(blurRadius: 10, color: Colors.black87)],
              ),
            ),
          ],
          SizedBox(height: 12 * scale),
          Container(
            width: 13 * scale,
            height: 13 * scale,
            decoration: BoxDecoration(
              color: plan.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  const _BracketPainter(this.color, this.strokeWidth);

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BracketPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}
