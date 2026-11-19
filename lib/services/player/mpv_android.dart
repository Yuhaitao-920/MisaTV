import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/logging/app_log.dart';

/// 系统里一个可以播放视频的 App（由原生 queryIntentActivities 枚举得到）。
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

/// 用 Android 标准 `ACTION_VIEW` Intent 把片源交给外部播放器。
///
/// 不指定包名时弹出系统选择器，手机上安装的任何视频播放器（MX Player、
/// VLC、PotPlayer、mpv-android……）都会出现；指定包名时直接拉起该播放器。
///   - data: http/https/ftp URI，MIME 由原生按扩展名推断并回退 `video/*`
///   - extras: `title`(String)、`position`(Int, 毫秒)（mpv 等支持）
///
/// 注意：Intent 不支持传自定义 HTTP header。需要 Referer/UA 的片源，
/// 调用方应先用 MisaTV 的本机中继（`/chunk` 或 `LocalRelay`）把远端流包成
/// 本机地址，再把该地址交给这里。
///
/// 桌面 / Web 上本工具不可用，调用方需用 [supported] 判断。
class MpvAndroid {
  MpvAndroid._();

  /// mpv-android 的包名（保留兼容：用作默认候选与设置项）。
  static const String package = 'is.xyz.mpv';
  static const String _tag = 'mpv-android';

  /// 当前平台是否支持（仅 Android；Web / 桌面一律 false）。
  static bool get supported => defaultTargetPlatform == TargetPlatform.android;

  static const MethodChannel _installChannel =
      MethodChannel('com.kniephos.kniephos/mpv_install');

  /// 枚举手机上所有能处理 `video/*` 的播放器。
  ///
  /// 原生通道不可用时返回空列表，调用方应提供「每次选择」兜底项。
  static Future<List<AndroidVideoPlayer>> installedPlayers() async {
    if (!supported) return const [];
    try {
      final raw = await _installChannel.invokeMethod<List<dynamic>>(
        'listVideoPlayers',
      );
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

  /// mpv-android 是否已安装（软检测）。
  ///
  /// Android 11+ 的包可见性限制要求在 AndroidManifest 的 `<queries>` 里声明
  /// `is.xyz.mpv`，否则 `canLaunchUrl` 会误报未安装。即便返回 false，
  /// [open] 仍会尝试拉起，失败由调用方回落内置播放器。
  static Future<bool> isInstalled() async {
    if (!supported) return false;
    try {
      final native = await _installChannel.invokeMethod<bool>('isInstalled');
      if (native != null) return native;
    } on MissingPluginException {
      // 老宿主未注册通道，走下面的 intent 探测。
    } catch (_) {}
    try {
      final probe = Uri.parse(
        'intent://#Intent;action=android.intent.action.VIEW;'
        'package=$package;type=video/any;end',
      );
      return await canLaunchUrl(probe);
    } catch (e) {
      AppLog.w(_tag, '检测 mpv-android 安装状态失败：$e');
      return false;
    }
  }

  /// 用外部播放器打开 [url]。
  ///
  /// [title] 作为媒体标题显示；[positionMs] 为起播位置（毫秒）。
  /// [package] 为空时弹出系统选择器（可选手机里的任意播放器）；
  /// 非空时直接拉起对应包名的播放器。
  /// 返回是否成功把 intent 交给系统。
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
    final target = trimmed.isEmpty ? null : trimmed;
    // 优先走原生标准 Intent：本机 /chunk 地址无扩展名，要靠 MIME 匹配，
    // 且 intent:// URI 的 #Intent fragment 经 url_launcher 传输时不会被解析，
    // 会报 ACTIVITY_NOT_FOUND。
    try {
      final ok = await _openNative(
        url,
        title: title,
        positionMs: positionMs,
        package: target,
      );
      if (ok != null) {
        AppLog.i(
          _tag,
          '唤起外部播放器(原生) package=${target ?? 'chooser'} '
          'scheme=${uri.scheme} ok=$ok',
        );
        if (!ok) AppLog.w(_tag, '原生通道未拉起外部播放器（未安装或 MIME 不匹配）');
        return ok;
      }
    } catch (e) {
      AppLog.w(_tag, '原生通道不可用，回退 intent URI：$e');
    }
    // 兜底：老版宿主未注册原生方法时用 intent URI（部分系统可解析）。
    try {
      final intentUrl = _buildIntent(
        uri,
        title: title,
        positionMs: positionMs,
        package: target,
      );
      AppLog.i(_tag, '唤起外部播放器(intent URI) scheme=${uri.scheme}');
      final ok = await launchUrl(
        Uri.parse(intentUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) AppLog.w(_tag, 'launchUrl 返回 false');
      return ok;
    } catch (e) {
      AppLog.e(_tag, '唤起外部播放器失败', e);
      return false;
    }
  }

  /// 调用原生标准 Intent 拉起播放器。返回 null 表示原生方法不可用（老宿主）。
  static Future<bool?> _openNative(
    String url, {
    String? title,
    int positionMs = 0,
    String? package,
  }) async {
    return await _installChannel.invokeMethod<bool>(
      'openWithExternalPlayer',
      <String, dynamic>{
        'url': url,
        'title': title,
        'positionMs': positionMs,
        'package': package,
      },
    );
  }

  /// 拼装 Android intent URI。
  ///
  /// `intent://host/path?#Intent;...;end` 会被 Android 解析成
  /// `ACTION_VIEW` + data=`scheme://host/path` 的 Intent。fragment 里的
  /// `;` / `=` 是语法分隔符，不能整体 percent-encode，只有 extra 的值需要。
  /// 不写 `package=` 时由系统弹出选择器。
  static String _buildIntent(
    Uri media, {
    String? title,
    int positionMs = 0,
    String? package,
  }) {
    final scheme = media.scheme;
    // 用规范化后的 URL 去掉 scheme 前缀，保留 host/path/query 的编码形式。
    final normalized = media.toString();
    final dataPart = normalized.substring(
      scheme.length + (normalized.startsWith('$scheme://') ? 3 : 0),
    );

    final parts = <String>[
      'action=android.intent.action.VIEW',
      if (package != null && package.isNotEmpty) 'package=$package',
      'scheme=$scheme',
      'type=video/*',
      if (title != null && title.isNotEmpty)
        'S.title=${Uri.encodeComponent(title)}',
      if (positionMs > 0) 'i.position=$positionMs',
    ];
    final fragment = 'Intent;${parts.join(';')};end';
    return 'intent://$dataPart#$fragment';
  }
}
