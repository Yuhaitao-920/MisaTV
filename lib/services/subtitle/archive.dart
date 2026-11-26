/// 字幕压缩包解压（zip / gz / rar / 7z / bz2）。
///
/// 移植自旧版 `src/main/subtitle/archive.ts`。旧版 rar/7z/bz2 依赖 wasm，
/// 早期 Flutter 侧没有可用实现，于是这三种格式明确不支持并抛中文原因 ——
/// 但 assrt 上大量字幕就是 `.rar`（实测 id=733904「人性本兽 Animals 2026」
/// 整包是 rar，内含 4 个 srt），「请手动解压」对用户是死路。
///
/// 现在 ZIP / GZ 走 `archive` 包（同步），RAR / 7Z / BZ2 走 `koni_archive`
/// （纯 Dart，无 FFI、无原生依赖，Windows 可用）。
library;

import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoder, ZipDecoder;
import 'package:koni_archive/io.dart' as koni;

import 'pick_entry.dart';
import 'subtitle_models.dart';

enum ArchiveKind { zip, gz, rar, sevenZip, bz2 }

extension ArchiveKindX on ArchiveKind {
  String get label => switch (this) {
    ArchiveKind.zip => 'ZIP',
    ArchiveKind.gz => 'GZ',
    ArchiveKind.rar => 'RAR',
    ArchiveKind.sevenZip => '7Z',
    ArchiveKind.bz2 => 'BZ2',
  };

  /// 走同步路径（`archive` 包）还是异步路径（`koni_archive`）。
  ///
  /// zip / gz 用既有的 `archive` 包（同步、零依赖、已有测试覆盖）。
  /// rar / 7z / bz2 交给 `koni_archive` —— 纯 Dart 实现，无原生依赖，
  /// Windows 可用（`rar` / `flutter_rar` / `unrar` 这几个包是 FFI 或
  /// 平台插件，桌面端拿不到）。
  bool get supported => true;

  /// 需要 `koni_archive` 异步解包的格式。
  bool get needsKoni => this != ArchiveKind.zip && this != ArchiveKind.gz;
}

/// 归档类型识别（魔数；非归档返回 null）。允许短字节数组。
ArchiveKind? detectArchiveKind(List<int> bytes) {
  if (bytes.length < 2) return null;
  if (bytes.length >= 4 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21) {
    return ArchiveKind.rar; // Rar!
  }
  if (bytes[0] == 0x50 && bytes[1] == 0x4b) return ArchiveKind.zip; // PK
  if (bytes[0] == 0x1f && bytes[1] == 0x8b) return ArchiveKind.gz;
  if (bytes.length >= 6 &&
      bytes[0] == 0x37 &&
      bytes[1] == 0x7a &&
      bytes[2] == 0xbc &&
      bytes[3] == 0xaf &&
      bytes[4] == 0x27 &&
      bytes[5] == 0x1c) {
    return ArchiveKind.sevenZip;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x42 &&
      bytes[1] == 0x5a &&
      bytes[2] == 0x68) {
    return ArchiveKind.bz2; // BZh
  }
  return null;
}

/// 包内条目。
class ArchiveEntry extends PickableEntry {
  ArchiveEntry({required super.name, required super.bytes});
}

/// 解出归档内的全部文件条目（目录项剔除）。
///
/// zip / gz 走同步路径（`archive` 包）；rar / 7z / bz2 走
/// [extractArchiveEntriesAsync]（`koni_archive`，纯 Dart）。
///
/// **同步入口只处理 zip/gz**。遇到 rar/7z/bz2 会抛 [SubtitleException]，
/// 提示调用方改用异步版本 —— 这是为了避免为了异步能力把整条字幕链路改成
/// `Future`（会牵连 5 个调用点和一堆测试）。
List<ArchiveEntry> extractArchiveEntries(List<int> bytes) {
  final kind = detectArchiveKind(bytes);
  if (kind == null) return const <ArchiveEntry>[];
  if (kind.needsKoni) {
    throw SubtitleException(
      '${kind.label} 压缩包需要异步解包，请用 extractArchiveEntriesAsync',
    );
  }
  try {
    if (kind == ArchiveKind.zip) return _zipEntries(bytes);
    return _gunzipEntry(bytes);
  } catch (_) {
    return const <ArchiveEntry>[];
  }
}

/// 解出归档内的全部文件条目（异步版，支持 ZIP / GZ / RAR / 7Z / BZ2）。
///
/// 为什么需要异步：assrt 上大量字幕以 `.rar` 发布（实测 id=733904
/// 「人性本兽 Animals 2026」整包就是 rar，内含 4 个 srt）。原先
/// 「暂不支持解压 RAR 压缩包，请手动解压」的提示对用户是死路。
///
/// `koni_archive` 是纯 Dart 的 RAR4/RAR5/7z 读取器，无 FFI、无原生依赖，
/// Windows 桌面可用（`rar` / `flutter_rar` / `unrar` 那几个包是 FFI 或
/// 平台插件，桌面端拿不到）。
Future<List<ArchiveEntry>> extractArchiveEntriesAsync(List<int> bytes) async {
  final kind = detectArchiveKind(bytes);
  if (kind == null) return const <ArchiveEntry>[];
  if (!kind.needsKoni) return extractArchiveEntries(bytes);

  koni.Archive? archive;
  try {
    archive = await koni.Archive.openBytes(Uint8List.fromList(bytes));
    final out = <ArchiveEntry>[];
    for (final e in archive.entries) {
      if (e.type != koni.ArchiveEntryType.file) continue;
      if (e.path.endsWith('/')) continue;
      // 上限：字幕包正常几十 KB ~ 几 MB；给 64MB 兜住异常膨胀的包。
      if (e.uncompressedSize > 64 << 20) continue;
      final data = await archive.readBytes(e, maxSize: 64 << 20);
      if (data.isEmpty) continue;
      out.add(ArchiveEntry(name: e.path, bytes: data));
    }
    return out;
  } catch (e) {
    throw SubtitleException('${kind.label} 压缩包解压失败：${_shortArchiveError(e)}');
  } finally {
    try {
      await archive?.close();
    } catch (_) {}
  }
}

/// 异常压成一行（koni 的错误信息可能很长，直接塞进 UI 不合适）。
String _shortArchiveError(Object e) {
  final text = e.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length <= 120 ? text : '${text.substring(0, 120)}…';
}

List<ArchiveEntry> _zipEntries(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final out = <ArchiveEntry>[];
    for (final f in archive.files) {
      if (f.isDirectory || f.name.endsWith('/')) continue;
      final data = f.content;
      if (data.isEmpty) continue;
      out.add(ArchiveEntry(name: f.name, bytes: data));
    }
    return out;
  } catch (_) {
    return const <ArchiveEntry>[];
  }
}

/// gzip：单文件流；条目名优先取头里的 FNAME，缺失时用占位名。
List<ArchiveEntry> _gunzipEntry(List<int> bytes) {
  final data = const GZipDecoder().decodeBytes(bytes);
  return <ArchiveEntry>[
    ArchiveEntry(name: _gzName(bytes) ?? 'subtitle.srt', bytes: data),
  ];
}

/// gzip 头 FNAME 字段（FLG bit3；偏移 10 起，0 结尾）。
String? _gzName(List<int> buf) {
  if (buf.length < 11) return null;
  final flg = buf[3];
  if ((flg & 0x08) == 0) return null;
  var end = 10;
  while (end < buf.length && buf[end] != 0) {
    end++;
  }
  if (end <= 10) return null;
  final raw = String.fromCharCodes(buf.sublist(10, end));
  final name = raw.replaceAll('\\', '/').split('/').last;
  return name.isEmpty ? null : name;
}
