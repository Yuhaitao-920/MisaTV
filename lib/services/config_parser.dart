import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../core/net/url_utils.dart';
import '../core/utils/json_utils.dart';
import '../models/site_config.dart';

class ParsedConfig {
  const ParsedConfig({
    required this.config,
    required this.report,
    this.warnings = const [],
    this.multiUrls = const [],
  });

  final SiteConfig config;
  final ImportReport report;
  final List<String> warnings;
  final List<MultiConfigEntry> multiUrls;
}

class MultiConfigEntry {
  const MultiConfigEntry({required this.name, required this.url});
  final String name;
  final String url;
}

const _defaultSiteTimeout = 15;
const _siteTimeoutMin = 5;
const _siteTimeoutMax = 60;
const _liveTimeoutMin = 5;
const _liveTimeoutMax = 30;

class ConfigParser {
  static const empty = SiteConfig();

  /// 部分订阅地址直接返回 base64 包着的 JSON；能解出配置就返回明文，
  /// 否则原样返回交给宽容 JSON 解析。
  static String decodeBase64Payload(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty || trimmed.contains('{') || trimmed.contains('[')) {
      return body;
    }
    final compact = trimmed.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 24 || compact.length % 4 == 1) return body;
    if (!RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(compact)) return body;
    var padded = compact.replaceAll('-', '+').replaceAll('_', '/');
    final mod = padded.length % 4;
    if (mod > 0) padded = padded.padRight(padded.length + (4 - mod), '=');
    try {
      final decoded = utf8
          .decode(base64.decode(padded), allowMalformed: true)
          .trim();
      if (decoded.contains('{') || decoded.contains('[')) return decoded;
    } catch (_) {
      // 解不出来就按原文处理
    }
    return body;
  }

  /// 潇洒系订阅的自包含 wire format：
  /// hex(`$#key#$` + AES-CBC/PKCS7 密文 + 13 字节 IV)，key/IV 右补 ASCII `0` 到 16 字节。
  ///
  /// 只做本地解密，不向第三方发送订阅地址；格式、块长、padding 或输出任一不符
  /// 就返回原文，避免把损坏数据当配置。
  static String decodeCbcPayload(String body) {
    final compact = body.trim().replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 64 || compact.length.isOdd) return body;
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) return body;
    final bytes = _hexBytes(compact);
    if (bytes == null || bytes.length < 42) return body;
    if (bytes[0] != 0x24 || bytes[1] != 0x23) return body; // "$#"
    var sep = -1;
    for (var i = 2; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x23 && bytes[i + 1] == 0x24) {
        sep = i; // "#$"
        break;
      }
    }
    if (sep < 0) return body;
    final keyBytes = bytes.sublist(2, sep);
    final payload = bytes.sublist(sep + 2);
    if (keyBytes.isEmpty || keyBytes.length > 16) return body;
    for (final b in keyBytes) {
      if (b < 0x21 || b > 0x7e) return body;
    }
    if (payload.length < 16 + 13) return body;
    final cipherBytes = payload.sublist(0, payload.length - 13);
    final ivBytes = payload.sublist(payload.length - 13);
    if (cipherBytes.isEmpty || cipherBytes.length % 16 != 0) return body;

    try {
      final key = Uint8List(16)..fillRange(0, 16, 0x30);
      key.setRange(0, keyBytes.length, keyBytes);
      final iv = Uint8List(16)..fillRange(0, 16, 0x30);
      iv.setRange(0, 13, ivBytes);
      final cbc = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), iv));
      final out = Uint8List(cipherBytes.length);
      for (var off = 0; off < cipherBytes.length; off += 16) {
        cbc.processBlock(cipherBytes, off, out, off);
      }
      final pad = out.last;
      if (pad < 1 || pad > 16 || pad > out.length) return body;
      for (var i = out.length - pad; i < out.length; i++) {
        if (out[i] != pad) return body;
      }
      final text = utf8
          .decode(out.sublist(0, out.length - pad), allowMalformed: true)
          .trim();
      if (text.startsWith('{') || text.startsWith('[')) return text;
    } catch (_) {
      // 解密失败按原文处理
    }
    return body;
  }

  /// 订阅载体的统一解码入口：先试 CBC（hex + 标记），再试 base64。
  static String decodePayload(String body) {
    final embedded = decodeEmbeddedBase64Payload(body);
    if (!identical(embedded, body)) return embedded;
    final cbc = decodeCbcPayload(body);
    if (!identical(cbc, body)) return cbc;
    return decodeBase64Payload(body);
  }

  /// 部分订阅把配置 JSON 以 base64 **追加在图片末尾**（饭太硬 `/tv` 实测：
  /// JPEG 数据 + 17 KB base64）。整段不是 base64，只能从尾部找可解出 `sites/urls`
  /// 的连续 base64 段。
  static String decodeEmbeddedBase64Payload(String body) {
    if (body.isEmpty) return body;
    final matches = RegExp(r'[A-Za-z0-9+/=]{64,}').allMatches(body).toList();
    for (final m in matches.reversed) {
      var text = m.group(0)!;
      while (text.length % 4 != 0 && text.isNotEmpty) {
        text = text.substring(0, text.length - 1);
      }
      try {
        final decoded = utf8.decode(base64.decode(text), allowMalformed: true);
        if (decoded.contains('{') &&
            (decoded.contains('"sites"') || decoded.contains('"urls"'))) {
          return decoded;
        }
      } catch (_) {
        // 不是这一段的 base64 → 继续试前一段
      }
    }
    return body;
  }

  static Uint8List? _hexBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final hi = _hexVal(hex.codeUnitAt(i * 2));
      final lo = _hexVal(hex.codeUnitAt(i * 2 + 1));
      if (hi < 0 || lo < 0) return null;
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  static int _hexVal(int code) {
    if (code >= 0x30 && code <= 0x39) return code - 0x30;
    if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
    if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
    return -1;
  }

  static ParsedConfig parse(
    String content, {
    String baseUrl = '',
    bool jarReady = false,
  }) {
    final warnings = <String>[];
    final text = fixContentPath(baseUrl, decodePayload(content));
    final multi = parseCollection(text);
    if (multi != null) {
      return ParsedConfig(
        config: SiteConfig(),
        report: ImportReport.empty,
        warnings: warnings,
        multiUrls: multi,
      );
    }
    final jsonText = trimJsonObject(text);
    if (jsonText.isEmpty) {
      return ParsedConfig(
        config: SiteConfig(),
        report: ImportReport.empty,
        warnings: ['配置为空或无可识别 JSON 对象'],
      );
    }
    final dynamic decoded = parseJsonLenient(jsonText);
    if (decoded is! Map) {
      throw const FormatException('配置顶层必须是 JSON 对象');
    }
    final root = Map<String, dynamic>.from(decoded);
    if (root.containsKey('storeHouse') && !root.containsKey('sites')) {
      warnings.add('检测到 storeHouse 仓库格式，安卓端不支持，已忽略');
    }
    final sitesRaw = root['sites'];
    final liveRaw = root['lives'] is List ? root['lives'] : root['live'];
    final hasConfigKeys = root.keys.any(
      (k) => const {
        'lives',
        'live',
        'parses',
        'spider',
        'wallpaper',
        'danmaku',
      }.contains(k),
    );
    if (sitesRaw is! List && !hasConfigKeys) {
      throw const FormatException('返回的 JSON 不是 TVBox 订阅配置（没有 sites / lives）');
    }
    final sites = <SourceBean>[];
    final items = <SiteReportItem>[];
    if (sitesRaw is List) {
      for (var i = 0; i < sitesRaw.length; i++) {
        final result = parseSite(sitesRaw[i], i, jarReady: jarReady);
        if (result.bean != null) sites.add(result.bean!);
        items.add(result.report);
      }
    }
    final parses = <ParseBean>[];
    if (root['parses'] is List) {
      for (final p in root['parses'] as List) {
        if (p is Map) {
          parses.add(ParseBean.fromJson(Map<String, dynamic>.from(p)));
        }
      }
    }
    final lives = parseLives(liveRaw);
    final hosts = <String, String>{};
    final hostsRaw = root['hosts'];
    if (hostsRaw is List) {
      for (final h in hostsRaw) {
        final s = h.toString();
        final idx = s.indexOf('=');
        if (idx <= 0) continue;
        hosts[s.substring(0, idx)] = s.substring(idx + 1);
      }
    }
    final config = SiteConfig(
      sites: sites,
      parses: parses,
      lives: lives,
      flags: safeStringList(root, 'flags'),
      spider: safeString(root, 'spider'),
      jarCache: safeString(root, 'jarCache', 'true'),
      danmaku: safeString(root, 'danmaku'),
      wallpaper: safeString(root, 'wallpaper'),
      hosts: hosts,
      rules: root['rules'] is List ? root['rules'] as List : const [],
      doh: safeStringList(root, 'doh'),
      ads: safeStringList(root, 'ads'),
      proxy: root['proxy'] is List ? root['proxy'] as List : const [],
    );
    return ParsedConfig(
      config: config,
      report: buildImportReport(items),
      warnings: warnings,
    );
  }

  static List<MultiConfigEntry>? parseCollection(String text) {
    try {
      final json = trimJsonObject(text);
      if (json.isEmpty) return null;
      final decoded = parseJsonLenient(json);
      if (decoded is! Map) return null;
      final root = Map<String, dynamic>.from(decoded);
      if (root.containsKey('sites') ||
          !root.containsKey('urls') ||
          root['urls'] is! List) {
        return null;
      }
      final out = <MultiConfigEntry>[];
      for (final element in root['urls'] as List) {
        var name = '';
        var url = '';
        if (element is Map) {
          final m = Map<String, dynamic>.from(element);
          name = safeString(m, 'name');
          url = safeString(m, 'url');
          if (url.isEmpty) url = safeString(m, 'api');
        } else if (element is String) {
          url = element;
        }
        if (url.isNotEmpty) out.add(MultiConfigEntry(name: name, url: url));
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  static SiteParseResult parseSite(
    dynamic obj,
    int index, {
    bool jarReady = false,
  }) {
    final o = obj is Map ? Map<String, dynamic>.from(obj) : <String, dynamic>{};
    final hasKey = o['key'] != null && o['key'].toString().trim().isNotEmpty;
    final hasType = o['type'] != null;
    final hasApi = o['api'] != null && o['api'].toString().trim().isNotEmpty;
    final key = hasKey ? o['key'].toString().trim() : '';
    final api = hasApi ? o['api'].toString().trim() : '';
    final type = hasType ? safeInt(o, 'type', 0) : 0;

    if (!hasKey || !hasType || !hasApi) {
      final reason = !hasKey
          ? 'MISSING_KEY'
          : (!hasType ? 'MISSING_TYPE' : 'MISSING_API');
      return SiteParseResult(
        bean: null,
        report: SiteReportItem(
          index: index,
          key: key,
          name: key,
          type: type,
          api: api,
          status: 'SKIP',
          reason: reason,
          message: '跳过：缺少必填字段 ($reason)',
        ),
      );
    }

    if (type == 2) {
      return SiteParseResult(
        bean: null,
        report: SiteReportItem(
          index: index,
          key: key,
          name: safeString(o, 'name', key),
          type: type,
          api: api,
          status: 'SKIP',
          reason: 'UNKNOWN_TYPE',
          message: '跳过：type=2 无分发分支',
        ),
      );
    }

    final pyPrefix = key.startsWith('py_');
    final timeout = clampSiteTimeout(safeInt(o, 'timeout', 0));
    final bean = SourceBean(
      key: key,
      name: safeString(o, 'name', key),
      type: type,
      api: api,
      searchable: safeInt(o, 'searchable', 1),
      quickSearch: safeInt(o, 'quickSearch', 1),
      changeable: safeInt(o, 'changeable', 1),
      filterable: pyPrefix ? 1 : safeInt(o, 'filterable', 1),
      playUrl: safeString(o, 'playUrl'),
      ext: safeString(o, 'ext'),
      jar: safeString(o, 'jar'),
      playerType: safeInt(o, 'playerType', -1),
      categories: o['categories'] is List
          ? safeStringList(o, 'categories')
          : null,
      timeout: timeout,
      click: safeString(o, 'click'),
      style: safeString(o, 'style'),
      homePage: safeString(o, 'homePage'),
    );

    String status = 'OK';
    String? reason;
    String message = '已导入';
    if (type == -1) {
      status = 'DEGRADE';
      reason = 'UNSUPPORTED_PUSH';
      message = '降级：推送源暂不支持';
    } else if (type == 3 && bean.isJsSpider) {
      status = 'OK';
      message = '已导入（JS 蜘蛛）';
    } else if (type == 3 && bean.isPySpider) {
      status = 'OK';
      message = '已导入（PY 蜘蛛，首次使用需下载运行时）';
    } else if (type == 3) {
      if (jarReady) {
        status = 'OK';
        message = '已导入（JAR / DEX 蜘蛛）';
      } else {
        status = 'DEGRADE';
        reason = 'UNSUPPORTED_JAR';
        message = '降级：需先下载 JVM 运行时（设置 → 播放 → JVM 运行时）';
      }
    } else if (type == 5) {
      status = 'OK';
      message = '已导入（Kazumi 规则源）';
    } else if (type != 0 && type != 1 && type != 4) {
      status = 'SKIP';
      reason = 'UNKNOWN_TYPE';
      message = '跳过：未知源类型 $type';
    }

    return SiteParseResult(
      bean: bean,
      report: SiteReportItem(
        index: index,
        key: key,
        name: bean.name,
        type: type,
        api: api,
        status: status,
        reason: reason,
        message: message,
      ),
    );
  }

  static List<LiveBean> parseLives(dynamic raw) {
    if (raw is! List) return const [];
    final out = <LiveBean>[];
    for (var i = 0; i < raw.length; i++) {
      try {
        final o = raw[i] is Map
            ? Map<String, dynamic>.from(raw[i] as Map)
            : <String, dynamic>{};
        final name = safeString(o, 'name', '线路${i + 1}');
        final api = safeString(o, 'api');
        var type = o['type'] != null ? o['type'].toString().trim() : '';
        if (type.isEmpty) {
          final a = api.toLowerCase();
          type = (a.endsWith('.js') || a.endsWith('.py')) ? '3' : '0';
        }
        final url = safeString(o, 'url').isNotEmpty
            ? safeString(o, 'url')
            : api;
        final timeout = clampLiveTimeout(safeInt(o, 'timeout', 0));
        out.add(
          LiveBean(
            name: name,
            api: api,
            type: type,
            url: url,
            jar: safeString(o, 'jar'),
            ext: o['ext'] is Map || o['ext'] is List
                ? jsonEncode(o['ext'])
                : safeString(o, 'ext'),
            epg: safeString(o, 'epg'),
            playerType: safeString(o, 'playerType'),
            timeZone: safeString(o, 'timeZone'),
            timeout: timeout,
            header: o['header'] is Map
                ? (o['header'] as Map).map(
                    (k, v) => MapEntry(k.toString(), v.toString()),
                  )
                : null,
            ua: safeString(o, 'ua'),
          ),
        );
      } catch (_) {
        // 与上游一致：单条失败静默跳过
      }
    }
    return out;
  }

  static ImportReport buildImportReport(List<SiteReportItem> items) {
    var ok = 0;
    var skipped = 0;
    var degraded = 0;
    for (final it in items) {
      if (it.status == 'OK') {
        ok++;
      } else if (it.status == 'SKIP') {
        skipped++;
      } else {
        degraded++;
      }
    }
    return ImportReport(
      total: items.length,
      ok: ok,
      skipped: skipped,
      degraded: degraded,
      items: items,
    );
  }

  static int clampSiteTimeout(int v) {
    if (v <= 0) return _defaultSiteTimeout;
    if (v < _siteTimeoutMin) return _siteTimeoutMin;
    if (v > _siteTimeoutMax) return _siteTimeoutMax;
    return v;
  }

  static int clampLiveTimeout(int v) {
    if (v <= 0) return _defaultSiteTimeout;
    if (v < _liveTimeoutMin) return _liveTimeoutMin;
    if (v > _liveTimeoutMax) return _liveTimeoutMax;
    return v;
  }

  /// 把订阅里的相对路径按订阅地址解析成绝对地址。
  ///
  /// 相对路径不只出现在 JSON 值开头，TVBox 订阅里还有两种写法，漏掉就会让蜘蛛
  /// 拿到一个打不开的相对地址：`ext` 用 `$$$` 串多段文件
  /// （`./lib/token.json$$$./json/a.txt`），以及 `ext` 是单引号包着的 JSON 串
  /// （`{'token': './lib/token.json'}`）。
  /// 所以 `./` / `../` 只在「字符串起头」和「`$$$` 之后」两种位置才当路径。
  static String fixContentPath(String baseUrl, String content) {
    final normalized = normalizeHostUrl(baseUrl);
    if (normalized.isEmpty || content.isEmpty) return content;
    if (!content.contains('./') && !content.contains('../')) return content;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(normalized)) {
      return content;
    }
    final dir = normalized.substring(0, normalized.lastIndexOf('/') + 1);
    if (dir.isEmpty) return content;
    final dot = _resolveAgainst(dir, './');
    final dotDot = _resolveAgainst(dir, '../');
    const sep = r'$$$';

    return content
        .replaceAll('"./', '"$dot')
        .replaceAll('"../', '"$dotDot')
        .replaceAll("'./", "'$dot")
        .replaceAll("'../", "'$dotDot")
        .replaceAll(r'$$$./', '$sep$dot')
        .replaceAll(r'$$$../', '$sep$dotDot');
  }

  static String _resolveAgainst(String dir, String relative) {
    try {
      return Uri.parse(dir).resolve(relative).toString();
    } catch (_) {
      return dir;
    }
  }

  static bool looksLikeSubscribeJson(String text) {
    final t = text.trim();
    if (!t.startsWith('{')) return false;
    final head = t.length > 4096 ? t.substring(0, 4096) : t;
    return RegExp(
      r'"(sites|lives|live|urls|spider|parses|wallpaper|danmaku)"\s*:',
    ).hasMatch(head);
  }

  /// 正文是否像订阅 JSON（对象或数组）。
  ///
  /// 不少国产接口会把配置挂在图床 CDN 上，响应头写成 `image/jpeg` 躲封禁，
  /// 判断类型时要看正文而不是只看 Content-Type。
  static bool looksLikeJsonBody(String body) {
    final head = body.trimLeft().replaceFirst('\uFEFF', '').trimLeft();
    return head.startsWith('{') || head.startsWith('[');
  }

  static SiteConfig merge(List<SiteConfig> configs) {
    final sites = <SourceBean>[];
    final seenKeys = <String, int>{};
    final parses = <ParseBean>[];
    final lives = <LiveBean>[];
    final flags = <String>{};
    final hosts = <String, String>{};
    final rules = <dynamic>[];
    final doh = <String>{};
    final ads = <String>{};
    final proxy = <dynamic>[];
    var spider = '';

    for (final c in configs) {
      for (final site in c.sites) {
        var key = site.key;
        if (seenKeys.containsKey(key)) {
          final n = seenKeys[key]! + 1;
          seenKeys[key] = n;
          key = '${site.key}_$n';
          sites.add(
            SourceBean(
              key: key,
              name: '${site.name} ($n)',
              type: site.type,
              api: site.api,
              searchable: site.searchable,
              quickSearch: site.quickSearch,
              changeable: site.changeable,
              filterable: site.filterable,
              playUrl: site.playUrl,
              ext: site.ext,
              jar: site.jar,
              playerType: site.playerType,
              categories: site.categories,
              timeout: site.timeout,
              click: site.click,
              style: site.style,
              homePage: site.homePage,
            ),
          );
        } else {
          seenKeys[key] = 0;
          sites.add(site);
        }
      }
      for (final p in c.parses) {
        if (!parses.any((e) => e.name == p.name && e.url == p.url)) {
          parses.add(p);
        }
      }
      lives.addAll(c.lives);
      flags.addAll(c.flags);
      hosts.addAll(c.hosts);
      rules.addAll(c.rules);
      doh.addAll(c.doh);
      ads.addAll(c.ads);
      proxy.addAll(c.proxy);
      if (spider.isEmpty) spider = c.spider;
    }
    return SiteConfig(
      sites: sites,
      parses: parses,
      lives: lives,
      flags: flags.toList(),
      spider: spider,
      hosts: hosts,
      rules: rules,
      doh: doh.toList(),
      ads: ads.toList(),
      proxy: proxy,
    );
  }

  /// 合并导出：与导入时「重名追加 _2」不同，这里按 key 去重（先到先得），
  /// 并把各档案不同的全局 spider 回填到源自己的 `jar`，保证导出后仍可独立运行。
  static SiteConfig mergeForExport(List<SiteConfig> configs) {
    final spider = configs
        .map((c) => c.spider.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    final sites = <SourceBean>[];
    final seenKeys = <String>{};
    final parses = <ParseBean>[];
    final lives = <LiveBean>[];
    final liveKeys = <String>{};
    final flags = <String>{};
    final hosts = <String, String>{};
    final rules = <dynamic>[];
    final doh = <String>{};
    final ads = <String>{};
    final proxy = <dynamic>[];

    for (final c in configs) {
      for (final site in c.sites) {
        if (!seenKeys.add(site.key)) continue;
        final jar = site.jar.trim();
        final fallbackJar =
            jar.isEmpty &&
                c.spider.trim().isNotEmpty &&
                c.spider.trim() != spider
            ? c.spider.trim()
            : '';
        sites.add(
          fallbackJar.isEmpty
              ? site
              : SourceBean(
                  key: site.key,
                  name: site.name,
                  type: site.type,
                  api: site.api,
                  searchable: site.searchable,
                  quickSearch: site.quickSearch,
                  changeable: site.changeable,
                  filterable: site.filterable,
                  playUrl: site.playUrl,
                  ext: site.ext,
                  jar: fallbackJar,
                  playerType: site.playerType,
                  categories: site.categories,
                  timeout: site.timeout,
                  click: site.click,
                  style: site.style,
                  homePage: site.homePage,
                ),
        );
      }
      for (final p in c.parses) {
        if (!parses.any((e) => e.name == p.name && e.url == p.url)) {
          parses.add(p);
        }
      }
      for (final live in c.lives) {
        if (liveKeys.add('${live.name}|${live.url}')) lives.add(live);
      }
      flags.addAll(c.flags);
      hosts.addAll(c.hosts);
      rules.addAll(c.rules);
      doh.addAll(c.doh);
      ads.addAll(c.ads);
      proxy.addAll(c.proxy);
    }

    return SiteConfig(
      sites: sites,
      parses: parses,
      lives: lives,
      flags: flags.toList(),
      spider: spider,
      hosts: hosts,
      rules: rules,
      doh: doh.toList(),
      ads: ads.toList(),
      proxy: proxy,
    );
  }
}

class SiteParseResult {
  const SiteParseResult({required this.bean, required this.report});
  final SourceBean? bean;
  final SiteReportItem report;
}
