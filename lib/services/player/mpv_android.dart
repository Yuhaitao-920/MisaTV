import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/logging/app_log.dart';

/// 用 Android 上的 FongMi/mpv-android（`is.xyz.mpv`）外部播放器打开片源。
///
/// mpv-android 不是可导入的 AAR，只能通过标准 `ACTION_VIEW` Intent 唤起：
///   - package: `is.xyz.mpv`
///   - data: http/https/ftp 等 URI，MIME 用 `video/any` 强制交给 mpv
///   - extras: `title`(String)、`position`(Int, 毫秒)
///
/// 注意：Intent 不支持传自定义 HTTP header。需要 Referer/UA 的片源，
/// 调用方应先用 MisaTV 的本机中继（`/chunk` 或 `LocalRelay`）把远端流包成
/// 本机地址，再把该地址交给这里。
///
/// 桌面 / Web 上本工具不可用，调用方需用 [supported] 判断。
class MpvAndroid {
  MpvAndroid._();

  /// mpv-android 的包名。
  static const String package = 'is.xyz.mpv';
  static const String _tag = 'mpv-android';

  /// 当前平台是否支持（仅 Android；Web / 桌面一律 false）。
  static bool get supported => defaultTargetPlatform == TargetPlatform.android;

  /// mpv-android 是否已安装（软检测）。
  ///
  /// Android 11+ 的包可见性限制要求在 AndroidManifest 的 `<queries>` 里声明
  /// `is.xyz.mpv`，否则 `canLaunchUrl` 会误报未安装。即便返回 false，
  /// [open] 仍会尝试拉起，失败由调用方回落内置播放器。
  static Future<bool> isInstalled() async {
    if (!supported) return false;
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

  /// 用 mpv-android 打开 [url]。
  ///
  /// [title] 作为媒体标题显示；[positionMs] 为起播位置（毫秒）。
  /// 返回是否成功把 intent 交给系统。
  static Future<bool> open(
    String url, {
    String? title,
    int positionMs = 0,
  }) async {
    if (!supported) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      AppLog.w(_tag, '无效播放地址：$url');
      return false;
    }
    try {
      final intentUrl = _buildIntent(uri, title: title, positionMs: positionMs);
      AppLog.i(_tag, '唤起 mpv-android scheme=${uri.scheme}');
      final ok = await launchUrl(
        Uri.parse(intentUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) AppLog.w(_tag, 'launchUrl 返回 false');
      return ok;
    } catch (e) {
      AppLog.e(_tag, '唤起 mpv-android 失败', e);
      return false;
    }
  }

  /// 拼装 Android intent URI。
  ///
  /// `intent://host/path?#Intent;...;end` 会被 Android 解析成
  /// `ACTION_VIEW` + data=`scheme://host/path` 的 Intent。fragment 里的
  /// `;` / `=` 是语法分隔符，不能整体 percent-encode，只有 extra 的值需要。
  static String _buildIntent(
    Uri media, {
    String? title,
    int positionMs = 0,
  }) {
    final scheme = media.scheme;
    // 用规范化后的 URL 去掉 scheme 前缀，保留 host/path/query 的编码形式。
    final normalized = media.toString();
    final dataPart = normalized.substring(
      scheme.length + (normalized.startsWith('$scheme://') ? 3 : 0),
    );

    final parts = <String>[
      'action=android.intent.action.VIEW',
      'package=$package',
      'scheme=$scheme',
      'type=video/any',
      if (title != null && title.isNotEmpty)
        'S.title=${Uri.encodeComponent(title)}',
      if (positionMs > 0) 'i.position=$positionMs',
    ];
    final fragment = 'Intent;${parts.join(';')};end';
    return 'intent://$dataPart#$fragment';
  }
}
