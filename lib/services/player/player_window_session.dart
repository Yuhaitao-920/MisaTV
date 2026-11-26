import 'dart:convert';

import '../../models/live.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../live/epg.dart';

/// 交给独立播放器窗口的一次点播会话快照。
///
/// 子窗口有独立的 Flutter 引擎与 AppState，不能直接共享主窗口对象，
/// 所以把详情、线路、选集与已经取好的首播地址序列化过去。
class VodWindowSession {
  const VodWindowSession({
    required this.detail,
    required this.site,
    required this.flag,
    required this.episodeIndex,
    required this.episodes,
    this.initialPlay,
    this.startPositionMs = 0,
    this.ephemeral = false,
  });

  final VodDetail detail;
  final SourceBean site;
  final String flag;
  final int episodeIndex;
  final List<Episode> episodes;
  final PlayResult? initialPlay;
  final int startPositionMs;
  final bool ephemeral;

  Map<String, dynamic> toJson() => {
    'detail': detail.toJson(),
    'site': site.toJson(),
    'flag': flag,
    'episodeIndex': episodeIndex,
    'episodes': episodes.map((e) => e.toJson()).toList(),
    'initialPlay': initialPlay?.toJson(),
    'startPositionMs': startPositionMs,
    'ephemeral': ephemeral,
  };

  factory VodWindowSession.fromJson(Map<String, dynamic> json) =>
      VodWindowSession(
        detail: VodDetail.fromJson(
          Map<String, dynamic>.from(json['detail'] as Map? ?? const {}),
        ),
        site: SourceBean.fromJson(
          Map<String, dynamic>.from(json['site'] as Map? ?? const {}),
        ),
        flag: (json['flag'] ?? '').toString(),
        episodeIndex: (json['episodeIndex'] as num?)?.toInt() ?? 0,
        episodes: [
          for (final item
              in (json['episodes'] is List
                  ? json['episodes'] as List
                  : const []))
            if (item is Map) Episode.fromJson(Map<String, dynamic>.from(item)),
        ],
        initialPlay: json['initialPlay'] is Map
            ? PlayResult.fromJson(
                Map<String, dynamic>.from(json['initialPlay'] as Map),
              )
            : null,
        startPositionMs: (json['startPositionMs'] as num?)?.toInt() ?? 0,
        ephemeral: (json['ephemeral'] as bool?) ?? false,
      );
}

/// 交给独立播放器窗口的一次直播会话快照。
class LiveWindowSession {
  const LiveWindowSession({
    required this.bean,
    required this.channel,
    required this.initialLine,
    this.epg,
    this.groups = const [],
    this.epgEntries = const {},
    this.initialGroup = '',
  });

  final LiveBean bean;
  final LiveChannel channel;
  final LiveLine initialLine;
  final EpgEntry? epg;
  final List<LiveGroup> groups;
  final Map<String, EpgEntry> epgEntries;
  final String initialGroup;

  Map<String, dynamic> toJson() => {
    'bean': bean.toJson(),
    'channel': channel.toJson(),
    'initialLine': initialLine.toJson(),
    if (epg != null) 'epg': epg!.toJson(),
    'groups': groups.map((e) => e.toJson()).toList(),
    'epgEntries': {
      for (final entry in epgEntries.entries) entry.key: entry.value.toJson(),
    },
    'initialGroup': initialGroup,
  };

  factory LiveWindowSession.fromJson(
    Map<String, dynamic> json,
  ) => LiveWindowSession(
    bean: LiveBean.fromJson(
      Map<String, dynamic>.from(json['bean'] as Map? ?? const {}),
    ),
    channel: LiveChannel.fromJson(
      Map<String, dynamic>.from(json['channel'] as Map? ?? const {}),
    ),
    initialLine: LiveLine.fromJson(
      Map<String, dynamic>.from(json['initialLine'] as Map? ?? const {}),
    ),
    epg: json['epg'] is Map
        ? EpgEntry.fromJson(Map<String, dynamic>.from(json['epg'] as Map))
        : null,
    groups: [
      for (final item
          in (json['groups'] is List ? json['groups'] as List : const []))
        if (item is Map) LiveGroup.fromJson(Map<String, dynamic>.from(item)),
    ],
    epgEntries: {
      for (final entry
          in (json['epgEntries'] is Map ? json['epgEntries'] as Map : const {})
              .entries)
        if (entry.value is Map)
          entry.key.toString(): EpgEntry.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
    },
    initialGroup: (json['initialGroup'] ?? '').toString(),
  );
}

/// 独立播放器窗口的启动参数前缀；后面跟载荷 JSON 文件的绝对路径。
const standalonePlayerWindowArgPrefix = 'misa-player:';

/// 从窗口参数里取出载荷文件路径。
///
/// 子窗口是 `desktop_multi_window` 用 `multi_window <id> <argument>` 重跑同一
/// 入口的，参数里带着 [standalonePlayerWindowArgPrefix]；直接把它当文件路径读
/// 会得到「载荷无效」，所以两条入口都必须先过这里。不是独立播放器窗口时返回 null。
String? standalonePlayerPayloadPath(String? raw) {
  final text = (raw ?? '').trim();
  if (!text.startsWith(standalonePlayerWindowArgPrefix)) return null;
  final path = text.substring(standalonePlayerWindowArgPrefix.length).trim();
  return path.isEmpty ? null : path;
}

/// 独立播放器窗口的载荷：`kind` 决定子窗口渲染点播还是直播播放器。
class PlayerWindowPayload {
  const PlayerWindowPayload._({required this.kind, this.vod, this.live});

  factory PlayerWindowPayload.vod(VodWindowSession session) =>
      PlayerWindowPayload._(kind: 'vod', vod: session);

  factory PlayerWindowPayload.live(LiveWindowSession session) =>
      PlayerWindowPayload._(kind: 'live', live: session);

  final String kind;
  final VodWindowSession? vod;
  final LiveWindowSession? live;

  String encode() => jsonEncode({
    'kind': kind,
    if (vod != null) 'vod': vod!.toJson(),
    if (live != null) 'live': live!.toJson(),
  });

  static PlayerWindowPayload? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final kind = (decoded['kind'] ?? '').toString();
      if (kind == 'vod' && decoded['vod'] is Map) {
        return PlayerWindowPayload.vod(
          VodWindowSession.fromJson(
            Map<String, dynamic>.from(decoded['vod'] as Map),
          ),
        );
      }
      if (kind == 'live' && decoded['live'] is Map) {
        return PlayerWindowPayload.live(
          LiveWindowSession.fromJson(
            Map<String, dynamic>.from(decoded['live'] as Map),
          ),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
