/// 字节 → 可用字幕：非归档直接解码；归档解压后挑最匹配的条目再解码。
///
/// 移植自旧版 `assrtProvider.ts` 的 `subtitleFromBytes`（纯函数，不做网络）。
///
/// ★ 提供同步与异步两个入口：
///   · [subtitleFromBytes] 只处理纯文本 / ZIP / GZ（`archive` 包，同步）
///   · [subtitleFromBytesAsync] 额外支持 RAR / 7Z / BZ2（`koni_archive`）
///   assrt 上大量字幕以 `.rar` 发布，调用方应优先用异步版本。
library;

import 'archive.dart';
import 'pick_entry.dart';
import 'subtitle_models.dart';
import 'subtitle_text.dart';

SubtitleFile subtitleFromBytes(
  List<int> bytes, {
  String fileName = '',
  String videoName = '',
  String ep = '',
}) {
  final kind = detectArchiveKind(bytes);
  if (kind == null) {
    final text = SubtitleText.decode(bytes);
    if (text.trim().isEmpty) {
      throw const SubtitleException('字幕内容为空或无法解码');
    }
    return SubtitleFile(
      name: fileName,
      format: extOf(fileName),
      text: text,
    );
  }

  final entries = extractArchiveEntries(bytes);
  return _pickAndDecode(entries, kind, videoName: videoName, ep: ep);
}

/// 异步版：RAR / 7Z / BZ2 也能解（走 `koni_archive`）。
///
/// `pickFirst: true`（默认）沿用旧的「自动挑一条」行为；传 `false` 时，
/// 包里有多条字幕会抛 [SubtitleChoicesException] 让调用方让用户选。
///
/// `onChoices` 在解出全部候选后回调一次（不论是否抛异常），调用方据此做
/// 会话内缓存 —— 同一个字幕包第二次被点击时就不用重新下载了。
Future<SubtitleFile> subtitleFromBytesAsync(
  List<int> bytes, {
  String fileName = '',
  String videoName = '',
  String ep = '',
  bool pickFirst = true,
  void Function(List<SubtitleChoice> choices)? onChoices,
}) async {
  final kind = detectArchiveKind(bytes);
  if (kind == null) {
    final text = SubtitleText.decode(bytes);
    if (text.trim().isEmpty) {
      throw const SubtitleException('字幕内容为空或无法解码');
    }
    final single = SubtitleFile(
      name: fileName,
      format: extOf(fileName),
      text: text,
    );
    onChoices?.call(<SubtitleChoice>[
      SubtitleChoice(name: single.name, format: single.format, text: text),
    ]);
    return single;
  }

  final entries = await extractArchiveEntriesAsync(bytes);
  return _pickAndDecode(
    entries,
    kind,
    videoName: videoName,
    ep: ep,
    pickFirst: pickFirst,
    onChoices: onChoices,
  );
}

SubtitleFile _pickAndDecode(
  List<ArchiveEntry> entries,
  ArchiveKind kind, {
  required String videoName,
  required String ep,
  bool pickFirst = true,
  void Function(List<SubtitleChoice> choices)? onChoices,
}) {
  if (entries.isEmpty) {
    throw SubtitleException('${kind.label} 压缩包解压失败或包内无文件');
  }
  final ranked = pickSubtitleEntries<ArchiveEntry>(
    entries,
    opts: PickOptions(videoName: videoName, ep: ep),
    n: 12, // 候选上限：再多也没人愿意翻
  );
  if (ranked.isEmpty) {
    throw SubtitleException(
      '压缩包内未找到字幕文件（共 ${entries.length} 个条目）',
    );
  }

  // 先把全部候选解出来（供 UI 选择 / 供调用方缓存）。
  final choices = <SubtitleChoice>[];
  for (final e in ranked) {
    final text = SubtitleText.decode(e.bytes);
    if (text.trim().isEmpty) continue;
    choices.add(
      SubtitleChoice(name: e.name, format: extOf(e.name), text: text),
    );
  }
  if (choices.isEmpty) {
    throw SubtitleException('包内字幕解码为空（共 ${ranked.length} 条）');
  }
  onChoices?.call(choices);

  // ★ 包里有多条字幕时让用户选。
  //
  //   实测 assrt id=733904（人性本兽）包内 4 条：简中 / eng / SDH / 繁中。
  //   自动打分挑错了（旧逻辑挑到 SDH），而用户要的是简中 ——
  //   「挂上的字幕不是我要的」没法纠正。所以只要可选项 >1 就列出来。
  //
  //   只有一条时直接用它（没有选择余地的情况不该多一步点击）。
  if (!pickFirst && choices.length > 1) {
    throw SubtitleChoicesException(choices);
  }
  return choices.first.toFile();
}
