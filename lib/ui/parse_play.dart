import 'package:flutter/material.dart';

import '../models/site_config.dart';
import '../models/vod.dart';
import '../services/parse/hhplayer_native.dart';
import '../state/app_state.dart';
import 'widgets/web_sniffer.dart';

/// 对 `parse != 0` 的播放结果执行解析接口 / 网页嗅探。
///
/// 成功返回 `parse: 0` 的直链；失败保留原因供 UI 上屏。
Future<PlayResult> resolveParsedPlay(
  BuildContext context,
  AppState app,
  SourceBean site,
  PlayResult play, {
  required String rawUrl,
}) async {
  if (play.parse == 0 || play.externalLink.isNotEmpty) return play;
  final target = play.url.trim().isNotEmpty ? play.url.trim() : rawUrl.trim();
  if (target.isEmpty) {
    return PlayResult(
      url: '',
      flag: play.flag,
      parse: play.parse,
      message: play.message.isEmpty ? '没有可解析的播放地址' : play.message,
    );
  }
  // Kazumi 规则源：播放页固定交给网页嗅探，不走解析接口（接口会把播放页
  // 当普通视频页签解析，命中率极低且会把地址带偏）。
  if (site.isKazumi) {
    final hit = await sniffWebMedia(
      context,
      target,
      timeout: const Duration(seconds: 28),
      headers: app.sourceService.kazumi.headersFor(site),
    );
    if (hit != null && hit.url.trim().isNotEmpty) {
      return PlayResult(
        url: hit.url,
        flag: play.flag,
        headers: hit.headers,
        message: '',
      );
    }
    return PlayResult(
      url: '',
      flag: play.flag,
      message: play.message.isNotEmpty
          ? '${play.message}；网页嗅探没有找到可播放地址'
          : '网页嗅探没有找到可播放地址（可能需要登录或站点有验证）',
    );
  }
  // 巴士动漫（Dm84）返回的 hhplayer 页面自带 bootstrap，按页面自己的
  // JSON POST 重新解析可绕开失效的旧 jar 请求。
  if (Uri.tryParse(target)?.host.toLowerCase() == 'hhjx.hhplayer.com') {
    final direct = await HhplayerNative(app.parseService.http)
        .resolve(target, headers: play.headers);
    if (direct != null) {
      return PlayResult(url: direct, flag: play.flag, headers: play.headers);
    }
  }
  final hit = await app.parseService.resolve(
    app.config?.parses ?? const <ParseBean>[],
    target,
    // 蜘蛛返回的 UA / Referer 也要带进嗅探窗口：PandaLive 这类站点用桌面
    // UA 会拿到验证页，必须有源内 UA 才可能出 m3u8。
    sniff: (url) =>
        sniffWebMedia(context, url, click: site.click, headers: play.headers),
  );
  if (hit == null) {
    return PlayResult(
      url: '',
      flag: play.flag,
      parse: play.parse,
      message: play.message.isNotEmpty
          ? '${play.message}；解析接口与网页嗅探都没有找到可播放地址'
          : '解析失败：解析接口与网页嗅探都没有找到可播放地址',
    );
  }
  return PlayResult(
    url: hit.url,
    flag: play.flag,
    headers: hit.headers,
    message: '',
  );
}
