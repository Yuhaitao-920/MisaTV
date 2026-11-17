import 'dart:convert';

import '../core/utils/text_utils.dart';
import '../models/live.dart';
import '../models/site_config.dart';

class LiveParser {
  /// 直播订阅地址本身就是一个 HLS 播放列表（而不是频道列表）：
  /// `live.catvod.com` 这类带 token 的地址会直接回一份媒体/主播放列表。
  /// 解析成频道只会得到一堆 `.ts` 分片，必须把它当作「单条直播流」。
  static bool isDirectPlaylist(String raw) {
    final upper = raw.toUpperCase();
    return upper.contains('#EXT-X-TARGETDURATION') ||
        upper.contains('#EXT-X-MEDIA-SEQUENCE') ||
        upper.contains('#EXT-X-STREAM-INF');
  }

  /// 把直链播放列表包成一条可直接点播的频道。
  static List<LiveGroup> directStream(
    String name,
    String url, {
    String ua = '',
    String referer = '',
    Map<String, String>? header,
  }) {
    return [
      LiveGroup(
        group: name.isEmpty ? defaultGroupName : name,
        channels: [
          LiveChannel(
            name: name.isEmpty ? defaultChannelName : name,
            urls: [url],
            ua: ua,
            referer: referer,
            header: header,
          ),
        ],
      ),
    ];
  }

  /// 把直播单级 UA / Referer / 公共头补到每个频道上。
  ///
  /// 不少直播服务按 UA 或 Referer 同时校验「订阅列表」和「频道流」：
  /// 列表能拉到（LiveService 用了 okhttp/3.12.0），播放器却拿着裸地址去取流，
  /// 表现就是频道列表正常、一点开就 invalid or unsupported media。
  static List<LiveGroup> applyDefaults(
    List<LiveGroup> groups, {
    String ua = '',
    String referer = '',
    Map<String, String>? header,
  }) {
    if (groups.isEmpty || (ua.isEmpty && referer.isEmpty && header == null)) {
      return groups;
    }
    return groups
        .map(
          (group) => LiveGroup(
            group: group.group,
            channels: group.channels
                .map(
                  (c) => LiveChannel(
                    name: c.name,
                    urls: c.urls,
                    logo: c.logo,
                    epg: c.epg,
                    ua: c.ua.isEmpty ? ua : c.ua,
                    click: c.click,
                    format: c.format,
                    origin: c.origin,
                    referer: c.referer.isEmpty ? referer : c.referer,
                    tvgId: c.tvgId,
                    tvgName: c.tvgName,
                    tvgChno: c.tvgChno,
                    header: c.header ?? header,
                    catchupType: c.catchupType,
                    catchupSource: c.catchupSource,
                    catchupReplace: c.catchupReplace,
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  /// 把订阅根 `headers` 里按 host 配置的请求头补到频道上。
  ///
  /// 播放器 / 回看只认频道自己的 `header` / `ua` / `referer`，所以规则命中
  /// 频道任一线路的 host 时，按该规则浅拷贝一份频道并补齐这三个字段；
  /// 频道自己已经带了同名头时以频道为准（直播单里的逐条声明更具体）。
  static List<LiveGroup> applyHostHeaders(
    List<LiveGroup> groups,
    List<HeaderRule> rules,
  ) {
    if (groups.isEmpty || rules.isEmpty) return groups;
    return [
      for (final group in groups)
        LiveGroup(
          group: group.group,
          channels: [
            for (final channel in group.channels)
              _withHostHeader(channel, rules),
          ],
        ),
    ];
  }

  static LiveChannel _withHostHeader(
    LiveChannel channel,
    List<HeaderRule> rules,
  ) {
    HeaderRule? hit;
    for (final url in channel.urls) {
      hit = headerRuleForUrl(url, rules);
      if (hit != null) break;
    }
    if (hit == null || hit.header.isEmpty) return channel;
    final merged = <String, String>{...?channel.header};
    for (final entry in hit.header.entries) {
      final exists = merged.keys.any(
        (k) => k.toLowerCase() == entry.key.toLowerCase(),
      );
      if (!exists) merged[entry.key] = entry.value;
    }
    final ua = channel.ua.isNotEmpty
        ? channel.ua
        : _headerValue(merged, 'user-agent');
    final referer = channel.referer.isNotEmpty
        ? channel.referer
        : _headerValue(merged, 'referer');
    return LiveChannel(
      name: channel.name,
      urls: channel.urls,
      logo: channel.logo,
      epg: channel.epg,
      ua: ua,
      click: channel.click,
      format: channel.format,
      origin: channel.origin,
      referer: referer,
      tvgId: channel.tvgId,
      tvgName: channel.tvgName,
      tvgChno: channel.tvgChno,
      header: merged,
      catchupType: channel.catchupType,
      catchupSource: channel.catchupSource,
      catchupReplace: channel.catchupReplace,
    );
  }

  static String _headerValue(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return '';
  }

  static List<LiveGroup> parseToGroups(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return const [];
    try {
      final decoded = jsonDecode(s);
      if (decoded is List) return _normalizeJson(decoded);
    } catch (_) {}
    if (s.startsWith('#EXTM3U')) return _parseM3u(s);
    return _parseTxt(s);
  }

  static List<LiveGroup> _normalizeJson(List groups) {
    final result = <_Group>[];
    for (final ge in groups) {
      if (ge is! Map) continue;
      final groupObj = Map<String, dynamic>.from(ge);
      var groupName = (groupObj['group'] ?? '').toString();
      if (groupName.isEmpty) {
        groupName = (groupObj['name'] ?? defaultGroupName).toString();
      }
      final outGroup = _Group(normalizeGroupName(groupName));
      final channels = groupObj['channels'] is List
          ? groupObj['channels'] as List
          : (groupObj['channel'] is List
                ? groupObj['channel'] as List
                : const []);
      for (final ce in channels) {
        if (ce is! Map) continue;
        final co = Map<String, dynamic>.from(ce);
        final ch = _Channel()
          ..name = (co['name'] ?? '').toString()
          ..urls = (co['urls'] is List)
              ? (co['urls'] as List)
                    .map((e) => e.toString().trim())
                    .where((e) => isLiveUrl(e))
                    .toList()
              : <String>[]
          ..logo = (co['logo'] ?? '').toString()
          ..epg = (co['epg'] ?? '').toString()
          ..ua = (co['ua'] ?? '').toString()
          ..click = (co['click'] ?? '').toString()
          ..format = (co['format'] ?? '').toString()
          ..origin = (co['origin'] ?? '').toString()
          ..referer = (co['referer'] ?? '').toString()
          ..tvgId = (co['tvg-id'] ?? '').toString()
          ..tvgName = (co['tvg-name'] ?? '').toString()
          ..tvgChno = (co['tvg-chno'] ?? '').toString()
          ..parse = int.tryParse(co['parse']?.toString() ?? '');
        if (co['header'] is Map) {
          ch.header = (co['header'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        }
        final catchup = co['catchup'];
        if (catchup is Map) {
          ch.catchupType = (catchup['type'] ?? '').toString();
          ch.catchupSource = (catchup['source'] ?? '').toString();
          ch.catchupReplace = (catchup['replace'] ?? '').toString();
        }
        final cs = (co['catchup-source'] ?? '').toString();
        if (cs.isNotEmpty && ch.catchupSource.isEmpty) ch.catchupSource = cs;
        final cr = (co['catchup-replace'] ?? '').toString();
        if (cr.isNotEmpty && ch.catchupReplace.isEmpty) ch.catchupReplace = cr;
        _addChannel(outGroup, ch);
      }
      result.add(outGroup);
    }
    return _toGroups(result);
  }

  static List<LiveGroup> _parseM3u(String raw) {
    final result = <_Group>[];
    final pendingMeta = <String, dynamic>{};
    _Group? currentGroup;
    _Channel? pendingChannel;
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '');
    for (var rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTM3U')) {
        pendingMeta.clear();
        _mergeMetaTo(pendingMeta, m3uMeta(line));
        continue;
      }
      if (isSettingLine(line)) {
        _mergeMetaTo(pendingMeta, m3uSettings(line));
        continue;
      }
      if (line.startsWith('#EXTINF') || line.contains('#EXTINF')) {
        final groupName = normalizeGroupName(m3uGroup(line));
        currentGroup = _findOrCreateGroup(result, groupName);
        pendingChannel = _Channel()..name = extractM3uName(line);
        _mergeMetaToChannel(pendingChannel, m3uMeta(line));
        _mergeMetaToChannel(pendingChannel, pendingMeta);
        pendingMeta.clear();
        continue;
      }
      if (line.startsWith('#')) continue;
      currentGroup ??= _findOrCreateGroup(result, defaultGroupName);
      pendingChannel ??= _Channel();
      final parts = line.split('|');
      final url = parts.first.trim();
      if (!isLiveUrl(url)) continue;
      if (parts.length > 1) {
        _mergeMetaTo(
          pendingMeta,
          _parseHeaderString(parts.sublist(1).join('|')),
        );
      }
      _mergeMetaToChannel(pendingChannel, pendingMeta);
      if (!pendingChannel.urls.contains(url)) pendingChannel.urls.add(url);
      _addChannel(currentGroup, pendingChannel);
      pendingMeta.clear();
    }
    return _toGroups(result);
  }

  static List<LiveGroup> _parseTxt(String raw) {
    final result = <_Group>[];
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '');
    _Group? currentGroup;
    final pendingMeta = <String, dynamic>{};
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (isSettingLine(line)) _mergeMetaTo(pendingMeta, m3uSettings(line));
        continue;
      }
      if (line.contains('#genre#')) {
        final groupName = line.split(',').first.trim();
        currentGroup = _findOrCreateGroup(result, groupName);
        pendingMeta.clear();
        continue;
      }
      final split = line.split(',');
      if (split.length < 2) continue;
      currentGroup ??= _findOrCreateGroup(result, defaultGroupName);
      final channel = _Channel()..name = split.first.trim();
      _mergeMetaToChannel(channel, pendingMeta);
      final urls = <String>[];
      for (final part in split.sublist(1).join(',').trim().split('#')) {
        final url = part.trim();
        if (isLiveUrl(url) && !urls.contains(url)) urls.add(url);
      }
      if (urls.isEmpty) continue;
      channel.urls = urls;
      _addChannel(currentGroup, channel);
      pendingMeta.clear();
    }
    return _toGroups(result);
  }

  static Map<String, dynamic> _parseHeaderString(String text) {
    final headers = <String, String>{};
    for (final param in text.split('&')) {
      final idx = param.indexOf('=');
      if (idx <= 0) continue;
      headers[param.substring(0, idx).trim().replaceAll('"', '')] = param
          .substring(idx + 1)
          .trim()
          .replaceAll('"', '');
    }
    return headers.isEmpty ? const {} : {'header': headers};
  }

  static void _mergeMetaTo(Map<String, dynamic> dst, Map<String, dynamic> src) {
    for (final e in src.entries) {
      if (e.key == 'header') {
        if (e.value is Map) {
          dst['header'] = (e.value as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        } else {
          try {
            final decoded = jsonDecode(e.value.toString());
            if (decoded is Map) {
              dst['header'] = decoded.map(
                (k, v) => MapEntry(k.toString(), v.toString()),
              );
            }
          } catch (_) {}
        }
      } else {
        dst[e.key] = e.value;
      }
    }
  }

  static void _mergeMetaToChannel(_Channel ch, Map<String, dynamic> meta) {
    for (final e in meta.entries) {
      switch (e.key) {
        case 'logo':
          if (ch.logo.isEmpty) ch.logo = e.value.toString();
        case 'epg':
          if (ch.epg.isEmpty) ch.epg = e.value.toString();
        case 'ua':
          if (ch.ua.isEmpty) ch.ua = e.value.toString();
        case 'click':
          if (ch.click.isEmpty) ch.click = e.value.toString();
        case 'format':
          if (ch.format.isEmpty) ch.format = e.value.toString();
        case 'origin':
          if (ch.origin.isEmpty) ch.origin = e.value.toString();
        case 'referer':
          if (ch.referer.isEmpty) ch.referer = e.value.toString();
        case 'tvg-id':
          if (ch.tvgId.isEmpty) ch.tvgId = e.value.toString();
        case 'tvg-name':
          if (ch.tvgName.isEmpty) ch.tvgName = e.value.toString();
        case 'tvg-chno':
          if (ch.tvgChno.isEmpty) ch.tvgChno = e.value.toString();
        case 'parse':
          ch.parse ??= int.tryParse(e.value.toString());
        case 'header':
          if (e.value is Map) {
            ch.header ??= (e.value as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            );
          }
        case 'catchup':
          final value = e.value.toString();
          if (value.contains('\u0001')) {
            final parts = value.split('\u0001');
            if (parts.isNotEmpty) ch.catchupType = parts[0];
            if (parts.length > 1) ch.catchupSource = parts[1];
            if (parts.length > 2) ch.catchupReplace = parts[2];
          } else {
            ch.catchupType = value;
          }
      }
    }
  }

  static _Group _findOrCreateGroup(List<_Group> result, String name) {
    final n = normalizeGroupName(name);
    for (final g in result) {
      if (g.group == n) return g;
    }
    final g = _Group(n);
    result.add(g);
    return g;
  }

  static void _addChannel(_Group group, _Channel channel) {
    final name = channel.name;
    _Channel? existing;
    if (name.isNotEmpty) {
      for (final c in group.channels) {
        if (c.name == name) {
          existing = c;
          break;
        }
      }
    }
    if (existing == null) {
      group.channels.add(channel);
      return;
    }
    for (final u in channel.urls) {
      final t = u.trim();
      if (isLiveUrl(t) && !existing.urls.contains(t)) existing.urls.add(t);
    }
    if (existing.logo.isEmpty) existing.logo = channel.logo;
    if (existing.epg.isEmpty) existing.epg = channel.epg;
    if (existing.ua.isEmpty) existing.ua = channel.ua;
    if (existing.click.isEmpty) existing.click = channel.click;
    if (existing.format.isEmpty) existing.format = channel.format;
    if (existing.origin.isEmpty) existing.origin = channel.origin;
    if (existing.referer.isEmpty) existing.referer = channel.referer;
    if (existing.tvgId.isEmpty) existing.tvgId = channel.tvgId;
    if (existing.tvgName.isEmpty) existing.tvgName = channel.tvgName;
    if (existing.tvgChno.isEmpty) existing.tvgChno = channel.tvgChno;
    existing.header ??= channel.header;
    existing.parse ??= channel.parse;
  }

  static List<LiveGroup> _toGroups(List<_Group> groups) {
    final out = <LiveGroup>[];
    for (final g in groups) {
      final channels = <LiveChannel>[];
      for (final c in g.channels) {
        if (c.urls.isEmpty) continue;
        channels.add(
          LiveChannel(
            name: c.name.isEmpty ? defaultChannelName : c.name,
            urls: c.urls,
            logo: c.logo,
            epg: c.epg,
            ua: c.ua,
            click: c.click,
            format: c.format,
            origin: c.origin,
            referer: c.referer,
            tvgId: c.tvgId,
            tvgName: c.tvgName,
            tvgChno: c.tvgChno,
            header: c.header,
            catchupType: c.catchupType,
            catchupSource: c.catchupSource,
            catchupReplace: c.catchupReplace,
          ),
        );
      }
      if (channels.isNotEmpty) {
        out.add(LiveGroup(group: g.group, channels: channels));
      }
    }
    return out;
  }
}

class _Group {
  _Group(this.group);
  final String group;
  final List<_Channel> channels = [];
}

class _Channel {
  String name = '';
  List<String> urls = [];
  String logo = '';
  String epg = '';
  String ua = '';
  String click = '';
  String format = '';
  String origin = '';
  String referer = '';
  String tvgId = '';
  String tvgName = '';
  String tvgChno = '';
  int? parse;
  Map<String, String>? header;
  String catchupType = '';
  String catchupSource = '';
  String catchupReplace = '';
}
