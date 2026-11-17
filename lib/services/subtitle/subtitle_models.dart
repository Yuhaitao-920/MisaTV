import 'subtitle_health.dart';

/// 外挂字幕的数据模型（供播放器 / 设置页直接调用）。
///
/// 与旧版 `src/shared/subtitle.ts` 对齐，但只保留 Flutter 侧需要的字段。
enum SubtitleProviderType { assrt, subtitleCat }

extension SubtitleProviderTypeX on SubtitleProviderType {
  /// 稳定 id（写入候选的 providerId，勿随意改）。
  String get id => switch (this) {
    SubtitleProviderType.assrt => 'assrt',
    SubtitleProviderType.subtitleCat => 'subtitlecat',
  };

  /// UI 展示名。
  String get displayName => switch (this) {
    SubtitleProviderType.assrt => 'assrt（伪射手，需 token）',
    SubtitleProviderType.subtitleCat => 'SubtitleCat（免 token）',
  };

  bool get needsToken => this == SubtitleProviderType.assrt;
}

/// 按 id 找源（大小写不敏感）；未知返回 null。
SubtitleProviderType? subtitleProviderFromId(String? id) {
  final key = (id ?? '').trim().toLowerCase();
  for (final t in SubtitleProviderType.values) {
    if (t.id == key) return t;
  }
  return null;
}

/// 检索条件。
class SubtitleQuery {
  const SubtitleQuery({
    required this.title,
    this.year,
    this.season,
    this.episode,
    this.rawName = '',
  });

  /// 剧名（详情页 name，可含副名）。
  final String title;

  final int? year;
  final int? season;
  final int? episode;

  /// 资源文件名（可选；用来补集号 / 兜底剧名）。
  final String rawName;
}

/// 一个字幕候选。
class SubtitleCandidate {
  const SubtitleCandidate({
    required this.providerId,
    required this.providerName,
    required this.id,
    required this.title,
    required this.language,
    required this.format,
    required this.downloadUrl,
    this.subname = '',
    this.detail = '',
    this.videoName = '',
    this.episodeHint = '',
  });

  /// 'assrt' / 'subtitlecat'
  final String providerId;
  final String providerName;

  /// provider 内唯一 id / 下载 key。
  final String id;

  final String title;
  final String language;

  /// srt / ass / ssa / zip ...
  final String format;

  /// 可直接下载的地址；assrt 搜索阶段为空（下载时再取 detail）。
  final String downloadUrl;

  /// 片源 / 视频文件名（用于压缩包内挑条目）。
  final String subname;

  /// 备注（体积 / 下载量等）。
  final String detail;

  /// 更精确的视频名提示（SubtitleCat 用行名）。
  final String videoName;

  /// 集号提示（下载时挑包内条目）。
  final String episodeHint;
}

/// 下载并解出后的字幕文件。
class SubtitleFile {
  const SubtitleFile({
    required this.name,
    required this.format,
    required this.text,
  });

  /// 真实字幕文件名（含扩展名）。
  final String name;

  /// 规范化格式：srt / ass / ssa / vtt / txt；未知为空串。
  final String format;

  final String text;

  /// 质量体检：条数 / 跨度 / 平均间隔。
  ///
  /// assrt 上存在「AI 摘要」字幕（实测 36 秒一条），时间轴能走但内容只是
  /// 换场梗概。这里算出来供 UI 提示，避免用户误以为「字幕对不上集数」。
  SubtitleHealth get health => inspectSubtitleHealth(text);
}

/// 字幕服务可读异常（消息直接面向用户）。
class SubtitleException implements Exception {
  const SubtitleException(this.message);

  final String message;

  @override
  String toString() => message;
}
