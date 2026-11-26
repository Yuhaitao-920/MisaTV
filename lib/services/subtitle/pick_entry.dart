/// 压缩包内「挑哪条字幕」的纯函数打分。
///
/// 移植自旧版 `src/main/subtitle/pickEntry.ts`：扩展名优先级 + 与视频/集号匹配 + 噪声剔除。
library;

/// 挑选时的上下文。
class PickOptions {
  const PickOptions({this.videoName = '', this.ep = ''});

  /// 视频文件名或详情页片名（用于与包内字幕名做匹配加分）。
  final String videoName;

  /// 当前集号（如 '12' / 'S01E12'；空串表示单集或未知）。
  final String ep;
}

/// 可参与挑选的条目。
class PickableEntry {
  const PickableEntry({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}

/// 字幕扩展名基础分（ass/ssa 带样式，优先；txt 常是说明文件，最低）。
const Map<String, int> _extScore = <String, int>{
  'ass': 40,
  'ssa': 40,
  'srt': 30,
  'vtt': 20,
  'sub': 5,
  'txt': 5,
};

/// 噪声条目：说明/校验/系统元数据 —— 一律排除。
final RegExp _noiseRe = RegExp(
  r'(^|\/)(readme|readme\.txt|readme\.md|.*\.nfo|.*\.sfv|.*\.md5|.*\.url|.*\.ini|.*\.ds_store)$',
  caseSensitive: false,
);

String _norm(String s) {
  final last = s.split(RegExp(r'[\\/]')).last;
  return last
      .toLowerCase()
      .replaceFirst(RegExp(r'\.[a-z0-9]{1,5}$'), '')
      .replaceAll(RegExp(r'[\s._\-\[\](){}（）【】]+'), '');
}

/// 取条目的扩展名（小写，无扩展名返回空串）。
String extOf(String name) {
  final m = RegExp(
    r'\.([a-z0-9]{1,5})$',
    caseSensitive: false,
  ).firstMatch(name.trim());
  return m == null ? '' : m.group(1)!.toLowerCase();
}

/// 从名称里提取集号（'s01e12' / 'ep12' / '第12集' → '12'；无则空串）。
String epOf(String name) {
  final s = name.toLowerCase();
  final se = RegExp(r's\d{1,2}[\s._-]*e(\d{1,3})').firstMatch(s);
  if (se != null) return int.parse(se.group(1)!).toString();
  final ep = RegExp(r'(?:^|[^a-z])e(?:p)?[\s._-]*(\d{1,3})(?:[^0-9]|$)')
      .firstMatch(s);
  if (ep != null) return int.parse(ep.group(1)!).toString();
  final cn = RegExp(r'第[\s._-]*(\d{1,3})[\s._-]*[集话]').firstMatch(s);
  if (cn != null) return int.parse(cn.group(1)!).toString();
  return '';
}

bool _isNoise(String name, int size) {
  final p = name.replaceAll('\\', '/');
  if (p.trim().isEmpty) return true;
  if (p.endsWith('/')) return true; // 目录项
  if (RegExp(r'(^|\/)__MACOSX\/', caseSensitive: false).hasMatch(p)) {
    return true;
  }
  if (RegExp(r'(^|\/)\.').hasMatch(p)) return true; // 隐藏文件/目录
  if (_noiseRe.hasMatch(p)) return true;
  if (extOf(p) == 'txt' && size > 200 * 1024) return true; // 大 txt 基本是站点说明
  return false;
}

/// 单条目打分（越高越应被选中；负无穷 = 直接排除）。
double scoreEntry(
  String name,
  int size, [
  PickOptions opts = const PickOptions(),
]) {
  if (_isNoise(name, size)) return double.negativeInfinity;
  final ext = extOf(name);
  final base = _extScore[ext];
  if (base == null) return double.negativeInfinity;
  if (size < 32) return double.negativeInfinity;
  var score = base.toDouble();

  final nVideo = _norm(opts.videoName);
  final nName = _norm(name);
  if (nVideo.isNotEmpty && nName.isNotEmpty) {
    if (nName == nVideo) {
      score += 30;
    } else if (nName.contains(nVideo) || nVideo.contains(nName)) {
      score += 22;
    } else {
      final head = nVideo.substring(
        0,
        nVideo.length < 4
            ? nVideo.length
            : (nVideo.length < 10 ? nVideo.length : 10),
      );
      if (head.isNotEmpty && nName.contains(head)) score += 10;
    }
  }

  // ★ 语言优先级：中文 > 双语 > 英文 > 其他。
  //
  //   实测 assrt id=733904（人性本兽）包内 4 条，旧打分把 SDH 排第一
  //   （它体积最大 → 同分时按长度排序），自动挂上的是英文字幕，而用户
  //   要的是简中。这里按文件名里的语种标记给分，让中文优先。
  //   SDH 明确降权 —— 它是听障版，带音效描述，多数人不要。
  final lower = name.toLowerCase();
  if (RegExp(r'简中|简體|简体|chs|zh[-_.]?cn|\.chi|中文').hasMatch(lower)) {
    score += 26;
  } else if (RegExp(r'繁中|繁體|繁体|cht|zh[-_.]?tw|\.chtc?').hasMatch(lower)) {
    score += 20;
  } else if (RegExp(r'双语|雙語|中英|bilingual').hasMatch(lower)) {
    score += 16;
  } else if (RegExp(r'chs&eng|简英|简繁').hasMatch(lower)) {
    score += 22;
  } else if (RegExp(r'eng|english|\.en\b').hasMatch(lower)) {
    score += 4;
  }
  if (RegExp(r'sdh|听障|聽障|hearing').hasMatch(lower)) score -= 12;

  final wantEp = opts.ep.replaceAll(RegExp(r'[^0-9]'), '');
  final gotEp = epOf(name);
  if (wantEp.isNotEmpty && gotEp.isNotEmpty) {
    score += wantEp == gotEp ? 20 : -15;
  }
  return score;
}

/// 按分数降序取前 n 条。
List<T> pickSubtitleEntries<T extends PickableEntry>(
  List<T> entries, {
  PickOptions opts = const PickOptions(),
  int n = 3,
}) {
  final scored =
      <({T entry, double score})>[
        for (final e in entries)
          (entry: e, score: scoreEntry(e.name, e.bytes.length, opts)),
      ].where((x) => x.score.isFinite).toList()..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0
            ? byScore
            : b.entry.bytes.length.compareTo(a.entry.bytes.length);
      });
  return scored.take(n < 1 ? 1 : n).map((x) => x.entry).toList();
}

/// 选最优条目；全部被排除返回 null。
T? pickSubtitleEntry<T extends PickableEntry>(
  List<T> entries, {
  PickOptions opts = const PickOptions(),
}) {
  final list = pickSubtitleEntries(entries, opts: opts, n: 1);
  return list.isEmpty ? null : list.first;
}
