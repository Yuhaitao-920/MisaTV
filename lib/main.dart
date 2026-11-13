import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/logging/app_log.dart';
import 'core/net/app_http.dart';
import 'core/net/proxy_runtime.dart';
import 'core/platform/player_engine.dart';
import 'core/platform/player_window.dart';
import 'core/platform/portable_app_data.dart';
import 'core/platform/window_service.dart';
import 'player_window.dart';
import 'models/site_config.dart';
import 'models/vod.dart';
import 'services/boss_key/boss_key_service.dart';
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
import 'services/torrent/torrent_play.dart';
import 'state/app_state.dart';

void main(List<String> args) {
  runZonedGuarded(() => _bootstrap(args), (error, stack) {
    AppLog.e('zone', '未捕获异常', error, stack);
  });
}

Future<void> _bootstrap(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 必须在任何 HttpClient 创建之前安装：之后 Dart / package:http 的网络请求
  // 都会按当前代理配置自动走本机 HTTP 代理桥（未启用时返回 DIRECT）。
  ProxyRuntime.installHttpOverrides();

  // desktop_multi_window 的子窗口会带着 `multi_window <id> <argument>` 参数
  // 重跑同一入口；参数里是带 `misa-player:` 前缀的载荷路径，两条入口都要先解前缀，
  // 否则子窗口会读一个不存在的文件、直接落到「播放会话已失效」。
  if (!kIsWeb) {
    final rawArgument = args.length >= 3 && args.first == 'multi_window'
        ? args[2]
        : await standalonePlayerWindowArgument();
    final playerPayload = standalonePlayerPayloadPath(rawArgument);
    if (playerPayload != null) {
      await runStandalonePlayerWindow(playerPayload);
      return;
    }
  }
  // 图片缓存默认 100MB / 1000 张，对桌面浏览来说过大；海报按卡片尺寸解码，
  // 48MB 足够覆盖几屏，避免长时间浏览后常驻内存不断攀升。
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSizeBytes = 48 << 20;
  imageCache.maximumSize = 220;

  // 关窗清理在下面补齐（服务初始化后接入）。
  Future<void> Function()? appShutdown;
  registerAppShutdown(() async {
    AppLog.i('app', '开始退出清理');
    await appShutdown?.call();
    await AppLog.flush();
  });

  setupPlayerEngine();

  // 数据与运行时默认放在软件安装目录（<exe>/userdata），实现便携/绿色版；
  // 安装目录不可写（Program Files 等）时回落到系统默认目录。
  // 改名 MisaTV 会改变 Windows 的默认应用数据目录（版本信息里的产品名），
  // 所以要在读取偏好与应用数据之前先把旧目录整体搬过来，否则订阅/登录态/运行时全丢。
  String? supportPath;
  if (!kIsWeb) {
    supportPath = await enablePortableAppData();
    supportPath ??= (await getApplicationSupportDirectory()).path;
    await migrateLegacySupportDir(supportPath);
  }
  await AppLog.init(supportDir: supportPath);
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLog.e('flutter', '未捕获的 Flutter 异常', details.exception, details.stack);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    AppLog.e('platform', '平台层异常', error, stack);
    return true;
  };
  AppLog.i('app', '日志目录: ${AppLog.directory}');

  final store = await LocalStore.create();
  // 窗口尺寸记忆存在便携目录的偏好里，必须等 LocalStore 就绪后再建窗口。
  await setupDesktopWindow(size: store.loadWindowSize());
  final http = AppHttp();
  final cms = CmsSource(http);
  final driveTokens = <String, String>{};
  final driveSeed = <String, String>{};
  final sourceService = SourceService(
    cms,
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
  // 播放失败时由 AppState 按需刷新网盘会话（夸克 `/member` 补发新 `__puus`）。
  sourceService.jar.refreshDriveSession = state.refreshDriveSession;
  await state.init();
  // 老板键 / 托盘：桌面端初始化；热键被占用等情况只记日志，不影响启动。
  if (!kIsWeb) await BossKeyService.instance.init(state);
  driveSeed.addAll(state.driveLocalSeed);
  state.addListener(
    () => driveSeed
      ..clear()
      ..addAll(state.driveLocalSeed),
  );

  if (!kIsWeb) {
    final support =
        supportPath ?? (await getApplicationSupportDirectory()).path;
    final torrentPlay = TorrentPlay(
      supportDir: support,
      downloadDir: state.playerSettings.magnetDownloadDir,
      customPlayers: () => state.customExternalPlayers,
      xunleiCloud: state.xunleiCloudService,
      logger: (message) => AppLog.i('bt', message),
    );
    state.torrentPlay = torrentPlay;
    // 第三方播放器的选集列表：M3U 里的每一项都回指本机中继，切集时按需解析。
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
      btSource: () => state.torrentPlay,
      jvmProxyPort: () => sourceService.jar.activeHostProxyPort,
      // 边播边缓存：目录固定放在应用数据下，开关与容量上限跟着设置实时走。
      cacheDir: () => p.join(support, 'cache', 'stream'),
      cacheEnabled: () => state.playerSettings.streamCache,
      cacheLimitMb: () => state.playerSettings.streamCacheMb,
      externalEpisodeResolver: externalPlaylist.resolveEpisode,
    );
    // 订阅里的代理规则（`rules[].hosts`）命中的请求走中继的通用代理口。
    ProxyRules.relayBase = () => LocalRelay.instance.baseUrl;
    appShutdown = () async {
      // 先关独立播放器窗口：它有自己的 JVM/中继，必须在进程退出前收尾。
      await closeAllStandalonePlayerWindows();
      await sourceService.shutdown();
      torrentPlay.dispose();
      state.xunleiCloudService.dispose();
      await LocalRelay.instance.stop();
    };
  } else {
    appShutdown = sourceService.shutdown;
  }

  // 子窗口关闭后把历史/设置同步回主窗口（两个引擎不共享内存对象）。
  await registerMainPlayerWindowBridge(
    onSync: state.reloadUserDataFromStore,
    onSearch: (keyword) async => state.requestSearch(keyword),
    onClosed: state.reloadUserDataFromStore,
  );

  runApp(KniephosApp(state: state));
  // 开发用冒烟钩子：`--dart-define=MISA_TEST_POPOUT=<视频地址>` 启动后自动弹一个
  // 独立播放器窗口，用来验证多窗口链路（正式构建不带这个 define，等于空操作）。
  const testPopoutUrl = String.fromEnvironment('MISA_TEST_POPOUT');
  if (testPopoutUrl.isNotEmpty) {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () async {
        final episodes = <Episode>[Episode(name: '第1集', url: testPopoutUrl)];
        await openStandalonePlayerWindow(
          payload: PlayerWindowPayload.vod(
            VodWindowSession(
              detail: VodDetail(
                id: 'test',
                name: '独立窗口测试',
                flags: ['测试线路'],
                episodes: {'测试线路': episodes},
                sourceKey: 'test',
              ),
              site: const SourceBean(
                key: 'test',
                name: '测试源',
                type: 0,
                api: '',
              ),
              flag: '测试线路',
              episodeIndex: 0,
              episodes: episodes,
              initialPlay: PlayResult(url: testPopoutUrl),
            ),
          ),
        );
      }),
    );
  }
  // 启动后在后台静默回源一次订阅；不阻塞首屏，失败继续用本地配置。
  state.startBackgroundTasks();
}
