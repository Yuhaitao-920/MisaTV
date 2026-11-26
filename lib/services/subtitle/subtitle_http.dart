/// 网页字幕源共用的极简 HTTP 取字节/取文本（UA / Referer / 超时 / 体积上限）。
///
/// 只用项目已依赖的 `package:http`；失败返回 null 不抛（与旧版 http.ts 一致）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const String browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const int _htmlMax = 4 * 1024 * 1024;
const int _fileMax = 20 * 1024 * 1024;

/// 原始响应（需要看状态码时使用，assrt API 依赖它区分 400 / 其它）。
class SubtitleHttpResponse {
  const SubtitleHttpResponse(this.statusCode, this.bytes);

  final int statusCode;
  final List<int> bytes;
}

class SubtitleHttp {
  SubtitleHttp({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// 取原始响应；网络异常/超时返回 null。
  Future<SubtitleHttpResponse?> getResponse(
    String url, {
    String? referer,
    bool html = false,
    int? maxBytes,
    Map<String, String>? headers,
  }) async {
    final max = maxBytes ?? (html ? _htmlMax : _fileMax);
    try {
      final res = await _client
          .get(
            Uri.parse(url),
            headers: <String, String>{
              'User-Agent': browserUserAgent,
              'Accept': html
                  ? 'text/html,application/xhtml+xml,*/*;q=0.8'
                  : '*/*',
              'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
              if (referer != null && referer.isNotEmpty) 'Referer': referer,
              ...?headers,
            },
          )
          .timeout(timeout);
      final bytes = res.bodyBytes;
      if (bytes.isEmpty || bytes.length > max) return null;
      return SubtitleHttpResponse(res.statusCode, bytes);
    } catch (_) {
      return null;
    }
  }

  /// 取二进制（字幕包/字幕文件）；取不到/超限返回 null。
  Future<List<int>?> getBytes(
    String url, {
    String? referer,
    int? maxBytes,
    Map<String, String>? headers,
  }) async {
    final res = await getResponse(
      url,
      referer: referer,
      maxBytes: maxBytes,
      headers: headers,
    );
    return res != null && res.statusCode == 200 ? res.bytes : null;
  }

  /// 取 HTML 文本（UTF-8；取不到/超限返回 null）。
  Future<String?> getText(
    String url, {
    String? referer,
    Map<String, String>? headers,
  }) async {
    final res = await getResponse(
      url,
      referer: referer,
      html: true,
      headers: headers,
    );
    if (res == null || res.statusCode != 200) return null;
    final text = utf8.decode(res.bytes, allowMalformed: true);
    return text.trim().isEmpty ? null : text;
  }
}
