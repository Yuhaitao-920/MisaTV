import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/utils/file_url.dart';
import '../core/utils/json_utils.dart';

class LocalImportPayload {
  const LocalImportPayload({required this.name, required this.text});
  final String name;
  final String text;
}

/// 本地订阅 / 本地蜘蛛 / 本地包导入。
///
/// 所有本地内容都会复制到应用数据目录后再使用：原文件/文件夹被删除或移动
/// 不会让已导入的源失效（与旧版 Win-Box 的托管副本口径一致）。
class LocalImportService {
  const LocalImportService._();

  static const _localFileExtensions = <String>[
    '.py',
    '.js',
    '.jar',
    '.json',
    '.txt',
    '.m3u',
    '.m3u8',
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.ico',
  ];

  /// 导入本地 `.json` 订阅文件。
  static Future<LocalImportPayload> fromJsonFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) throw Exception('文件不存在：$path');
    final text = await file.readAsString();
    return LocalImportPayload(
      name: p.basenameWithoutExtension(file.path),
      text: rewriteLocalPaths(text, p.dirname(file.path)),
    );
  }

  /// 导入一组 `.py` 蜘蛛：复制到托管目录，返回可直接并入订阅的站点条目。
  ///
  /// key 用「文件名 + 内容 md5」：同一个文件重复导入会更新原站点而不是重复添加。
  static Future<List<Map<String, dynamic>>> pySites(List<String> paths) async {
    final root = await _managedDir('local_py');
    final sites = <Map<String, dynamic>>[];
    final seenKeys = <String>{};
    for (final path in paths) {
      final source = File(path);
      if (!source.existsSync()) continue;
      final bytes = await source.readAsBytes();
      if (bytes.isEmpty) continue;
      final base = p.basenameWithoutExtension(source.path);
      final safe = _safeName(base);
      final digest = md5.convert(bytes).toString();
      final key = 'py_${safe}_$digest';
      if (!seenKeys.add(key)) continue;
      final target = File(p.join(root.path, '${safe}_$digest.py'));
      if (!target.existsSync()) await source.copy(target.path);
      sites.add({
        'key': key,
        'name': base,
        'type': 3,
        'api': fileUrlOf(target.path),
      });
    }
    if (sites.isEmpty) throw Exception('没有可导入的 .py 文件');
    return sites;
  }

  /// 导入单个 `.py` 蜘蛛：生成只含该源的 TVBox 配置（旧入口兼容）。
  static Future<LocalImportPayload> fromPyFile(String path) async {
    final sites = await pySites([path]);
    return LocalImportPayload(
      name: sites.first['name'].toString(),
      text: const JsonEncoder.withIndent('  ').convert({'sites': sites}),
    );
  }

  /// 导入本地包目录：整个目录复制到托管目录，再找订阅 JSON；
  /// 只有 `.py` 文件时自动生成一份只含这些源的配置。
  static Future<LocalImportPayload> fromPackage(String dirPath) async {
    final source = Directory(dirPath);
    if (!source.existsSync()) throw Exception('文件夹不存在：$dirPath');
    final name = _safeName(p.basename(source.path));
    final root = await _managedDir('local_pkgs');
    final target = Directory(
      p.join(root.path, '${name}_${DateTime.now().millisecondsSinceEpoch}'),
    );
    await _copyDirectory(source, target);
    return _payloadFromDirectory(target, name);
  }

  /// 导入 ZIP 形式本地包（常见于 CatVod / TVBox 离线包）。
  static Future<LocalImportPayload> fromPackageArchive(String zipPath) async {
    final source = File(zipPath);
    if (!source.existsSync()) throw Exception('文件不存在：$zipPath');
    final name = _safeName(p.basenameWithoutExtension(source.path));
    final root = await _managedDir('local_pkgs');
    final target = Directory(
      p.join(root.path, '${name}_${DateTime.now().millisecondsSinceEpoch}'),
    );
    target.createSync(recursive: true);

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    } catch (e) {
      throw Exception('不是有效的 ZIP 文件：$e');
    }
    final rootPath = p.normalize(p.absolute(target.path));
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final rawName = entry.name.replaceAll('\\', '/');
      if (rawName.isEmpty || rawName.startsWith('__MACOSX/')) continue;
      final dest = p.normalize(p.join(rootPath, rawName));
      if (!p.isWithin(rootPath, dest)) continue;
      final data = entry.readBytes();
      if (data == null || data.isEmpty) continue;
      final file = File(dest);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data);
    }
    return _payloadFromDirectory(target, name);
  }

  static Future<LocalImportPayload> _payloadFromDirectory(
    Directory package,
    String name,
  ) async {
    final jsonFile = findSubscriptionJson(package);
    if (jsonFile != null) {
      final text = await jsonFile.readAsString();
      // 相对路径以 JSON 所在目录为准（CatVod 包常把 config.json 放在子目录里）。
      return LocalImportPayload(
        name: p.basenameWithoutExtension(jsonFile.path),
        text: rewriteLocalPaths(text, p.dirname(jsonFile.path)),
      );
    }

    final pys =
        package
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.py'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (pys.isEmpty) {
      throw Exception('这个本地包里没有找到订阅 JSON，也没有 .py 蜘蛛文件');
    }
    final sites = <Map<String, dynamic>>[];
    for (var i = 0; i < pys.length; i++) {
      final file = pys[i];
      final base = p.basenameWithoutExtension(file.path);
      sites.add({
        'key': 'py_${_safeName(base)}_$i',
        'name': base,
        'type': 3,
        'api': fileUrlOf(file.path),
      });
    }
    return LocalImportPayload(
      name: name,
      text: const JsonEncoder.withIndent('  ').convert({'sites': sites}),
    );
  }

  /// 本地包里的订阅 JSON：优先 `config.json` / `api.json` / `index.json`，
  /// 再按目录层级由浅到深找包含 `sites` / `urls` / `lives` 的那份。
  ///
  /// CatVod 离线包经常把配置放在一级子目录（如 `local/config.json`），
  /// 不能只看包根。
  static File? findSubscriptionJson(Directory root) {
    final candidates = _jsonFiles(root, maxDepth: 3);
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final pa = _jsonPriority(a);
      final pb = _jsonPriority(b);
      if (pa != pb) return pa.compareTo(pb);
      final da = p.split(p.relative(a.path, from: root.path)).length;
      final db = p.split(p.relative(b.path, from: root.path)).length;
      if (da != db) return da.compareTo(db);
      return a.path.compareTo(b.path);
    });
    for (final file in candidates) {
      try {
        final text = trimJsonObject(file.readAsStringSync());
        if (text.contains('"sites"') || text.contains('"urls"')) return file;
      } catch (_) {
        // 坏文件跳过
      }
    }
    for (final file in candidates) {
      try {
        final text = trimJsonObject(file.readAsStringSync());
        if (text.contains('"lives"')) return file;
      } catch (_) {
        // 坏文件跳过
      }
    }
    return null;
  }

  static List<File> _jsonFiles(
    Directory dir, {
    required int maxDepth,
    int depth = 0,
  }) {
    final out = <File>[];
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        final base = p.basename(entity.path);
        if (base.startsWith('.') || base == '__MACOSX') continue;
        if (entity is File) {
          if (base.toLowerCase().endsWith('.json')) out.add(entity);
        } else if (entity is Directory && depth < maxDepth) {
          out.addAll(_jsonFiles(entity, maxDepth: maxDepth, depth: depth + 1));
        }
      }
    } catch (_) {
      // 权限 / 坏目录跳过
    }
    return out;
  }

  static int _jsonPriority(File file) {
    final name = p.basename(file.path).toLowerCase();
    if (name == 'config.json' || name == 'api.json') return 0;
    if (name == 'index.json') return 1;
    return 2;
  }

  /// 把订阅里指向包内的相对路径改写成 `file://`。
  ///
  /// 兼容 CatVod / TVBox 离线包的三种写法：
  ///   · `./spider.jar`、`jar/custom_spider.jar;md5;...`（相对 JSON 所在目录）
  ///   · `clan://localhost/<包名>/spider.jar`（本地包虚拟路径）
  ///   · `assets://` / `pkg://` 指向包内资源
  /// 同时改写站点 `ext`：CatVod 包常用 ext 指向包内 json / txt 配置。
  static String rewriteLocalPaths(String text, String packageRoot) {
    final trimmed = trimJsonObject(text);
    if (trimmed.isEmpty) return text;
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return text;
    }
    if (decoded is! Map) return text;
    final root = Map<String, dynamic>.from(decoded);

    for (final key in const ['spider', 'logo', 'wallpaper']) {
      if (root.containsKey(key)) root[key] = _localRef(root[key], packageRoot);
    }
    for (final key in const ['sites', 'lives', 'parses']) {
      final list = root[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        for (final field in const [
          'api',
          'url',
          'jar',
          'playUrl',
          'ext',
          'icon',
          'logo',
        ]) {
          if (map.containsKey(field)) {
            map[field] = _localRef(map[field], packageRoot);
          }
        }
        final index = list.indexOf(item);
        if (index >= 0) list[index] = map;
      }
    }
    return const JsonEncoder.withIndent('  ').convert(root);
  }

  static dynamic _localRef(dynamic value, String packageRoot) {
    if (value is! String) return value;
    final raw = value.trim();
    if (raw.isEmpty) return value;
    final lower = raw.toLowerCase();
    if (RegExp(
      r'^(https?|file|proxy)://',
      caseSensitive: false,
    ).hasMatch(raw)) {
      return value;
    }

    // CatVod / TVBox 本地包虚拟路径：按包内相对文件解析。
    String? relative;
    if (lower.startsWith('clan://localhost/')) {
      relative = raw.substring('clan://localhost/'.length);
    } else if (lower.startsWith('assets://')) {
      relative = raw.substring('assets://'.length);
    } else if (lower.startsWith('pkg://')) {
      relative = raw.substring('pkg://'.length);
    }
    if (relative != null) {
      final nested = _splitRef(relative);
      final found = _findInPackage(packageRoot, nested.path);
      if (found == null) return value;
      return '${fileUrlOf(found)}${nested.suffix}${nested.query}';
    }

    if (!_localFileExtensions.any((ext) => lower.contains(ext))) return value;
    if (raw.length > 2048) return value;
    final parts = _splitRef(raw);
    final found = _findInPackage(packageRoot, parts.path);
    if (found == null) return value;
    return '${fileUrlOf(found)}${parts.suffix}${parts.query}';
  }

  /// 拆出 `.py?name=X` 的查询串、`URL;md5;xxx` 的校验尾缀，
  /// 以及 `./config/env.json$线路名` 的 `$` 自定义参数。
  ///
  /// `$` 后缀是 TVBox 生态里常见的「同一份配置、多套参数」写法：脚本拿到 ext 后
  /// 自己按 `$` 切开，前面是配置地址，后面是这条线路的名字（如 wanpan.js 的
  /// `const [url, order] = ext.split('$')`）。如果不把它拆出来，整串会被当成
  /// 文件路径 `env.json$闪电` 去找，必然找不到 → 原样退回 → 线路名保留但
  /// **地址仍是 `./config/env.json` 相对路径**，脚本再去请求就 404。
  static ({String path, String suffix, String query}) _splitRef(String raw) {
    final queryIndex = raw.indexOf('?');
    final query = queryIndex >= 0 ? raw.substring(queryIndex) : '';
    final head = queryIndex >= 0 ? raw.substring(0, queryIndex) : raw;
    final semicolon = head.indexOf(';');
    final afterSem = semicolon >= 0 ? head.substring(0, semicolon) : head;
    final suffix = semicolon >= 0 ? head.substring(semicolon) : '';
    // `$` 只在「后面确实还有内容」时才算分隔符，避免误伤结尾的单个 `$`。
    final dollar = afterSem.indexOf(r'$');
    final path = dollar > 0 ? afterSem.substring(0, dollar) : afterSem;
    final tail = dollar > 0 ? afterSem.substring(dollar) : '';
    return (path: path, suffix: '$tail$suffix', query: query);
  }

  /// 在本地包里找引用指向的文件：先按完整相对路径，再试去掉一级目录、
  /// 最后只用文件名（兼容 `clan://localhost/<包名>/...` 的虚拟前缀）。
  static String? _findInPackage(String packageRoot, String ref) {
    var rel = ref.replaceAll('\\', '/').trim();
    if (rel.isEmpty) return null;
    if (p.isAbsolute(ref) && File(ref).existsSync()) return ref;
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    if (rel.isEmpty) return null;
    final root = p.normalize(p.absolute(packageRoot));
    final candidates = <String>[];
    void add(String value) {
      final dest = p.normalize(p.join(root, value));
      if (p.isWithin(root, dest)) candidates.add(dest);
    }

    add(rel);
    try {
      final decoded = Uri.decodeComponent(rel);
      if (decoded != rel) add(decoded);
    } catch (_) {
      // 非法百分号编码忽略
    }
    final parts = rel.split('/');
    if (parts.length > 1) add(parts.skip(1).join('/'));
    if (parts.isNotEmpty) add(parts.last);
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static Future<Directory> _managedDir(String child) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, child));
    dir.createSync(recursive: true);
    return dir;
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    target.createSync(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.path);
      final dest = p.join(target.path, relative);
      if (entity is Directory) {
        Directory(dest).createSync(recursive: true);
      } else if (entity is File) {
        final parent = Directory(p.dirname(dest));
        parent.createSync(recursive: true);
        await entity.copy(dest);
      }
    }
  }

  static String _safeName(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'local' : cleaned;
  }
}
