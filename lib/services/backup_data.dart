import 'dart:convert';

import '../models/drive_account.dart';
import '../models/site_config.dart';

/// 设置备份的格式校验与旧版 Win-Box 备份迁移。
///
/// 本应用导出的原生备份：
/// `{ kind: "kniephos-backup", version: 1, profiles: [...], ... }`
///
/// 同时兼容旧版 Electron Win-Box 的 `win-box-backup`（v1）以及它的
/// `user-config.json`：把其中的 `sources/lives/parses/global` 或 `profiles[].json`
/// 转成当前 `ConfigProfile`，网盘 Cookie 转成 `DriveAccount`。
class BackupData {
  const BackupData._();

  static const kind = 'kniephos-backup';
  static const version = 1;

  static Map<String, dynamic> parse(String text) {
    dynamic raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      throw const FormatException('不是有效的 JSON 文件');
    }
    if (raw is! Map) throw const FormatException('备份内容不是 JSON 对象');
    final map = Map<String, dynamic>.from(raw);

    if (map['kind'] == kind || map['format'] == kind) {
      final v = (map['version'] as num?)?.toInt() ?? 0;
      if (v < 1) throw const FormatException('备份版本号缺失或非法');
      if (v > version) {
        throw FormatException('备份版本 $v 高于当前支持的 $version，请升级软件后再导入');
      }
      return map;
    }
    if (map['kind'] == 'win-box-backup' || map['app'] == 'win-box') {
      return _fromWinBox(map);
    }

    // 直接选了 user-config.json 的情况（外层可能是 JsonStore 的字符串包裹）。
    final userConfig = _decodeUserConfig(map['user-config'] ?? map);
    if (userConfig != null) return _fromUserConfig(userConfig, sourceUrl: '');
    throw const FormatException('不是 MisaTV 或 Win-Box 的设置备份文件');
  }

  static Map<String, dynamic> _fromWinBox(Map<String, dynamic> map) {
    final settings = map['settings'] is Map
        ? Map<String, dynamic>.from(map['settings'] as Map)
        : <String, dynamic>{};
    final userConfig = _decodeUserConfig(settings['userConfig']);
    if (userConfig == null) {
      throw const FormatException('备份里缺少设置内容（settings.userConfig）');
    }
    final result = _fromUserConfig(userConfig, sourceUrl: '');
    final drives = <Map<String, dynamic>>[];
    final tokens = settings['driveTokens'];
    if (tokens is Map) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in tokens.entries) {
        final provider = entry.key.toString().trim();
        final cookie = entry.value?.toString().trim() ?? '';
        if (provider.isEmpty || cookie.isEmpty) continue;
        drives.add(
          DriveAccount(
            provider: provider,
            cookie: cookie,
            updatedAt: now,
          ).toJson(),
        );
      }
    }
    result['driveAccounts'] = drives;
    return result;
  }

  static Map<String, dynamic> _fromUserConfig(
    Map<String, dynamic> userConfig, {
    required String sourceUrl,
  }) {
    final profiles = <Map<String, dynamic>>[];
    final rawProfiles = userConfig['profiles'];
    if (rawProfiles is List) {
      for (final entry in rawProfiles) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final rawJson = _decodeJsonString(map['json']);
        if (rawJson == null) continue;
        final sites = rawJson['sites'] is List
            ? rawJson['sites'] as List
            : const [];
        final lives = rawJson['lives'] is List
            ? rawJson['lives'] as List
            : const [];
        final name = (map['name'] ?? '').toString().trim();
        profiles.add(
          ConfigProfile(
            id: (map['id'] ?? '').toString().trim().isEmpty
                ? 'legacy${DateTime.now().millisecondsSinceEpoch}${profiles.length}'
                : map['id'].toString(),
            name: name.isEmpty ? 'Win-Box 配置 ${profiles.length + 1}' : name,
            url: (map['apiUrl'] ?? sourceUrl).toString(),
            rawJson: jsonEncode(rawJson),
            importedAt:
                DateTime.tryParse((map['importedAt'] ?? '').toString()) ??
                DateTime.now(),
            siteCount: sites.length,
            liveCount: lives.length,
          ).toJson(),
        );
      }
    }

    if (profiles.isEmpty) {
      final sites = userConfig['sources'] is List
          ? userConfig['sources'] as List
          : const [];
      final lives = userConfig['lives'] is List
          ? userConfig['lives'] as List
          : const [];
      if (sites.isNotEmpty || lives.isNotEmpty) {
        final global = userConfig['global'] is Map
            ? Map<String, dynamic>.from(userConfig['global'] as Map)
            : const <String, dynamic>{};
        final rawJson = {
          'sites': sites,
          'lives': lives,
          'parses': userConfig['parses'] is List
              ? userConfig['parses']
              : const [],
          'spider': global['spider'] ?? userConfig['spider'] ?? '',
          'flags': global['flags'] ?? userConfig['flags'] ?? const [],
        };
        profiles.add(
          ConfigProfile(
            id: 'legacy${DateTime.now().millisecondsSinceEpoch}',
            name: 'Win-Box 备份',
            url: (userConfig['apiUrl'] ?? sourceUrl).toString(),
            rawJson: jsonEncode(rawJson),
            importedAt: DateTime.now(),
            siteCount: sites.length,
            liveCount: lives.length,
          ).toJson(),
        );
      }
    }

    final activeOld = (userConfig['activeProfileId'] ?? '').toString();
    final active = profiles.any((p) => p['id'] == activeOld)
        ? activeOld
        : (profiles.isNotEmpty ? profiles.first['id'] as String : null);
    final ui = userConfig['ui'] is Map
        ? Map<String, dynamic>.from(userConfig['ui'] as Map)
        : const <String, dynamic>{};

    return {
      'kind': kind,
      'version': version,
      'profiles': profiles,
      'activeProfileId': active,
      'activeSiteKey': ui['activeSourceKey'] ?? '',
      'activeLiveKey': '',
      'favorites': const [],
      'history': const [],
      'searchHistory': const [],
      'driveAccounts': const [],
    };
  }

  static Map<String, dynamic>? _decodeUserConfig(dynamic raw) {
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      if (map.containsKey('sources') || map.containsKey('profiles')) return map;
      if (map.containsKey('user-config')) {
        return _decodeUserConfig(map['user-config']);
      }
      return null;
    }
    final decoded = _decodeJsonString(raw);
    if (decoded != null) {
      if (decoded.containsKey('sources') || decoded.containsKey('profiles')) {
        return decoded;
      }
    }
    return null;
  }

  static Map<String, dynamic>? _decodeJsonString(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}
