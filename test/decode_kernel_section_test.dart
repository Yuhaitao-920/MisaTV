import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/app.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/core/theme/app_theme.dart';
import 'package:kniephos/services/cms_source.dart';
import 'package:kniephos/services/jar_spider_service.dart';
import 'package:kniephos/services/js_spider_service.dart';
import 'package:kniephos/services/live_service.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:kniephos/services/py_spider_service.dart';
import 'package:kniephos/services/search_service.dart';
import 'package:kniephos/services/source_service.dart';
import 'package:kniephos/state/app_state.dart';
import 'package:kniephos/ui/pages/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「设置 → 播放与外观 → 解码内核」的平台门控。
///
/// 该分区讲的是「FFmpeg/libmdk 与系统 ExoPlayer 二选一」，而 ExoPlayer 只存在于
/// Android：桌面端固定走 FFmpeg/libmdk，`player_page._ensureFvp()` 在非 Android
/// 直接 return。如果这一区在桌面端也显示，用户点开一个不起作用的开关、
/// 还会看到不存在的「系统 ExoPlayer」，属于误导。
Future<AppState> _app() async {
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

Future<void> _openPlaySection(WidgetTester tester, AppState app) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final base = AppTheme.build(app.accentColor, Brightness.dark);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: AppTheme.fontFamily),
  );

  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        theme: theme,
        home: const Scaffold(body: SettingsPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('播放与外观').first);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('解码内核分区在 Windows 上不显示', (tester) async {
    // 平台覆盖必须在用例体内复位：Flutter 在 body 结束时校验 foundation
    // 调试变量，放到 tearDown 里已经太晚。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _openPlaySection(tester, await _app());

      expect(find.text('解码内核'), findsNothing);
      // 相邻分区仍在，说明只是这一个被隐藏，而不是整页没渲染出来。
      expect(find.text('缓冲与缓存'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('解码内核分区在 Android 上显示', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await _openPlaySection(tester, await _app());

      expect(find.text('解码内核'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
