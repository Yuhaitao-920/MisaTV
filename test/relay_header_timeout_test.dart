import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证 `HttpClient.connectionTimeout` 不覆盖「连上了但对方不发响应头」这一段。
///
/// 这是 `/play` 上游挂起的根因：`_openFollow` 原本直接 `await req.close()`，
/// 没有任何上限。实测日志里出现「开始打开」后 51 秒零输出、连 25 秒的
/// initialize 超时都没触发过。
void main() {
  test('connectionTimeout 不覆盖响应头等待（证明必须自己加 timeout）', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final sockets = <Socket>[];
    server.listen(sockets.add); // 只 accept，永不回包

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 1);
    final sw = Stopwatch()..start();
    var timedOut = false;
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/x'),
      );
      // 不自己加 timeout 的话这里会一直挂着
      await req.close().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      timedOut = true;
    }
    sw.stop();
    // ignore: avoid_print
    print('connectionTimeout=1s，req.close() 实际耗时 ${sw.elapsedMilliseconds}ms');
    expect(
      timedOut,
      isTrue,
      reason: 'connectionTimeout 只覆盖 TCP 建连，响应头等待需要调用方自己限时',
    );

    for (final s in sockets) {
      try {
        s.destroy();
      } catch (_) {}
    }
    client.close(force: true);
    await server.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('自己加 timeout + abort 能按时退出', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final sockets = <Socket>[];
    server.listen(sockets.add);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 1);
    final sw = Stopwatch()..start();
    var caught = false;
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/x'),
      );
      try {
        await req.close().timeout(const Duration(seconds: 1));
      } on TimeoutException {
        req.abort();
        caught = true;
      }
    } catch (_) {
      caught = true;
    }
    sw.stop();
    // ignore: avoid_print
    print('加 timeout+abort 后耗时 ${sw.elapsedMilliseconds}ms');
    expect(caught, isTrue);
    expect(
      sw.elapsedMilliseconds,
      lessThan(2500),
      reason: '应在 timeout 附近退出，不该等满整个连接生命周期',
    );

    for (final s in sockets) {
      try {
        s.destroy();
      } catch (_) {}
    }
    client.close(force: true);
    await server.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
