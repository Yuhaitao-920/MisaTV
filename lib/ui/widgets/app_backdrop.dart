import 'package:flutter/material.dart';

/// 全窗口共享背景（对角渐变），自绘标题栏与页面共用同一层。
///
/// 性能要点：必须用 `CustomPaint(painter: …)` 直接画在内容**之下**（同一个绘制层），
/// 不能做成 `Stack` 里「内容上方/下方的独立图层」，也不要让绘制几何溢出视口 ——
/// Flutter 在 Windows 上遇到这种情况会保留多张整窗尺寸的离屏缓冲，实测常驻提交内存
/// 会多出约 200 MB（多张 ~34 MB 私有大块）。
class AppBackdropPainter extends CustomPainter {
  const AppBackdropPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  const Color(0xFF0F130D),
                  const Color(0xFF121810),
                  const Color(0xFF0D110C),
                ]
              : [
                  const Color(0xFFF6FAF2),
                  const Color(0xFFF1F6ED),
                  const Color(0xFFEDF3E9),
                ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(AppBackdropPainter old) => old.dark != dark;
}
