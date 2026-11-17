/// 字幕质量体检：判断一条字幕是不是「AI 摘要」而非逐句对白。
///
/// 背景（实测）：assrt 上有些条目是「字幕智能体自主生成」的剧情摘要，
/// 例如 `Unprotected: Murder in Galicia 2026`（id=803237）：
///   · 104 条 / 3753 秒 → **平均 36 秒一条**
///   · 正常影视对白字幕是 1–3 秒一条
/// 这类字幕时间轴能和画面走，但内容只在换场时出现一句梗概，
/// 用户会以为「字幕对不上」。与其让人猜，不如在列表里直接标出来。
library;

/// 体检结果。
class SubtitleHealth {
  const SubtitleHealth({
    required this.entries,
    required this.spanSeconds,
    required this.averageGapSeconds,
    required this.isLikelySummary,
  });

  /// 解析到的时间轴条数（0 表示不是可识别的时间轴格式）。
  final int entries;

  /// 首条开始到末条结束的总跨度（秒）。
  final double spanSeconds;

  /// 平均间隔（秒）：`spanSeconds / (entries - 1)`。
  final double averageGapSeconds;

  /// 是否判定为「疑似 AI 摘要」。
  final bool isLikelySummary;

  /// 空/无法解析时的占位。
  static const unknown = SubtitleHealth(
    entries: 0,
    spanSeconds: 0,
    averageGapSeconds: 0,
    isLikelySummary: false,
  );

  /// 给人看的短标签；判不出来时返回空串（不占用界面）。
  String get badge {
    if (entries < 5) return '';
    if (isLikelySummary) {
      return '疑似摘要（${averageGapSeconds.round()}s/条）';
    }
    return '';
  }
}

/// 摘要阈值：平均间隔超过这个秒数就不是逐句对白字幕。
///
/// 实测依据：正常影视字幕 1–3 秒一条；慢节奏文艺片也很少超过 8 秒。
/// 取 15 秒 —— 足够宽松，不会误伤正常字幕，又能抓住「36 秒一条」这种。
const double kSummaryGapSeconds = 15;

/// SRT / VTT 的时间码：`00:00:00,000 --> 00:00:02,000`。
final RegExp _timeCodeRe = RegExp(
  r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*'
  r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
);

/// ASS / SSA 的 `Dialogue: Layer,Start,End,Style,...`：
/// `Dialogue:` 后第 1 个字段是 Layer，**第 2、3 个才是 Start / End**。
final RegExp _assDialogueRe = RegExp(
  r'^Dialogue:\s*[^,]*,\s*'
  r'(\d+):(\d{2}):(\d{2})[.,](\d{1,2})\s*,\s*'
  r'(\d+):(\d{2}):(\d{2})[.,](\d{1,2})',
  multiLine: true,
);

double _hhmmss(int h, int m, int s, int fraction, {bool ms = true}) =>
    h * 3600 + m * 60 + s + (fraction / (ms ? 1000 : 100));

/// 体检一条字幕文本（纯函数，不发网络）。
SubtitleHealth inspectSubtitleHealth(String text) {
  if (text.trim().isEmpty) return SubtitleHealth.unknown;
  final spans = <(double, double)>[];

  for (final m in _timeCodeRe.allMatches(text)) {
    spans.add((
      _hhmmss(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!.padRight(3, '0').substring(0, 3)),
      ),
      _hhmmss(
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
        int.parse(m.group(7)!),
        int.parse(m.group(8)!.padRight(3, '0').substring(0, 3)),
      ),
    ));
  }
  if (spans.isEmpty) {
    for (final m in _assDialogueRe.allMatches(text)) {
      spans.add((
        _hhmmss(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!.padRight(2, '0')),
          ms: false,
        ),
        _hhmmss(
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
          int.parse(m.group(7)!),
          int.parse(m.group(8)!.padRight(2, '0')),
          ms: false,
        ),
      ));
    }
  }
  if (spans.length < 2) {
    return SubtitleHealth(
      entries: spans.length,
      spanSeconds: 0,
      averageGapSeconds: 0,
      isLikelySummary: false,
    );
  }

  final start = spans.first.$1;
  final end = spans.map((e) => e.$2).reduce((a, b) => a > b ? a : b);
  final span = end - start;
  final gap = span / (spans.length - 1);
  return SubtitleHealth(
    entries: spans.length,
    spanSeconds: span,
    averageGapSeconds: gap,
    isLikelySummary: gap > kSummaryGapSeconds,
  );
}
