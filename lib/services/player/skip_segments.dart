/// 播放器「跳过片头 / 片尾」记录。
///
/// 设置按资源生效：保存一次会清理该资源下所有集的旧记录，只保留当前这条，
/// 因此该资源的每一集都会解析到同一组片头 / 片尾秒数。
/// 键格式仍为 `资源|集`（保留旧数据兼容），资源由调用方给出（当前用 `源 key|影片 id`）。
class SkipSegment {
  const SkipSegment({this.intro = 0, this.outro = 0});

  /// 片头跳过秒数（起播直接跳到该位置）。
  final int intro;

  /// 片尾跳过秒数（距结尾还剩这么多秒时跳下一集）。
  final int outro;

  bool get isEmpty => intro <= 0 && outro <= 0;

  Map<String, dynamic> toJson() => {'intro': intro, 'outro': outro};
}

class SkipRecord extends SkipSegment {
  const SkipRecord({super.intro, super.outro, this.at = 0, this.from = ''});

  /// 写入时间（毫秒），用于「本资源最近一次设置」排序。
  final int at;

  /// 写入时的集展示名（如「第12集」），用于「沿用 X 的设置」提示。
  final String from;

  @override
  Map<String, dynamic> toJson() => {
    'intro': intro,
    'outro': outro,
    'at': at,
    if (from.isNotEmpty) 'from': from,
  };
}

class SkipResolved {
  const SkipResolved({
    required this.intro,
    required this.outro,
    this.inheritedFrom = '',
  });

  final int intro;
  final int outro;

  /// 非空表示本集没有自己的记录，沿用了该资源最近一次设置。
  final String inheritedFrom;

  bool get isEmpty => intro <= 0 && outro <= 0;
}

/// 秒数上限（6 小时），防手滑输入天文数字。
const int skipSecMax = 6 * 3600;

/// 非法 / 负数 → 0；超上限截断。
int clampSkipSeconds(Object? value) {
  final n = value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;
  if (n <= 0) return 0;
  return n > skipSecMax ? skipSecMax : n;
}

SkipRecord? normalizeSkipRecord(Object? raw) {
  if (raw is! Map) return null;
  final intro = clampSkipSeconds(raw['intro']);
  final outro = clampSkipSeconds(raw['outro']);
  if (intro <= 0 && outro <= 0) return null;
  final at = raw['at'] is num
      ? (raw['at'] as num).toInt()
      : int.tryParse('${raw['at'] ?? ''}') ?? 0;
  return SkipRecord(
    intro: intro,
    outro: outro,
    at: at,
    from: (raw['from'] ?? '').toString(),
  );
}

String skipStoreKey(String resource, String episode) =>
    '${resource.trim()}|${episode.trim()}';

/// 本资源最近一次保存的设置。
({String episode, SkipRecord record})? latestSkipOfResource(
  Map<String, SkipRecord> store,
  String resource,
) {
  final prefix = '${resource.trim()}|';
  if (prefix == '|') return null;
  ({String episode, SkipRecord record})? best;
  for (final entry in store.entries) {
    if (!entry.key.startsWith(prefix)) continue;
    final ep = entry.key.substring(prefix.length);
    if (best == null || entry.value.at > best.record.at) {
      best = (episode: ep, record: entry.value);
    }
  }
  return best;
}

/// 本集有效设置：始终取该资源最近一次保存的设置。
///
/// 以前是「本集记录优先、无记录才继承」，导致旧数据里个别集自己的记录会把
/// 资源级设置挡住；现在统一按资源级设置生效，该资源的每一集取到同一组秒数。
SkipResolved? resolveSkip(
  Map<String, SkipRecord> store,
  String resource,
  String episode,
) {
  final latest = latestSkipOfResource(store, resource);
  if (latest == null) return null;
  return SkipResolved(
    intro: latest.record.intro,
    outro: latest.record.outro,
    inheritedFrom: latest.episode == episode.trim()
        ? ''
        : (latest.record.from.isNotEmpty ? latest.record.from : latest.episode),
  );
}

/// 写入 / 清除本集记录（两项都为 0 = 清除，不再继承）。
Map<String, SkipRecord> putSkipRecord(
  Map<String, SkipRecord> store,
  String resource,
  String episode,
  SkipSegment segment, {
  String label = '',
  int? nowMs,
}) {
  final out = Map<String, SkipRecord>.from(store);
  final key = skipStoreKey(resource, episode);
  final normalized = normalizeSkipRecord({
    'intro': segment.intro,
    'outro': segment.outro,
    'at': nowMs ?? DateTime.now().millisecondsSinceEpoch,
    'from': label,
  });
  if (normalized == null) {
    out.remove(key);
  } else {
    out[key] = normalized;
  }
  return out;
}

/// 写入资源级设置：先删掉该资源下所有集的旧记录，再写入当前集一条。
///
/// 两项都为 0 时表示清除，会移除整个资源的设置而不是只清当前集。
Map<String, SkipRecord> putResourceSkipRecord(
  Map<String, SkipRecord> store,
  String resource,
  String episode,
  SkipSegment segment, {
  String label = '',
  int? nowMs,
}) {
  final trimmed = resource.trim();
  if (trimmed.isEmpty) return Map<String, SkipRecord>.from(store);
  final prefix = '$trimmed|';
  final out = Map<String, SkipRecord>.from(store)
    ..removeWhere((key, _) => key.startsWith(prefix));
  return putSkipRecord(
    out,
    trimmed,
    episode,
    segment,
    label: label,
    nowMs: nowMs,
  );
}

/// 是否该跳过片尾：未知时长 / 片尾秒数过小 / 出点落在片外 → 不跳。
bool shouldSkipOutro(int positionMs, int durationMs, int outroSec, bool fired) {
  if (fired || outroSec <= 1 || durationMs <= 0) return false;
  final point = durationMs - outroSec * 1000;
  if (point <= 1000 || point >= durationMs) return false;
  return positionMs >= point;
}

/// 进度条右键双击的判定窗口（对齐 Flutter 的 `kDoubleTapTimeout`）。
const Duration skipDoubleTapWindow = Duration(milliseconds: 300);

/// 双击两次按下之间允许的位置偏差（逻辑像素），手抖一点仍算同一次双击。
const double skipDoubleTapSlop = 24;

/// 进度条右键的两次按下是否构成「双击」。
///
/// [gap] 为两次按下的时间间隔，[dx] / [lastDx] 为各自在进度条上的横坐标。
/// 间隔超窗或位置差超容差都按两次独立单击处理 —— 否则用户想连续设片头、
/// 片尾时，第二次点击会被误判成清除。
bool isSkipDoubleTap({
  required Duration gap,
  required double dx,
  required double lastDx,
}) {
  if (gap.isNegative || gap > skipDoubleTapWindow) return false;
  return (dx - lastDx).abs() <= skipDoubleTapSlop;
}
