import 'dart:convert';

import '../core/utils/text_utils.dart';
import '../models/vod.dart';

/// 把 JS/PY 蜘蛛 `playerContent` / `play` 的返回（JSON 文本或裸地址）
/// 归一化为 [PlayResult]（对齐 TVBox 安卓契约）。
PlayResult normalizeSpiderPlay(String text, String flag) {
  final t = text.trim();
  if (t.isEmpty) {
    return PlayResult(url: '', flag: flag, message: '蜘蛛没有返回播放地址');
  }
  final decoded = _tryDecode(t);
  if (decoded == null) {
    if (isLikelyVideoPage(t)) {
      return PlayResult(
        url: splitUrlHeadersClean(t),
        parse: 1,
        flag: flag,
        message: '该线路是网页播放页，正在尝试解析',
      );
    }
    if (isPlayableMediaUrl(t)) return directPlay(t, flag);
    return PlayResult(url: '', flag: flag, message: '蜘蛛返回了无法识别的播放信息');
  }
  if (decoded is Map && decoded['__error'] != null) {
    return PlayResult(
      url: '',
      flag: flag,
      message: '蜘蛛返回错误：${decoded['__error']}',
    );
  }
  if (decoded is List) {
    for (final item in decoded) {
      final url = item.toString().trim();
      if (isLikelyVideoPage(url)) {
        return PlayResult(
          url: splitUrlHeadersClean(url),
          parse: 1,
          flag: flag,
          message: '该线路是网页播放页，正在尝试解析',
        );
      }
      if (isPlayableMediaUrl(url)) return directPlay(url, flag);
    }
    return PlayResult(url: '', flag: flag, message: '蜘蛛没有返回可播放地址');
  }
  if (decoded is! Map) {
    if (decoded is String && isLikelyVideoPage(decoded)) {
      return PlayResult(
        url: splitUrlHeadersClean(decoded),
        parse: 1,
        flag: flag,
        message: '该线路是网页播放页，正在尝试解析',
      );
    }
    if (decoded is String && isPlayableMediaUrl(decoded)) {
      return directPlay(decoded, flag);
    }
    return PlayResult(url: '', flag: flag, message: '蜘蛛返回了无法识别的播放信息');
  }
  final map = Map<String, dynamic>.from(decoded);
  final declared = map['parse'];
  final parse = declared == null || '$declared'.isEmpty
      ? 0
      : int.tryParse('$declared') ?? 0;
  final msg = (map['msg'] ?? '').toString().trim();

  final rawUrl = map['url'];
  if (rawUrl is List) {
    for (final item in rawUrl) {
      final candidate = item.toString().trim();
      if (isPlayableMediaUrl(candidate)) return directPlay(candidate, flag);
    }
    return PlayResult(
      url: '',
      flag: flag,
      message: msg.isEmpty ? '蜘蛛没有返回可播放地址' : msg,
    );
  }
  var url = (rawUrl ?? '').toString().trim();
  if (url.isEmpty) {
    return PlayResult(
      url: '',
      flag: flag,
      message: msg.isEmpty ? '蜘蛛没有返回播放地址' : msg,
    );
  }
  final plain = splitUrlHeadersClean(url);
  if (RegExp(r'^magnet:', caseSensitive: false).hasMatch(plain) ||
      RegExp(r'^ed2k://', caseSensitive: false).hasMatch(plain)) {
    // 磁力/电驴链接不是普通直链，但也不能当「占位视频」丢掉：
    // 交给上层的内置 BT 引擎播放（「新6V|磁力」这类源就是这么做）。
    return PlayResult(
      url: '',
      flag: flag,
      message: msg.isEmpty ? '磁力/电驴链接由内置 BT 引擎播放' : msg,
      externalLink: plain,
    );
  }
  final headers = <String, String>{...splitUrlHeaders(url)};
  final explicit = map['header'] ?? map['headers'];
  if (explicit is Map) {
    explicit.forEach((k, v) {
      if (v != null) headers[k.toString()] = v.toString();
    });
  } else if (explicit is String && explicit.trim().isNotEmpty) {
    final parsed = _tryDecode(explicit);
    if (parsed is Map) {
      parsed.forEach((k, v) {
        if (v != null) headers[k.toString()] = v.toString();
      });
    }
  }
  if (url.startsWith('video://')) {
    return PlayResult(
      url: '',
      parse: 1,
      flag: flag,
      headers: headers,
      message: msg.isEmpty ? '该地址需要网页嗅探，内置播放器暂不支持' : msg,
    );
  }
  if (url.startsWith('proxy://')) {
    return PlayResult(
      url: '',
      flag: flag,
      message: msg.isEmpty ? '该源需要蜘蛛本地代理路由' : msg,
    );
  }
  if (parse != 0) {
    // 解析目标必须是蜘蛛返回的页面地址（不能只留空让上层拿选集参数当目标）。
    // headers 必须一并保留：网页嗅探会用它带源内 UA / Referer，丢了就容易被
    // PandaLive 这类站点判定为桌面访客/验证页。
    return PlayResult(
      url: splitUrlHeadersClean(url),
      parse: parse,
      flag: flag,
      headers: headers,
      message: msg.isEmpty ? '该资源需要 VIP/第三方解析（$parse）' : msg,
    );
  }
  final clean = splitUrlHeadersClean(url);
  if (isLikelyVideoPage(clean)) {
    // 网页播放页（腾讯/爱奇艺/优酷…）即使蜘蛛写了 parse=0 也不能直连播放器，
    // 改走解析接口 / 网页嗅探。
    return PlayResult(
      url: clean,
      parse: 1,
      flag: flag,
      headers: headers,
      message: msg.isNotEmpty ? msg : '该线路是网页播放页，正在尝试解析',
    );
  }
  if (!isPlayableMediaUrl(clean)) {
    // 把源内选集参数、占位视频、相对路径挡在播放器之外；否则会打开
    // 一个“能创建播放器但永远没画面”的假播放页。
    return PlayResult(
      url: '',
      parse: parse == 0 ? 1 : parse,
      flag: flag,
      headers: headers,
      message: msg.isNotEmpty ? msg : '蜘蛛返回的地址不是可播放直链（可能是选集参数或占位视频）',
    );
  }
  return PlayResult(url: clean, flag: flag, headers: headers, message: msg);
}

PlayResult directPlay(String raw, String flag) {
  final headers = splitUrlHeaders(raw);
  return PlayResult(
    url: splitUrlHeadersClean(raw),
    flag: flag,
    headers: headers,
  );
}

dynamic _tryDecode(String text) {
  final t = text.trim();
  if (!(t.startsWith('{') || t.startsWith('['))) return null;
  try {
    return jsonDecode(t);
  } catch (_) {
    return null;
  }
}
