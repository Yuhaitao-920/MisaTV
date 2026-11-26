import 'dart:convert';
import 'dart:io';

import 'package:gbk_codec/gbk_codec.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/utils/file_url.dart';

class LocalLiveImport {
  const LocalLiveImport({required this.name, required this.filePath});
  final String name;
  final String filePath;
}

/// 本地 TXT / M3U 直播源：复制到应用数据目录，并统一成 UTF-8。
class LocalLiveService {
  const LocalLiveService._();

  static Future<LocalLiveImport> importFile(String path) async {
    final source = File(path);
    if (!source.existsSync()) throw Exception('文件不存在：$path');
    final bytes = await source.readAsBytes();
    final text = _decode(bytes).replaceFirst('\uFEFF', '');
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'local_live'));
    dir.createSync(recursive: true);
    final name = p.basenameWithoutExtension(source.path);
    final safe = _safeName(name);
    final ext = p.extension(source.path).toLowerCase();
    final target = File(
      p.join(dir.path, '${safe}_${DateTime.now().millisecondsSinceEpoch}$ext'),
    );
    await target.writeAsString(text);
    return LocalLiveImport(name: name, filePath: target.path);
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return latin1.decode(bytes);
      }
    }
  }

  static String _safeName(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'local_live' : cleaned;
  }

  /// 生成 `file://` 地址供 LiveService 读取。
  static String fileUrlOfPath(String path) => fileUrlOf(path);
}
