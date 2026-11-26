import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/platform/video_window_fit.dart';

void main() {
  test('视频宽高比：未知分辨率返回 0', () {
    expect(videoAspectOf(1080, 1920), closeTo(0.5625, 1e-9));
    expect(videoAspectOf(1920, 1080), closeTo(16 / 9, 1e-9));
    expect(videoAspectOf(0, 1920), 0);
    expect(videoAspectOf(1080, 0), 0);
  });

  test('竖版视频：窗口按比例压成竖版，不超出工作区', () {
    const work = Size(1440, 860);
    final size = windowSizeForVideo(1080, 1920, work);
    expect(size.height, closeTo(860 * 0.85, 0.5));
    expect(size.width / size.height, closeTo(1080 / 1920, 0.01));
    expect(size.width, lessThan(work.width));
  });

  test('横版视频：窗口按 16:9 收，高度不超过工作区', () {
    const work = Size(1440, 860);
    final size = windowSizeForVideo(1920, 1080, work);
    expect(size.width / size.height, closeTo(16 / 9, 0.02));
    expect(size.height, lessThanOrEqualTo(860 * 0.85 + 0.5));
    expect(size.width, lessThanOrEqualTo(1440 * 0.92 + 0.5));
  });

  test('窗口最小尺寸跟着视频比例走，竖版才能压下去', () {
    final portrait = portraitWindowMinimum(1080, 1920);
    expect(portrait.width, 320);
    expect(portrait.height, closeTo(320 / (1080 / 1920), 0.5));
    // 极端竖版（长截图那种）不要算出无限高的下限。
    expect(portraitWindowMinimum(100, 1000).height, 1280);
    expect(portraitWindowMinimum(9, 21).height, closeTo(320 / (9 / 21), 0.5));
    expect(portraitWindowMinimum(0, 0), const Size(320, 480));
  });
}
