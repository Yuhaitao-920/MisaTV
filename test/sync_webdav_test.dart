import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/app.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/models/dav.dart';
import 'package:kniephos/models/user_data.dart';
import 'package:kniephos/services/cms_source.dart';
import 'package:kniephos/services/jar_spider_service.dart';
import 'package:kniephos/services/js_spider_service.dart';
import 'package:kniephos/services/live_service.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:kniephos/services/py_spider_service.dart';
import 'package:kniephos/services/search_service.dart';
import 'package:kniephos/services/source_service.dart';
import 'package:kniephos/state/app_state.dart';
import 'package:kniephos/ui/pages/sync_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 两台「设备」共用同一个本地 WebDAV 服务时的真实同步流程。
///
/// 覆盖设置页最容易出问题的链路：GET 404 → 合并本机 → MKCOL + PUT，
/// 另一台设备再 GET → 合并进本地历史。
Future<AppState> _newApp() async {
  final http = AppHttp();
  final tokens = <String, String>{};
  final source = SourceService(
    CmsSource(http),
    JsSpiderService(
      driveTokens: () => tokens,
      localSeed: () => <String, String>{},
    ),
    PySpiderService(driveTokens: () => tokens),
    JarSpiderService(
      driveTokens: () => tokens,
      driveSeed: () => <String, String>{},
      http: http,
    ),
  );
  return AppState(
    store: await LocalStore.create(),
    http: http,
    sourceService: source,
    searchService: SearchService(source),
    liveService: LiveService(http, source),
    driveTokens: tokens,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  final files = <String, String>{};
  final dirs = <String>{'/dav'};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // flutter_test 默认把 HttpClient 换成「一律失败」的桩。
    HttpOverrides.global = null;
    files.clear();
    dirs
      ..clear()
      ..add('/dav');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      if (req.method == 'MKCOL') {
        final dir = path.replaceAll(RegExp(r'/+$'), '');
        req.response.statusCode = dirs.add(dir) ? 201 : 405;
        await req.response.close();
        return;
      }
      if (req.method == 'PUT') {
        final cut = path.lastIndexOf('/');
        final parent = cut <= 0 ? '' : path.substring(0, cut);
        final body = await utf8.decoder.bind(req).join();
        if (!dirs.contains(parent)) {
          req.response.statusCode = 409;
        } else {
          files[path] = body;
          req.response.statusCode = 201;
        }
        await req.response.close();
        return;
      }
      final body = files[path];
      req.response.statusCode = body == null ? 404 : 200;
      if (body != null) req.response.write(body);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('两台设备通过 WebDAV 互相同步历史', () async {
    DavServer serverOf() => DavServer(
      id: '',
      name: 'local',
      url: 'http://127.0.0.1:${server.port}/dav',
      username: 'u',
      password: 'p',
    );

    final a = await _newApp();
    final savedA = await a.saveDavServer(serverOf());
    a.history = [
      HistoryItem(
        key: 'demo|1',
        name: '测试影片',
        updatedAt: 1700000000000,
        episodeName: '第1集',
      ),
    ];
    final reportA = await a.syncViaWebDav(serverId: savedA.id);
    expect(reportA.pushed, isTrue);
    expect(files['/dav/MisaTV/sync.json'], contains('测试影片'));
    expect(a.syncSettings.lastSyncAt, greaterThan(0));

    // 模拟另一台全新设备：本地存储清空，只保留同一个 WebDAV 地址。
    SharedPreferences.setMockInitialValues({});
    final b = await _newApp();
    final savedB = await b.saveDavServer(serverOf());
    await b.syncViaWebDav(serverId: savedB.id);
    expect(b.history.any((e) => e.name == '测试影片'), isTrue);
  });

  testWidgets('只有一个 WebDAV 服务器时同步页自动选中，不再要求手动选择', (tester) async {
    final app = await _newApp();
    await app.saveDavServer(
      DavServer(
        id: '',
        name: 'local',
        url: 'http://127.0.0.1:${server.port}/dav',
        username: 'u',
        password: 'p',
      ),
    );
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: const MaterialApp(home: SyncPage()),
      ),
    );
    await tester.pumpAndSettle();
    // 下拉框直接显示唯一服务器（FormField 只在创建时读取 initialValue，
    // 旧实现会让这里保持空白，点「立即同步」只会提示请先选择服务器）。
    expect(find.text('local'), findsOneWidget);
    expect(find.text('立即同步'), findsOneWidget);
  });
}
