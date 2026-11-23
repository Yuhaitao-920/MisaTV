import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app.dart';

/// 从当前影片的横图里取一个主色，交给标题做配色。
///
/// 图片地址与 [ImmersiveBackdrop] 共用 `ArtworkService.backdrop` 的缓存，
/// 不会额外发一次网络请求；取色失败时 [tint] 为 null，标题回落到类型配色。
class TitleTint extends StatefulWidget {
  const TitleTint({
    super.key,
    required this.title,
    this.year = '',
    this.altTitle = '',
    this.fallbackUrl = '',
    required this.builder,
  });

  final String title;
  final String year;

  /// 元数据里的英文 / 日文原名，与封面共用同一套 TMDB 匹配。
  final String altTitle;

  /// 横图不可用时（例如只有竖版封面）用来取色的兜底图片。
  final String fallbackUrl;
  final Widget Function(BuildContext context, Color? tint) builder;

  @override
  State<TitleTint> createState() => _TitleTintState();
}

class _TitleTintState extends State<TitleTint> {
  Color? _tint;
  String _key = '';
  int _seq = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant TitleTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.year != widget.year ||
        oldWidget.altTitle != widget.altTitle ||
        oldWidget.fallbackUrl != widget.fallbackUrl) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final key =
        '${widget.title}|${widget.year}|${widget.altTitle}|${widget.fallbackUrl}';
    if (key == _key) return;
    _key = key;
    final seq = ++_seq;
    _tint = null;
    final service = AppScope.of(context).artworkService;
    final backdrop = await service.backdrop(
      widget.title,
      year: widget.year,
      altTitle: widget.altTitle,
    );
    if (!mounted || seq != _seq) return;
    Color? tint;
    if (backdrop != null && backdrop.isNotEmpty) {
      tint = await BackdropTintCache.resolve(backdrop);
      if (!mounted || seq != _seq) return;
    }
    final fallback = widget.fallbackUrl.trim();
    if (tint == null && fallback.isNotEmpty && fallback != backdrop) {
      tint = await BackdropTintCache.resolve(fallback);
      if (!mounted || seq != _seq) return;
    }
    if (tint != null) setState(() => _tint = tint);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _tint);
}

/// 横图主色缓存：同一张图只解码一次。
class BackdropTintCache {
  BackdropTintCache._();

  static final Map<String, Future<Color?>> _cache = {};

  static Future<Color?> resolve(String url) {
    if (_cache.length > 160) _cache.clear();
    return _cache.putIfAbsent(url, () => _sample(url));
  }

  static Future<Color?> _sample(String url) async {
    try {
      final stream = NetworkImage(url).resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (error, stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final image = await completer.future.timeout(const Duration(seconds: 12));
      return await _dominantHue(image);
    } catch (_) {
      return null;
    }
  }

  static Future<Color?> _dominantHue(ui.Image image) async {
    const side = 32;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      Paint()..filterQuality = FilterQuality.low,
    );
    final small = await recorder.endRecording().toImage(side, side);
    final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    small.dispose();
    if (data == null) return null;

    // 按色相做向量平均，避免把互补色平均成灰色。
    var x = 0.0;
    var y = 0.0;
    var weightSum = 0.0;
    var satSum = 0.0;
    for (var i = 0; i < side * side; i++) {
      final offset = i * 4;
      if (data.getUint8(offset + 3) < 128) continue;
      final color = Color.fromARGB(
        255,
        data.getUint8(offset),
        data.getUint8(offset + 1),
        data.getUint8(offset + 2),
      );
      final hsl = HSLColor.fromColor(color);
      if (hsl.saturation < 0.18) continue;
      if (hsl.lightness < 0.10 || hsl.lightness > 0.90) continue;
      final weight = hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 1.2);
      if (weight <= 0) continue;
      final angle = hsl.hue * math.pi / 180;
      x += math.cos(angle) * weight;
      y += math.sin(angle) * weight;
      weightSum += weight;
      satSum += hsl.saturation * weight;
    }
    if (weightSum < 0.8) return null;
    var hue = math.atan2(y, x) * 180 / math.pi;
    if (hue < 0) hue += 360;
    final saturation = (satSum / weightSum).clamp(0.55, 0.90);
    return HSLColor.fromAHSL(1, hue, saturation, 0.62).toColor();
  }
}
