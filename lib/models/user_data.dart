import 'player_fit.dart';

class FavoriteItem {
  const FavoriteItem({
    required this.key,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.sourceKey = '',
    this.sourceName = '',
    this.vodId = '',
    this.pic = '',
    this.remarks = '',
    this.year = '',
    this.type = '',
    this.title = '',
    this.note = '',
    this.updateSignature = '',
    this.hasUpdate = false,
    this.updateNote = '',
  });

  final String key;
  final String name;
  final int createdAt;
  final int updatedAt;
  final String sourceKey;
  final String sourceName;
  final String vodId;
  final String pic;
  final String remarks;
  final String year;
  final String type;
  final String title;
  final String note;

  /// 上次检查到的「备注 + 各线路集数/末集名」指纹；空 = 还没完成首次基线检查。
  final String updateSignature;

  /// 指纹变化后置 true，收藏页显示「有更新」；打开详情后清除。
  final bool hasUpdate;

  /// 更新提示（如「更新至 28 集」）。
  final String updateNote;

  String get displayTitle =>
      title.trim().isNotEmpty ? title.trim() : name.split(' - ').first.trim();

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'sourceKey': sourceKey,
    'sourceName': sourceName,
    'vodId': vodId,
    'pic': pic,
    'remarks': remarks,
    'year': year,
    'type': type,
    'title': title,
    'note': note,
    'updateSignature': updateSignature,
    'hasUpdate': hasUpdate,
    'updateNote': updateNote,
  };

  factory FavoriteItem.fromJson(Map<String, dynamic> j) => FavoriteItem(
    key: (j['key'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
    updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    sourceKey: (j['sourceKey'] ?? '').toString(),
    sourceName: (j['sourceName'] ?? '').toString(),
    vodId: (j['vodId'] ?? '').toString(),
    pic: (j['pic'] ?? '').toString(),
    remarks: (j['remarks'] ?? '').toString(),
    year: (j['year'] ?? '').toString(),
    type: (j['type'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    note: (j['note'] ?? '').toString(),
    updateSignature: (j['updateSignature'] ?? '').toString(),
    hasUpdate: (j['hasUpdate'] as bool?) ?? false,
    updateNote: (j['updateNote'] ?? '').toString(),
  );

  FavoriteItem copyWith({String? title, String? note}) => FavoriteItem(
    key: key,
    name: name,
    createdAt: createdAt,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    sourceKey: sourceKey,
    sourceName: sourceName,
    vodId: vodId,
    pic: pic,
    remarks: remarks,
    year: year,
    type: type,
    title: title ?? this.title,
    note: note ?? this.note,
    updateSignature: updateSignature,
    hasUpdate: hasUpdate,
    updateNote: updateNote,
  );

  /// 更新检查结果落库：不改 `updatedAt`（不是用户编辑）。
  FavoriteItem withUpdateCheck({
    required String signature,
    required bool hasUpdate,
    required String updateNote,
  }) => FavoriteItem(
    key: key,
    name: name,
    createdAt: createdAt,
    updatedAt: updatedAt,
    sourceKey: sourceKey,
    sourceName: sourceName,
    vodId: vodId,
    pic: pic,
    remarks: remarks,
    year: year,
    type: type,
    title: title,
    note: note,
    updateSignature: signature,
    hasUpdate: hasUpdate,
    updateNote: updateNote,
  );
}

class HistoryItem {
  const HistoryItem({
    required this.key,
    required this.name,
    required this.updatedAt,
    this.sourceKey = '',
    this.sourceName = '',
    this.vodId = '',
    this.pic = '',
    this.remarks = '',
    this.flag = '',
    this.episodeName = '',
    this.episodeIndex = 0,
    this.url = '',
    this.rawUrl = '',
    this.positionMs = 0,
    this.durationMs = 0,
  });

  final String key;
  final String name;
  final int updatedAt;
  final String sourceKey;
  final String sourceName;
  final String vodId;
  final String pic;
  final String remarks;
  final String flag;
  final String episodeName;
  final int episodeIndex;
  final String url;

  /// 原始集数地址（订阅里的播放页 / 提取码页）。
  ///
  /// 续播时优先用它重新取链：`url` 存的是解析后的播放地址，网盘源那种
  /// `127.0.0.1/chunk` 临时地址在 JVM 退出后就失效了。
  final String rawUrl;

  final int positionMs;
  final int durationMs;

  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'updatedAt': updatedAt,
    'sourceKey': sourceKey,
    'sourceName': sourceName,
    'vodId': vodId,
    'pic': pic,
    'remarks': remarks,
    'flag': flag,
    'episodeName': episodeName,
    'episodeIndex': episodeIndex,
    'url': url,
    'rawUrl': rawUrl,
    'positionMs': positionMs,
    'durationMs': durationMs,
  };

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
    key: (j['key'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    sourceKey: (j['sourceKey'] ?? '').toString(),
    sourceName: (j['sourceName'] ?? '').toString(),
    vodId: (j['vodId'] ?? '').toString(),
    pic: (j['pic'] ?? '').toString(),
    remarks: (j['remarks'] ?? '').toString(),
    flag: (j['flag'] ?? '').toString(),
    episodeName: (j['episodeName'] ?? '').toString(),
    episodeIndex: (j['episodeIndex'] as num?)?.toInt() ?? 0,
    url: (j['url'] ?? '').toString(),
    rawUrl: (j['rawUrl'] ?? '').toString(),
    positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
  );

  HistoryItem copyWith({
    String? flag,
    String? episodeName,
    int? episodeIndex,
    String? url,
    String? rawUrl,
    int? positionMs,
    int? durationMs,
    int? updatedAt,
  }) => HistoryItem(
    key: key,
    name: name,
    updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    sourceKey: sourceKey,
    sourceName: sourceName,
    vodId: vodId,
    pic: pic,
    remarks: remarks,
    flag: flag ?? this.flag,
    episodeName: episodeName ?? this.episodeName,
    episodeIndex: episodeIndex ?? this.episodeIndex,
    url: url ?? this.url,
    rawUrl: rawUrl ?? this.rawUrl,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
  );
}

/// 播放器「详情」悬浮层的单个指标。
class PlayerOverlayMetric {
  const PlayerOverlayMetric(this.id, this.label, this.corner);

  final String id;
  final String label;

  /// 显示位置：`tl` 左上、`tr` 右上、`bl` 左下、`br` 右下。
  final String corner;
}

/// 可显示的指标全集（顺序即悬浮层内的行序）。
const kPlayerOverlayMetrics = <PlayerOverlayMetric>[
  PlayerOverlayMetric('title', '剧名', 'tl'),
  PlayerOverlayMetric('episode', '集数', 'tl'),
  PlayerOverlayMetric('resolution', '分辨率', 'tl'),
  PlayerOverlayMetric('fps', '帧率', 'tl'),
  PlayerOverlayMetric('codec', '视频编码', 'tl'),
  PlayerOverlayMetric('format', '容器格式', 'tl'),
  PlayerOverlayMetric('source', '来源站点', 'tl'),
  PlayerOverlayMetric('line', '线路', 'tl'),
  PlayerOverlayMetric('clock', '当前时间', 'tr'),
  PlayerOverlayMetric('progress', '播放进度', 'bl'),
  PlayerOverlayMetric('remaining', '剩余时间', 'bl'),
  PlayerOverlayMetric('net', '实时网速', 'br'),
  PlayerOverlayMetric('buffer', '缓冲时长', 'br'),
  PlayerOverlayMetric('audio', '音频编码', 'br'),
  PlayerOverlayMetric('volume', '音量', 'br'),
  PlayerOverlayMetric('rate', '播放倍速', 'br'),
];

const kDefaultPlayerOverlayMetrics = <String>[
  'title',
  'episode',
  'resolution',
  'clock',
  'progress',
  'net',
];

/// 直播「详情」悬浮层指标：和点播共用四角布局与开关，但内容换成频道 /
/// 分组 / 线路 / EPG。直播没有播放进度和倍速，改成「正在播 / 下一档」
/// 与节目进度。
const kLivePlayerOverlayMetrics = <PlayerOverlayMetric>[
  PlayerOverlayMetric('title', '频道', 'tl'),
  PlayerOverlayMetric('group', '分组', 'tl'),
  PlayerOverlayMetric('resolution', '分辨率', 'tl'),
  PlayerOverlayMetric('fps', '帧率', 'tl'),
  PlayerOverlayMetric('codec', '视频编码', 'tl'),
  PlayerOverlayMetric('format', '格式', 'tl'),
  PlayerOverlayMetric('source', '直播源', 'tl'),
  PlayerOverlayMetric('line', '线路', 'tl'),
  PlayerOverlayMetric('clock', '当前时间', 'tr'),
  PlayerOverlayMetric('status', '直播状态', 'tr'),
  PlayerOverlayMetric('epg', '正在播', 'bl'),
  PlayerOverlayMetric('epg_next', '下一档', 'bl'),
  PlayerOverlayMetric('epg_progress', '节目进度', 'bl'),
  PlayerOverlayMetric('net', '实时码率', 'br'),
  PlayerOverlayMetric('buffer', '缓冲时长', 'br'),
  PlayerOverlayMetric('audio', '音频编码', 'br'),
  PlayerOverlayMetric('volume', '音量', 'br'),
];

const kDefaultLivePlayerOverlayMetrics = <String>[
  'title',
  'group',
  'resolution',
  'clock',
  'epg',
  'epg_next',
  'net',
];

/// 默认播放器：内置 / Yaozhi MPV / 用户自定义第三方播放器（`custom:<exe路径>`）。
const kDefaultPlayerBuiltin = 'builtin';
const kDefaultPlayerYaozhiMpv = 'mpv';
const kDefaultPlayerCustomPrefix = 'custom:';

String defaultCustomPlayerId(String path) =>
    '$kDefaultPlayerCustomPrefix${path.trim()}';

String defaultCustomPlayerPath(String id) =>
    id.startsWith(kDefaultPlayerCustomPrefix)
    ? id.substring(kDefaultPlayerCustomPrefix.length).trim()
    : '';

String normalizeDefaultPlayer(String raw) {
  final value = raw.trim();
  if (value == kDefaultPlayerYaozhiMpv) return value;
  if (value.startsWith(kDefaultPlayerCustomPrefix) &&
      defaultCustomPlayerPath(value).isNotEmpty) {
    return value;
  }
  return kDefaultPlayerBuiltin;
}

/// 用户手动选择的第三方播放器：只认可执行文件路径，不依赖安装记录。
class ExternalPlayerEntry {
  const ExternalPlayerEntry({required this.name, required this.path});

  final String name;
  final String path;

  ExternalPlayerEntry copyWith({String? name, String? path}) =>
      ExternalPlayerEntry(name: name ?? this.name, path: path ?? this.path);

  Map<String, dynamic> toJson() => {'name': name, 'path': path};

  factory ExternalPlayerEntry.fromJson(Map<String, dynamic> j) =>
      ExternalPlayerEntry(
        name: (j['name'] ?? '').toString().trim(),
        path: (j['path'] ?? '').toString().trim(),
      );
}

class PlayerSettings {
  const PlayerSettings({
    this.speed = 1.0,
    this.autoPlayNext = true,
    this.autoSwitchLine = false,
    this.magnetDownloadDir = '',
    this.rememberProgress = true,
    this.overlayMetrics = kDefaultPlayerOverlayMetrics,
    this.liveOverlayMetrics = kDefaultLivePlayerOverlayMetrics,
    this.overlayFontSize = 14,
    this.overlayVisible = false,
    this.volume = 1.0,
    this.m3u8Purify = false,
    this.bufferMinSec = 1.0,
    this.bufferMaxSec = 4.0,
    this.streamCache = false,
    this.streamCacheMb = 1024,
    this.fit = 'contain',
    this.jsWorkerPool = false,
    this.keepSpiderHosts = false,
    this.externalPlayers = const [],
    this.defaultPlayer = kDefaultPlayerBuiltin,
    this.immersiveMode = false,
    this.popOutPlayer = false,
    this.artworkPriority = 'douban',
    this.tmdbApiKey = '',
    this.tmdbReadToken = '',
    this.bossKey = kDefaultBossKey,
    this.autoLandscape = true,
  });
  final double speed;
  final bool autoPlayNext;

  /// 播放失败时自动换线路；当前源线路耗尽后搜索其他源的相同片名。
  final bool autoSwitchLine;

  /// 移动端播放时自动横屏；离开播放器恢复系统默认方向（仅移动端生效）。
  final bool autoLandscape;

  /// 磁力下载/缓存目录；空串 = 应用数据目录下的 `bt`。
  final String magnetDownloadDir;
  final bool rememberProgress;

  /// 画面比例（[PlayerFit.name]）。
  final String fit;

  /// 设置中手动添加的第三方播放器（排在自动探测结果前面）。
  final List<ExternalPlayerEntry> externalPlayers;

  /// 详情页点击播放时优先使用的播放器；见 `kDefaultPlayer*`。
  final String defaultPlayer;

  /// 沉浸观影模式：除播放器外的页面切换为大屏 TV 布局。
  final bool immersiveMode;

  /// 内置播放器独立窗口：在主界面之外另开一个完整播放器窗口；
  /// false = 与现在一样嵌入软件主界面。沉浸观影模式下不生效。
  final bool popOutPlayer;

  /// [popOutPlayer] 的实际生效值：沉浸观影模式是独占全屏的大屏布局，
  /// 此时独立窗口一律不弹（设置本身保留，退出沉浸后自动恢复）。
  bool get effectivePopOutPlayer => popOutPlayer && !immersiveMode;

  /// 横图封面优先来源：`douban` / `tmdb` / `imdb`。
  final String artworkPriority;

  /// TMDB 的 v3 API Key（32 位十六进制，走 query 的 `api_key`）；空 = 未填。
  final String tmdbApiKey;

  /// TMDB 的 v4 Read Access Token（JWT，走 `Authorization: Bearer`）；空 = 未填。
  ///
  /// 两份都填时优先用这个：令牌走请求头，密钥不会出现在 URL 里。
  final String tmdbReadToken;

  /// 老板键：暂停视频并隐藏到托盘 / 原样恢复；见 [kBossKeyShortcuts]。
  /// `off` = 关闭；沉浸观影模式下不生效。
  final String bossKey;

  String get defaultCustomPlayerPathValue =>
      defaultCustomPlayerPath(defaultPlayer);

  PlayerSettings copyWith({
    double? speed,
    bool? autoPlayNext,
    bool? autoSwitchLine,
    bool? autoLandscape,
    String? magnetDownloadDir,
    bool? rememberProgress,
    List<String>? overlayMetrics,
    List<String>? liveOverlayMetrics,
    double? overlayFontSize,
    bool? overlayVisible,
    double? volume,
    bool? m3u8Purify,
    double? bufferMinSec,
    double? bufferMaxSec,
    bool? streamCache,
    int? streamCacheMb,
    String? fit,
    bool? jsWorkerPool,
    bool? keepSpiderHosts,
    List<ExternalPlayerEntry>? externalPlayers,
    String? defaultPlayer,
    bool? immersiveMode,
    bool? popOutPlayer,
    String? artworkPriority,
    String? tmdbApiKey,
    String? tmdbReadToken,
    String? bossKey,
  }) => PlayerSettings(
    speed: speed ?? this.speed,
    autoPlayNext: autoPlayNext ?? this.autoPlayNext,
    autoSwitchLine: autoSwitchLine ?? this.autoSwitchLine,
    autoLandscape: autoLandscape ?? this.autoLandscape,
    magnetDownloadDir: magnetDownloadDir ?? this.magnetDownloadDir,
    rememberProgress: rememberProgress ?? this.rememberProgress,
    overlayMetrics: overlayMetrics ?? this.overlayMetrics,
    liveOverlayMetrics: liveOverlayMetrics ?? this.liveOverlayMetrics,
    overlayFontSize: overlayFontSize ?? this.overlayFontSize,
    overlayVisible: overlayVisible ?? this.overlayVisible,
    volume: volume ?? this.volume,
    m3u8Purify: m3u8Purify ?? this.m3u8Purify,
    bufferMinSec: bufferMinSec ?? this.bufferMinSec,
    bufferMaxSec: bufferMaxSec ?? this.bufferMaxSec,
    streamCache: streamCache ?? this.streamCache,
    streamCacheMb: streamCacheMb ?? this.streamCacheMb,
    fit: fit ?? this.fit,
    jsWorkerPool: jsWorkerPool ?? this.jsWorkerPool,
    keepSpiderHosts: keepSpiderHosts ?? this.keepSpiderHosts,
    externalPlayers: externalPlayers ?? this.externalPlayers,
    defaultPlayer: normalizeDefaultPlayer(defaultPlayer ?? this.defaultPlayer),
    immersiveMode: immersiveMode ?? this.immersiveMode,
    popOutPlayer: popOutPlayer ?? this.popOutPlayer,
    artworkPriority: normalizeArtworkPriority(
      artworkPriority ?? this.artworkPriority,
    ),
    tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
    tmdbReadToken: tmdbReadToken ?? this.tmdbReadToken,
    bossKey: normalizeBossKey(bossKey ?? this.bossKey),
  );

  /// m3u8 去广告（默认关；只在点播清单上生效）。
  final bool m3u8Purify;

  /// 起播预缓冲秒数（fvp/libmdk `bufferRange.min`）：攒够这么多才开播。
  final double bufferMinSec;

  /// 最大缓冲秒数（fvp/libmdk `bufferRange.max`）：超过就停止继续拉流。
  final double bufferMaxSec;

  /// 边播边缓存：把已下行的分片写进本地磁盘，重看 / 拖动直接读盘。
  final bool streamCache;

  /// 边播边缓存容量上限（MB），超出按最久未用淘汰。
  final int streamCacheMb;

  /// JS 蜘蛛并行（实验，默认关）：开启后最多 3 只 QuickJS 执行器，
  /// 多 JS 源搜索/浏览不用再排同一个 isolate 的队。
  final bool jsWorkerPool;

  /// 常驻 JVM 保温（实验，默认关）：搜索/浏览后保留 serve host 2 分钟，
  /// 用内存换下一次调用的冷启动时间。
  final bool keepSpiderHosts;

  /// 播放器音量（0–1），与系统音量相互独立。
  final double volume;

  /// 播放器「详情」层要显示的指标（见 [kPlayerOverlayMetrics]）。
  final List<String> overlayMetrics;

  /// 直播播放器「详情」层要显示的指标（见 [kLivePlayerOverlayMetrics]）。
  final List<String> liveOverlayMetrics;
  final double overlayFontSize;

  /// 「详情」悬浮层是否开启（跨启动记忆：上次开着下次仍开，关掉也记住）。
  final bool overlayVisible;

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'autoPlayNext': autoPlayNext,
    'autoSwitchLine': autoSwitchLine,
    'autoLandscape': autoLandscape,
    'magnetDownloadDir': magnetDownloadDir,
    'rememberProgress': rememberProgress,
    'overlayMetrics': overlayMetrics,
    'liveOverlayMetrics': liveOverlayMetrics,
    'overlayFontSize': overlayFontSize,
    'overlayVisible': overlayVisible,
    'volume': volume,
    'm3u8Purify': m3u8Purify,
    'bufferMinSec': bufferMinSec,
    'bufferMaxSec': bufferMaxSec,
    'streamCache': streamCache,
    'streamCacheMb': streamCacheMb,
    'fit': fit,
    'jsWorkerPool': jsWorkerPool,
    'keepSpiderHosts': keepSpiderHosts,
    'externalPlayers': externalPlayers.map((e) => e.toJson()).toList(),
    'defaultPlayer': defaultPlayer,
    'immersiveMode': immersiveMode,
    'popOutPlayer': popOutPlayer,
    'artworkPriority': artworkPriority,
    'tmdbApiKey': tmdbApiKey,
    'tmdbReadToken': tmdbReadToken,
    'bossKey': bossKey,
  };

  factory PlayerSettings.fromJson(Map<String, dynamic> j) => PlayerSettings(
    speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
    autoPlayNext: (j['autoPlayNext'] as bool?) ?? true,
    autoSwitchLine: (j['autoSwitchLine'] as bool?) ?? false,
    autoLandscape: (j['autoLandscape'] as bool?) ?? true,
    magnetDownloadDir: (j['magnetDownloadDir'] ?? '').toString().trim(),
    rememberProgress: (j['rememberProgress'] as bool?) ?? true,
    overlayMetrics:
        (j['overlayMetrics'] as List?)
            ?.map((e) => '$e')
            .where((e) => kPlayerOverlayMetrics.any((m) => m.id == e))
            .toList() ??
        kDefaultPlayerOverlayMetrics,
    liveOverlayMetrics:
        (j['liveOverlayMetrics'] as List?)
            ?.map((e) => '$e')
            .where((e) => kLivePlayerOverlayMetrics.any((m) => m.id == e))
            .toList() ??
        kDefaultLivePlayerOverlayMetrics,
    overlayFontSize: (j['overlayFontSize'] as num?)?.toDouble() ?? 14,
    overlayVisible: (j['overlayVisible'] as bool?) ?? false,
    volume: ((j['volume'] as num?)?.toDouble() ?? 1.0)
        .clamp(0.0, 1.0)
        .toDouble(),
    m3u8Purify: (j['m3u8Purify'] as bool?) ?? false,
    bufferMinSec: ((j['bufferMinSec'] as num?)?.toDouble() ?? 1.0)
        .clamp(0.2, 30.0)
        .toDouble(),
    bufferMaxSec: ((j['bufferMaxSec'] as num?)?.toDouble() ?? 4.0)
        .clamp(1.0, 120.0)
        .toDouble(),
    streamCache: (j['streamCache'] as bool?) ?? false,
    streamCacheMb: ((j['streamCacheMb'] as num?)?.toInt() ?? 1024)
        .clamp(128, 16384)
        .toInt(),
    fit: normalizePlayerFit((j['fit'] ?? '').toString()).name,
    jsWorkerPool: (j['jsWorkerPool'] as bool?) ?? false,
    keepSpiderHosts: (j['keepSpiderHosts'] as bool?) ?? false,
    externalPlayers: _externalPlayersFromJson(j['externalPlayers']),
    defaultPlayer: normalizeDefaultPlayer(
      (j['defaultPlayer'] ?? '').toString(),
    ),
    immersiveMode: (j['immersiveMode'] as bool?) ?? false,
    popOutPlayer: (j['popOutPlayer'] as bool?) ?? false,
    artworkPriority: normalizeArtworkPriority(
      (j['artworkPriority'] ?? '').toString(),
    ),
    tmdbApiKey: (j['tmdbApiKey'] ?? '').toString().trim(),
    tmdbReadToken: (j['tmdbReadToken'] ?? '').toString().trim(),
    bossKey: normalizeBossKey((j['bossKey'] ?? '').toString()),
  );
}

/// 老板键默认值：Ctrl + Shift + B。
const String kDefaultBossKey = 'ctrl+shift+b';

/// 老板键可选项（值 → 显示名）。`off` 表示不注册全局热键。
const List<(String, String)> kBossKeyShortcuts = [
  (kDefaultBossKey, 'Ctrl + Shift + B'),
  ('ctrl+alt+b', 'Ctrl + Alt + B'),
  ('alt+q', 'Alt + Q'),
  ('alt+x', 'Alt + X'),
  ('f12', 'F12'),
  ('off', '关闭'),
];

/// 老板键归一：只接受预设组合与 `off`，未知值回落到默认组合。
String normalizeBossKey(String raw) {
  final value = raw.trim().toLowerCase().replaceAll(' ', '');
  for (final item in kBossKeyShortcuts) {
    if (item.$1 == value) return value;
  }
  return kDefaultBossKey;
}

/// 老板键显示名（如 `Ctrl + Shift + B`）。
String bossKeyLabel(String raw) {
  final value = normalizeBossKey(raw);
  for (final item in kBossKeyShortcuts) {
    if (item.$1 == value) return item.$2;
  }
  return 'Ctrl + Shift + B';
}

/// 横图封面来源归一：只认 douban / tmdb / imdb，未知值回落到豆瓣。
String normalizeArtworkPriority(String raw) {
  final value = raw.trim().toLowerCase();
  return switch (value) {
    'tmdb' => 'tmdb',
    'imdb' => 'imdb',
    _ => 'douban',
  };
}

List<ExternalPlayerEntry> _externalPlayersFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <ExternalPlayerEntry>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! Map) continue;
    final entry = ExternalPlayerEntry.fromJson(Map<String, dynamic>.from(item));
    final path = entry.path.trim();
    if (path.isEmpty || !seen.add(path.toLowerCase())) continue;
    out.add(entry.copyWith(path: path));
  }
  return out;
}
