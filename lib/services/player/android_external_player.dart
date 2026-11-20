import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/logging/app_log.dart';

/// 系统里一个能播放视频的 App（由原生 queryIntentActivities 枚举得到）。
class AndroidVideoPlayer {
  const AndroidVideoPlayer({required this.package, required this.label});

  final String package;
  final String label;

  static AndroidVideoPlayer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pkg = (raw['package'] ?? '').toString().trim();
    if (pkg.isEmpty) return null;
    final label = (raw['label'] ?? '').toString().trim();
    return AndroidVideoPlayer(package: pkg, label: label.isEmpty ? pkg : label);
  }
}

/// 用 Android 标准 `ACTION_VIEW` Intent 把片源交给手机里**任意**已安装的播放器。
///
/// 不绑定任何特定包名：不传 [package] 时弹出系统选择器，MX Player、VLC、
/// 夸克浏览器等所有声明了视频 MIME 的 App 都会出现；传 [package] 时精确定位。
/// 没有下载/安装逻辑，只做拉起。
///
/// 注意：Intent 无法传自定义 HTTP header。需要 Referer/UA 的片源由调用方先用
/// 本机中继（`/chunk`）包成本机地址再交给这里。
///
/// 仅 Android 可用；桌面 / Web 上 [supported] 为 false，调用方需自行判断。
class AndroidExternalPlayer {
  AndroidExternalPlayer._();

  static const _tag = 'ext-player';
  static const MethodChannel _channel =
      MethodChannel('com.kniephos.kniephos/external_player');

  static bool get supported => defaultTargetPlatform == TargetPlatform.android;

  /// 枚举手机上所有能处理视频的播放器。通道不可用时返回空列表，
  /// 调用方应提供「每次让我选择」的 chooser 兜底项。
  static Future<List<AndroidVideoPlayer>> installedPlayers() async {
    if (!supported) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listVideoPlayers');
      final out = <AndroidVideoPlayer>[];
      for (final item in raw ?? const <dynamic>[]) {
        final player = AndroidVideoPlayer.fromJson(item);
        if (player != null) out.add(player);
      }
      return out;
    } on MissingPluginException {
      return const [];
    } catch (e) {
      AppLog.w(_tag, '枚举外部播放器失败：$e');
      return const [];
    }
  }

  /// 用外部播放器打开 [url]。
  ///
  /// [title] 媒体标题；[positionMs] 起播位置（毫秒，播放器支持时生效）；
  /// [package] 为空时弹系统选择器，非空时直接拉起对应包名的播放器。
  /// 返回是否成功把 Intent 交给系统。
  static Future<bool> open(
    String url, {
    String? title,
    int positionMs = 0,
    String? package,
  }) async {
    if (!supported) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      AppLog.w(_tag, '无效播放地址：$url');
      return false;
    }
    final trimmed = package?.trim() ?? '';
    try {
      final ok = await _channel.invokeMethod<bool>('openWithExternalPlayer', {
        'url': url,
        'title': title,
        'positionMs': positionMs,
        'package': trimmed.isEmpty ? null : trimmed,
      });
      AppLog.i(
        _tag,
        '唤起外部播放器 '
        'package=${trimmed.isEmpty ? 'chooser' : trimmed} '
        'scheme=${uri.scheme} ok=$ok',
      );
      return ok ?? false;
    } catch (e) {
      AppLog.w(_tag, '唤起外部播放器失败：$e');
      return false;
    }
  }
}
