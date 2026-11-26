import 'dart:ui' show Size;

/// 视频宽高比（宽 / 高）；分辨率未知时返回 0。
double videoAspectOf(double width, double height) =>
    (width > 0 && height > 0) ? width / height : 0;

/// 按视频比例算独立播放器窗口的目标尺寸。
///
/// 竖版视频取工作区高度的 85%（手机录像常见 9:16，横着放会留两大条黑边）；
/// 横版按工作区宽度的 92% 收。两边都保证不超出 [work]。
Size windowSizeForVideo(double width, double height, Size work) {
  final aspect = videoAspectOf(width, height);
  if (aspect <= 0 || work.width <= 0 || work.height <= 0) {
    return const Size(1280, 720);
  }
  final maxWidth = work.width * 0.92;
  final maxHeight = work.height * 0.85;
  double w;
  double h;
  if (aspect < 1) {
    h = maxHeight;
    w = h * aspect;
    if (w > maxWidth) {
      w = maxWidth;
      h = w / aspect;
    }
  } else {
    w = maxWidth;
    h = w / aspect;
    if (h > maxHeight) {
      h = maxHeight;
      w = h * aspect;
    }
  }
  return Size(w.roundToDouble(), h.roundToDouble());
}

/// 竖版窗口的最小尺寸：短边 320，长边按视频比例（上限 1280）。
///
/// 不变的话窗口会被主播放器的 720×405 下限卡住，压不出竖版。
Size portraitWindowMinimum(double width, double height) {
  final aspect = videoAspectOf(width, height);
  if (aspect <= 0) return const Size(320, 480);
  return Size(320, (320 / aspect).clamp(320.0, 1280.0));
}
