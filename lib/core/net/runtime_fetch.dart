import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/app_log.dart';

/// 运行时组件（Python / JVM / 加固壳）下载的统一取件层。
///
/// 存在的理由：这些组件的下载原本各自 new 一个 `HttpClient`，只设了
/// `connectionTimeout`，没有「响应头超时」「静默超时」「重试」，也没有任何日志。
/// 一旦代理隧道断在半开状态，`await for (chunk in res)` 会永远挂着——界面上
/// 只剩一个不动的百分比，用户看不出是卡了、还是在下 4 MB 的 lxml。
///
/// 这里补上三件事：
///   · 响应头超时 + 数据静默超时（有数据就续期，慢速大文件不会被误杀）；
///   · 每个地址自动重试，失败换下一个镜像；
///   · 全流程写 AppLog，出问题能在 `userdata/logs/` 里看到是哪一步断的。
class RuntimeFetch {
  RuntimeFetch._();

  /// 等响应头的上限。镜像站偶发排队，给得比连接超时宽一点。
  static const headerTimeout = Duration(seconds: 30);

  /// 两次收到数据之间的最长间隔：超过就认为这条连接死了。
  /// 这是「卡死」与「慢」的分界——真的在下 lxml 时数据一直在流，不会触发。
  static const stallTimeout = Duration(seconds: 45);

  /// 单个地址的最多尝试次数（不含换镜像）。
  static const attemptsPerUrl = 2;

  static HttpClient newClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    // 关掉自动解压：我们要按 Content-Length 校验完整性，
    // 让 HttpClient 偷偷 gzip 解压会让字节数和声明对不上。
    ..autoUncompress = false
    ..userAgent = null;

  /// 取文本（PyPI simple 索引页）。
  ///
  /// 失败返回 null 而不是抛异常：调用方本来就要遍历多个镜像。
  static Future<String?> text(
    HttpClient http,
    Uri uri, {
    String tag = 'fetch',
    String userAgent = 'MisaTV/0.1',
  }) async {
    for (var attempt = 1; attempt <= attemptsPerUrl; attempt++) {
      try {
        final request = await http
            .getUrl(uri)
            .timeout(headerTimeout);
        request.headers
          ..set(HttpHeaders.userAgentHeader, userAgent)
          ..set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(headerTimeout);
        if (response.statusCode != 200) {
          await response.drain<void>().timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
          AppLog.w(tag, 'HTTP ${response.statusCode}：${_safe(uri)}');
          return null;
        }
        // 逐块读取并重置静默计时器：不能直接 join()，那等于无限期等待。
        final buffer = StringBuffer();
        await for (final chunk in response.timeout(stallTimeout)) {
          buffer.write(utf8.decode(chunk, allowMalformed: true));
        }
        return buffer.toString();
      } on TimeoutException {
        AppLog.w(tag, '读取索引超时（第 $attempt 次）：${_safe(uri)}');
      } catch (e) {
        AppLog.w(tag, '读取索引失败（第 $attempt 次）：${_safe(uri)}', e);
      }
    }
    return null;
  }

  /// 下载到文件。
  ///
  /// [minBytes] 用于把「下到一个错误页」和「真下到了」区分开；
  /// [onProgress] 拿到的比例可能为 null（服务器没给 Content-Length）。
  /// 返回实际写入的字节数；失败抛 [RuntimeFetchException]，调用方换镜像。
  static Future<int> file(
    HttpClient http,
    Uri uri,
    File target, {
    String tag = 'fetch',
    String userAgent = 'MisaTV/0.1',
    int minBytes = 1,
    void Function(int received, int? total)? onProgress,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= attemptsPerUrl; attempt++) {
      HttpClientRequest? request;
      try {
        request = await http.getUrl(uri).timeout(headerTimeout);
        request.headers
          ..set(HttpHeaders.userAgentHeader, userAgent)
          ..set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(headerTimeout);
        if (response.statusCode != 200) {
          await response.drain<void>().timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
          throw RuntimeFetchException('HTTP ${response.statusCode}');
        }
        // HttpClient 的 contentLength 在服务器没声明时是 -1，不是 null。
        final total = response.contentLength;
        target.parent.createSync(recursive: true);
        final temp = File('${target.path}.part');
        final sink = temp.openWrite();
        var received = 0;
        try {
          await for (final chunk in response.timeout(stallTimeout)) {
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received, total > 0 ? total : null);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (received < minBytes) {
          try {
            temp.deleteSync();
          } catch (_) {}
          throw RuntimeFetchException('内容过小（$received 字节 < $minBytes）');
        }
        // 只有确认下完才落到目标文件名：中途失败不会留下一个「看起来装好了」
        // 的残缺文件，下次进来还会重下。
        if (target.existsSync()) target.deleteSync();
        temp.renameSync(target.path);
        if (total > 0 && received != total) {
          AppLog.w(tag, '长度不符：${_safe(uri)} 收到 $received / 声明 $total');
        }
        return received;
      } on TimeoutException {
        lastError = '超时（${stallTimeout.inSeconds}s 无数据）';
        AppLog.w(tag, '下载超时（第 $attempt 次）：${_safe(uri)}');
      } catch (e) {
        lastError = e;
        AppLog.w(tag, '下载失败（第 $attempt 次）：${_safe(uri)}', e);
      } finally {
        // 请求已经发出但异常发生在 close()/读取阶段时，把连接掐掉，
        // 免得半开的 socket 留在连接池里污染后续请求。
        try {
          request?.abort();
        } catch (_) {}
      }
    }
    throw RuntimeFetchException('$lastError');
  }

  /// 按顺序尝试多个地址，返回第一个成功的下载字节数。
  ///
  /// [urls] 应当已经是「测速排序后」的列表；这里只负责逐个试并记录最后一个错误。
  static Future<int> fileFromAny(
    HttpClient http,
    List<String> urls,
    Future<File> Function(String url) targetOf, {
    String tag = 'fetch',
    String userAgent = 'MisaTV/0.1',
    int minBytes = 1,
    void Function(String url, int received, int? total)? onProgress,
  }) async {
    Object? lastError;
    for (final url in urls) {
      final target = await targetOf(url);
      try {
        return await file(
          http,
          Uri.parse(url),
          target,
          tag: tag,
          userAgent: userAgent,
          minBytes: minBytes,
          onProgress: (received, total) =>
              onProgress?.call(url, received, total),
        );
      } catch (e) {
        lastError = e;
        AppLog.w(tag, '线路失败，换下一个：${_safe(Uri.parse(url))}', e);
      }
    }
    throw RuntimeFetchException('$lastError');
  }

  /// 日志里的 URL 去掉 query，避免把 token / 签名写进日志。
  static String _safe(Uri uri) =>
      uri.hasQuery ? '${uri.origin}${uri.path}?…' : '${uri.origin}${uri.path}';
}

class RuntimeFetchException implements Exception {
  RuntimeFetchException(this.message);
  final String message;

  @override
  String toString() => message;
}
