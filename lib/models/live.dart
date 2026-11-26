class LiveChannel {
  const LiveChannel({
    required this.name,
    required this.urls,
    this.logo = '',
    this.epg = '',
    this.ua = '',
    this.click = '',
    this.format = '',
    this.origin = '',
    this.referer = '',
    this.tvgId = '',
    this.tvgName = '',
    this.tvgChno = '',
    this.header,
    this.catchupType = '',
    this.catchupSource = '',
    this.catchupReplace = '',
  });

  final String name;
  final List<String> urls;
  final String logo;
  final String epg;
  final String ua;
  final String click;
  final String format;
  final String origin;
  final String referer;
  final String tvgId;
  final String tvgName;
  final String tvgChno;
  final Map<String, String>? header;
  final String catchupType;
  final String catchupSource;
  final String catchupReplace;

  Map<String, dynamic> toJson() => {
    'name': name,
    'urls': urls,
    'logo': logo,
    'epg': epg,
    'ua': ua,
    'click': click,
    'format': format,
    'origin': origin,
    'referer': referer,
    'tvgId': tvgId,
    'tvgName': tvgName,
    'tvgChno': tvgChno,
    if (header != null) 'header': header,
    'catchupType': catchupType,
    'catchupSource': catchupSource,
    'catchupReplace': catchupReplace,
  };

  factory LiveChannel.fromJson(Map<String, dynamic> json) => LiveChannel(
    name: (json['name'] ?? '').toString(),
    urls: [
      for (final item
          in (json['urls'] is List ? json['urls'] as List : const []))
        item.toString(),
    ],
    logo: (json['logo'] ?? '').toString(),
    epg: (json['epg'] ?? '').toString(),
    ua: (json['ua'] ?? '').toString(),
    click: (json['click'] ?? '').toString(),
    format: (json['format'] ?? '').toString(),
    origin: (json['origin'] ?? '').toString(),
    referer: (json['referer'] ?? '').toString(),
    tvgId: (json['tvgId'] ?? '').toString(),
    tvgName: (json['tvgName'] ?? '').toString(),
    tvgChno: (json['tvgChno'] ?? '').toString(),
    header: json['header'] is Map
        ? {
            for (final e in (json['header'] as Map).entries)
              e.key.toString(): e.value.toString(),
          }
        : null,
    catchupType: (json['catchupType'] ?? '').toString(),
    catchupSource: (json['catchupSource'] ?? '').toString(),
    catchupReplace: (json['catchupReplace'] ?? '').toString(),
  );
}

class LiveLine {
  const LiveLine({required this.index, required this.name, required this.url});
  final int index;
  final String name;
  final String url;

  Map<String, dynamic> toJson() => {'index': index, 'name': name, 'url': url};

  factory LiveLine.fromJson(Map<String, dynamic> json) => LiveLine(
    index: (json['index'] as num?)?.toInt() ?? 0,
    name: (json['name'] ?? '').toString(),
    url: (json['url'] ?? '').toString(),
  );
}

class LiveGroup {
  const LiveGroup({required this.group, required this.channels});
  final String group;
  final List<LiveChannel> channels;

  Map<String, dynamic> toJson() => {
    'group': group,
    'channels': channels.map((e) => e.toJson()).toList(),
  };

  factory LiveGroup.fromJson(Map<String, dynamic> json) => LiveGroup(
    group: (json['group'] ?? '').toString(),
    channels: [
      for (final item
          in (json['channels'] is List ? json['channels'] as List : const []))
        if (item is Map) LiveChannel.fromJson(Map<String, dynamic>.from(item)),
    ],
  );
}

List<LiveLine> channelLines(LiveChannel channel) {
  final out = <LiveLine>[];
  for (var i = 0; i < channel.urls.length; i++) {
    final raw = channel.urls[i];
    final parts = raw.split(r'$');
    final url = parts.first.trim();
    final name = parts.length > 1 && parts[1].trim().isNotEmpty
        ? parts[1].trim()
        : '源${i + 1}';
    if (url.isEmpty) continue;
    out.add(LiveLine(index: i + 1, name: name, url: url));
  }
  return out;
}
