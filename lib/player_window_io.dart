import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/logging/app_log.dart';
import 'core/net/app_http.dart';
import 'core/platform/player_engine.dart';
import 'core/platform/player_window.dart';
import 'core/platform/portable_app_data.dart';
import 'core/platform/window_service.dart';
import 'core/theme/app_theme.dart';
import 'services/cms_source.dart';
import 'services/jar_spider_service.dart';
import 'services/js_spider_service.dart';
import 'services/live_service.dart';
import 'services/local_store.dart';
import 'services/player/external_playlist.dart';
import 'services/player/player_window_session.dart';
import 'services/py_spider_service.dart';
import 'services/relay/local_relay.dart';
import 'services/relay/proxy_rules.dart';
import 'services/search_service.dart';
import 'services/source_service.dart';
import 'services/support_dir_migration.dart';
import 'state/app_state.dart';
import 'ui/pages/live_player_page.dart';
import 'ui/pages/player_page.dart';

/// 独立播放器子窗口的完整启动流程。
///
/// 它跑在独立的 Flutter 引擎/isolate 里：重新创建一套 AppState、服务与
/// 本机中继（9978 被主窗口占用时自动换临时端口），然后只渲染播放器页。
/// 主窗口的 UI 不会被遮挡。
Future<void> runStandalonePlayerWindow(String payloadPath) async {
  setupPlayerEngine();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSizeBytes = 48 << 20;
  imageCache.maximumSize = 220;

  String? supportPath;
  if (!kIsWeb) {
    supportPath = await enablePortableAppData();
    supportPath ??= (await getApplicationSupportDirectory()).path;
    await migrateLegacySupportDir(supportPath);
  }
  await AppLog.init(supportDir: supportPath);
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLog.e('flutter', '独立播放器窗口 Flutter 异常', details.exception, details.stack);
  };

  final payload = PlayerWindowPayload.decode(await _readPayload(payloadPath));
  if (payload == null) {
    AppLog.e('window', '独立播放器窗口载荷无效 $payloadPath');
    await setupStandalonePlayerWindow(title: 'MisaTV 播放器');
    runApp(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Text('播放会话已失效', style: TextStyle(color: Colors.white70)),
          ),
        ),
      ),
    );
    return;
  }

  final store = await LocalStore.create();
  final http = AppHttp();
  final driveTokens = <String, String>{};
  final driveSeed = <String, String>{};
  final sourceService = SourceService(
    CmsSource(http),
    JsSpiderService(driveTokens: () => driveTokens, localSeed: () => driveSeed),
    PySpiderService(driveTokens: () => driveTokens),
    createJarSpiderService(
      driveTokens: () => driveTokens,
      driveSeed: () => driveSeed,
      http: http,
    ),
  );
  final state = AppState(
    store: store,
    http: http,
    sourceService: sourceService,
    searchService: SearchService(sourceService),
    liveService: LiveService(http, sourceService),
    driveTokens: driveTokens,
  );
  sourceService.jar.refreshDriveSession = state.refreshDriveSession;
  await state.init(playerWindow: true);
  driveSeed.addAll(state.driveLocalSeed);
  state.addListener(
    () => driveSeed
      ..clear()
      ..addAll(state.driveLocalSeed),
  );

  final support = supportPath ?? (await getApplicationSupportDirectory()).path;
  final externalPlaylist = ExternalPlaylistService(
    sourceService: sourceService,
    parseService: state.parseService,
    config: () => state.config,
    jarReady: () => state.jarReady,
    preparePlay: state.preparePlay,
    unwrapPlayPage: state.unwrapPlayPage,
    warmUp: sourceService.jar.warmUpLocalPlayUrl,
    holdExternal: sourceService.jar.holdPlaybackForExternal,
    supportDir: support,
    relayBaseUrl: () => LocalRelay.instance.baseUrl,
  );
  state.externalPlaylist = externalPlaylist;
  await LocalRelay.instance.start(
    fileRoot: support,
    driveTokens: () => state.driveTokens,
    rules: () => state.config?.rules ?? const [],
    purifyEnabled: () => state.playerSettings.m3u8Purify,
    davAuth: (id) => state.davService.authHeader(id),
    jvmProxyPort: () => sourceService.jar.activeHostProxyPort,
    externalEpisodeResolver: externalPlaylist.resolveEpisode,
  );
  ProxyRules.relayBase = () => LocalRelay.instance.baseUrl;

  var closed = false;
  Future<void> shutdown() async {
    if (closed) return;
    closed = true;
    try {
      await sourceService.shutdown();
    } catch (_) {}
    try {
      await LocalRelay.instance.stop();
    } catch (_) {}
    await notifyMainPlayerWindow('closed');
    await deletePlayerWindowPayload(payloadPath);
  }

  Future<void> close() async {
    await shutdown();
    await closeStandalonePlayerWindowNow();
  }

  await registerPlayerWindowControls(onClose: close);
  final title = payload.kind == 'vod'
      ? 'MisaTV · ${payload.vod?.detail.name ?? ''}'
      : 'MisaTV · ${payload.live?.channel.name ?? ''}';
  await setupStandalonePlayerWindow(title: _clipTitle(title));
  runApp(
    AppScope(
      state: state,
      child: _StandalonePlayerApp(
        state: state,
        payload: payload,
        onExit: close,
        onShutdown: shutdown,
      ),
    ),
  );
}

String _clipTitle(String value) {
  final text = value.trim();
  if (text.length <= 60) return text;
  return '${text.substring(0, 57)}…';
}

Future<String> _readPayload(String path) async {
  try {
    return await File(path).readAsString();
  } catch (_) {
    return '';
  }
}

class _StandalonePlayerApp extends StatefulWidget {
  const _StandalonePlayerApp({
    required this.state,
    required this.payload,
    required this.onExit,
    required this.onShutdown,
  });

  final AppState state;
  final PlayerWindowPayload payload;
  final Future<void> Function() onExit;
  final Future<void> Function() onShutdown;

  @override
  State<_StandalonePlayerApp> createState() => _StandalonePlayerAppState();
}

class _StandalonePlayerAppState extends State<_StandalonePlayerApp>
    with WindowListener {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(_close());
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await widget.onShutdown();
    } finally {
      await closeStandalonePlayerWindowNow();
    }
  }

  Future<void> _switchSource(String keyword) async {
    await notifyMainPlayerWindow('search', arguments: {'keyword': keyword});
    await _close();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(state.accentColor, Brightness.light),
        darkTheme: AppTheme.build(state.accentColor, Brightness.dark),
        themeMode: state.themeMode,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // 无边框子窗口没有系统边缘，缩放交给 `windowFrame` 的 Flutter 边缘层。
        home: windowFrame(_home()),
      ),
    );
  }

  Widget _home() {
    final payload = widget.payload;
    final vod = payload.vod;
    if (vod != null) {
      return PlayerPage(
        session: PlayerSession(
          detail: vod.detail,
          site: vod.site,
          flag: vod.flag,
          episodeIndex: vod.episodeIndex,
          episodes: vod.episodes,
          initialPlay: vod.initialPlay,
          startPositionMs: vod.startPositionMs,
          ephemeral: vod.ephemeral,
        ),
        onExit: widget.onExit,
        onSwitchSource: _switchSource,
        onVideoAspect: fitAppWindowToVideo,
      );
    }
    final live = payload.live;
    if (live != null) {
      return LivePlayerPage(
        bean: live.bean,
        channel: live.channel,
        initialLine: live.initialLine,
        epg: live.epg,
        groups: live.groups,
        epgEntries: live.epgEntries,
        initialGroup: live.initialGroup,
        onExit: widget.onExit,
      );
    }
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text('没有可播放的会话', style: TextStyle(color: Colors.white70)),
      ),
    );
  }
}
