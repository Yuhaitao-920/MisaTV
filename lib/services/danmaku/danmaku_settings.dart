// 弹幕显示偏好与接口清单（对齐旧版 src/main/danmaku/DanmakuStore.ts 的读取口径）。
// 只做 JSON 读写与校验，不落盘（设置文件由调用方负责）。
import 'dart:convert';

import 'danmaku_endpoints.dart';
import 'danmaku_models.dart';

/// 接口清单默认开关修订号：rev2 起默认只启用「炊烟袅袅」；旧配置读取时一次性对齐。
const int danmakuEndpointsRev = 2;

/// 弹幕显示区域占屏幕高度的比例范围：10%（只占顶部一小条）到 100%（全屏）。
const double danmakuRegionMinRatio = 0.1;
const double danmakuRegionMaxRatio = 1.0;

/// 旧版字符串区域 → 比例（读取旧配置时一次性迁移）。
double danmakuLegacyRegionRatio(String region) => switch (region) {
  'threeQuarter' => 0.75,
  'half' => 0.5,
  'quarter' => 0.25,
  _ => 1.0,
};

class DanmakuSettings {
  const DanmakuSettings({
    required this.enabled,
    required this.regionRatio,
    required this.fontSize,
    required this.opacity,
    required this.density,
    required this.speed,
    required this.offset,
    required this.endpoints,
    this.blockWords = const [],
  });

  /// 默认值：弹幕关闭、全屏、24px、0.85 透明度、全量密度、110px/s、无偏移；仅炊烟袅袅启用。
  factory DanmakuSettings.defaults() => DanmakuSettings(
    enabled: false,
    regionRatio: 1,
    fontSize: 24,
    opacity: 0.85,
    density: 1,
    speed: 110,
    offset: 0,
    endpoints: defaultDanmakuEndpoints(),
  );

  /// 宽容解析 JSON（非法返回默认值）；逐项校验接口地址。
  factory DanmakuSettings.fromJsonString(String? json) {
    if (json == null || json.trim().isEmpty) return DanmakuSettings.defaults();
    dynamic raw;
    try {
      raw = jsonDecode(json);
    } catch (_) {
      return DanmakuSettings.defaults();
    }
    if (raw is! Map) return DanmakuSettings.defaults();
    return DanmakuSettings.fromJson(raw.cast<String, dynamic>());
  }

  factory DanmakuSettings.fromJson(Map<String, dynamic> raw) {
    final fallback = DanmakuSettings.defaults();
    final rev = _asInt(raw['endpointsRev']) ?? 1;
    // 逐项校验（非法地址剔除、尾斜杠归一、同地址去重），避免脏数据进到请求层。
    final stored = <DanmakuEndpoint>[];
    final seen = <String>{};
    final rawEndpoints = raw['endpoints'];
    if (rawEndpoints is List) {
      for (final e in rawEndpoints) {
        if (e is! Map) continue;
        final url = normalizeEndpointBase(_asString(e['url']));
        if (url.isEmpty || !seen.add(url)) continue;
        final name = _asString(e['name']).trim();
        stored.add(
          DanmakuEndpoint(
            name: name.isEmpty ? endpointLabel(url) : name,
            url: url,
            enabled: e['enabled'] != false,
          ),
        );
      }
    }
    final List<DanmakuEndpoint> endpoints;
    if (stored.isEmpty) {
      endpoints = defaultDanmakuEndpoints();
    } else if (rev < danmakuEndpointsRev) {
      // 旧配置 → 内置项开关回到默认（仅炊烟袅袅开）；用户自定义项保留原状态。
      final custom = stored.where((e) => !isBuiltinEndpoint(e.url)).toList();
      endpoints = [...defaultDanmakuEndpoints(), ...custom];
    } else {
      endpoints = stored;
    }
    final ratioRaw = _asDouble(raw['regionRatio']);
    final regionRatio = ratioRaw != null && ratioRaw.isFinite
        ? ratioRaw
              .clamp(danmakuRegionMinRatio, danmakuRegionMaxRatio)
              .toDouble()
        : danmakuLegacyRegionRatio(_asString(raw['region']));
    return DanmakuSettings(
      enabled: _asBool(raw['enabled']) ?? fallback.enabled,
      regionRatio: regionRatio,
      fontSize: _asDouble(raw['fontSize']) ?? fallback.fontSize,
      opacity: _asDouble(raw['opacity']) ?? fallback.opacity,
      density: _asDouble(raw['density']) ?? fallback.density,
      speed: _asDouble(raw['speed']) ?? fallback.speed,
      offset: _asDouble(raw['offset']) ?? fallback.offset,
      endpoints: endpoints,
      blockWords: _parseBlockWords(raw['blockWords']),
    );
  }

  final bool enabled;

  /// 弹幕显示区域占屏幕高度的比例（0.1–1.0）。
  final double regionRatio;
  final double fontSize;
  final double opacity;
  final double density;
  final double speed;
  final double offset;
  final List<DanmakuEndpoint> endpoints;

  /// 弹幕屏蔽词：普通关键词（包含即屏蔽）或 `/正则/`（不区分大小写）。
  final List<String> blockWords;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'regionRatio': regionRatio,
    'fontSize': fontSize,
    'opacity': opacity,
    'density': density,
    'speed': speed,
    'offset': offset,
    'endpoints': [for (final e in endpoints) e.toJson()],
    'endpointsRev': danmakuEndpointsRev,
    'blockWords': blockWords,
  };

  String toJsonString() => jsonEncode(toJson());

  DanmakuSettings copyWith({
    bool? enabled,
    double? regionRatio,
    double? fontSize,
    double? opacity,
    double? density,
    double? speed,
    double? offset,
    List<DanmakuEndpoint>? endpoints,
    List<String>? blockWords,
  }) {
    return DanmakuSettings(
      enabled: enabled ?? this.enabled,
      regionRatio: regionRatio ?? this.regionRatio,
      fontSize: fontSize ?? this.fontSize,
      opacity: opacity ?? this.opacity,
      density: density ?? this.density,
      speed: speed ?? this.speed,
      offset: offset ?? this.offset,
      endpoints: endpoints ?? this.endpoints,
      blockWords: blockWords ?? this.blockWords,
    );
  }
}

/// 屏蔽词归一：按行 / 逗号 / 顿号 / 分号切分，去空白与重复（保留 `/正则/` 原样）。
List<String> normalizeDanmakuBlockWords(String raw) {
  final out = <String>[];
  final seen = <String>{};
  for (final part in raw.split(RegExp(r'[\r\n,，、;；]+'))) {
    final word = part.trim();
    if (word.isEmpty) continue;
    final isRegex =
        word.length > 2 && word.startsWith('/') && word.endsWith('/');
    final key = isRegex ? word : word.toLowerCase();
    if (!seen.add(key)) continue;
    out.add(word);
  }
  return out;
}

/// 弹幕文本是否命中屏蔽词：`/.../` 按正则（不区分大小写）处理，其余按子串包含。
bool isDanmakuBlocked(String text, List<String> blockWords) {
  if (blockWords.isEmpty || text.isEmpty) return false;
  final lower = text.toLowerCase();
  for (final word in blockWords) {
    if (word.length > 2 && word.startsWith('/') && word.endsWith('/')) {
      try {
        if (RegExp(
          word.substring(1, word.length - 1),
          caseSensitive: false,
        ).hasMatch(text)) {
          return true;
        }
      } catch (_) {
        // 非法正则忽略，不影响其他屏蔽词
      }
      continue;
    }
    if (lower.contains(word.toLowerCase())) return true;
  }
  return false;
}

List<String> _parseBlockWords(dynamic raw) {
  if (raw is List) {
    return normalizeDanmakuBlockWords(
      raw.map((e) => e?.toString() ?? '').join('\n'),
    );
  }
  return normalizeDanmakuBlockWords(raw == null ? '' : raw.toString());
}

String _asString(dynamic v) => v == null ? '' : v.toString();

bool? _asBool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final t = v.trim().toLowerCase();
    if (t == 'true' || t == '1') return true;
    if (t == 'false' || t == '0') return false;
  }
  return null;
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}
