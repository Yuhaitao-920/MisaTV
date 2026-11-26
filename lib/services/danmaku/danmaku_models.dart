// 弹幕数据层模型（对齐旧版 src/shared/danmaku.ts）。

/// 外部弹幕接口条目：`url` = 站点 + token 路径（无尾斜杠）。
class DanmakuEndpoint {
  const DanmakuEndpoint({
    required this.name,
    required this.url,
    this.enabled = true,
  });

  final String name;
  final String url;
  final bool enabled;

  DanmakuEndpoint copyWith({String? name, String? url, bool? enabled}) {
    return DanmakuEndpoint(
      name: name ?? this.name,
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'enabled': enabled,
  };

  @override
  bool operator ==(Object other) =>
      other is DanmakuEndpoint &&
      other.name == name &&
      other.url == url &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(name, url, enabled);

  @override
  String toString() => 'DanmakuEndpoint($name, $url, enabled=$enabled)';
}

/// 内置接口清单：默认只启用「炊烟袅袅」，其余由播放器「弹幕源」面板按需开启。
const List<DanmakuEndpoint> builtinDanmakuEndpoints = [
  DanmakuEndpoint(
    name: '炊烟袅袅',
    url: 'https://danmu.cynn.top/cynnsq',
    enabled: true,
  ),
  DanmakuEndpoint(
    name: 'LogVar',
    url: 'https://dm.abai.ccwu.cc/abai',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '御坂',
    url: 'https://dmk.abai.ccwu.cc/api/v1/abaibai',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'Lily',
    url: 'https://danmu.lily.lat/lilyemby',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'Lily',
    url: 'https://danmu.longemby.com/lilyemby',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '墨云阁',
    url: 'https://danmu.wangziyang.top/020116',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '麦当劳',
    url: 'https://logo.saodu.work:8888',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '麦当劳',
    url: 'https://ybdm.saodu.wang:9999/api/v1/IN5H9udKhmMMklvDYVPs',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'W佬',
    url: 'https://dm.660505.xyz:8443/a123456',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '稳健',
    url: 'https://dandan.wenjian.de/wenjian',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '鸢尾 Iris',
    url: 'https://justdanmu.irisnb.com/iris-danmu',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '夏天',
    url: 'https://dm.wodenas.xin/xiatianemby',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'Uncle Joel',
    url: 'https://dmfl.us.ci',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '小助理',
    url: 'https://danmu.qianting168.com/456765847636987622146901',
    enabled: false,
  ),
  DanmakuEndpoint(name: '睡觉', url: 'https://danmu.0000996.xyz', enabled: false),
  DanmakuEndpoint(name: '晨曦', url: 'https://dm.199333.xyz/dm', enabled: false),
  DanmakuEndpoint(
    name: '乔蒂深',
    url: 'https://logvarrn.278612356.xyz/steven',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '乔蒂深',
    url: 'https://logvardm.278612356.xyz/steven',
    enabled: false,
  ),
  DanmakuEndpoint(name: 'dx.sld.tw', url: 'https://dx.sld.tw', enabled: false),
  DanmakuEndpoint(
    name: 'dm.626258.xyz',
    url: 'https://dm.626258.xyz',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'dmapi.6565n.xyz',
    url: 'https://dmapi.6565n.xyz',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: '88920.dpdns.org',
    url: 'https://88920.dpdns.org',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'logvar.hhht.cc.cd',
    url: 'https://logvar.hhht.cc.cd',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'logvar-danmu.rinrin.top',
    url: 'https://logvar-danmu.rinrin.top',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'Dm.lJiaoVm.com',
    url: 'https://Dm.lJiaoVm.com/luosen',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'logvar-rinrin.netlify.app',
    url: 'https://logvar-rinrin.netlify.app/r1NYa9i',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'danmu-api-five-pink',
    url: 'https://danmu-api-five-pink.vercel.app/999999',
    enabled: false,
  ),
  DanmakuEndpoint(
    name: 'logdanmu.kongcheng666',
    url: 'https://logdanmu.kongcheng666.dpdns.org/a123456',
    enabled: false,
  ),
];

/// 内置清单的**新副本**（勿让调用方共享同一数组引用）。
List<DanmakuEndpoint> defaultDanmakuEndpoints() {
  return [for (final e in builtinDanmakuEndpoints) e.copyWith()];
}

/// 弹幕类型：scroll / top / bottom。
class DanmakuItem {
  const DanmakuItem({
    required this.time,
    required this.type,
    required this.text,
    required this.size,
    required this.color,
  });

  /// 弹幕出现时间（秒，相对于片源）。
  final double time;

  /// 弹幕类型：滚动 / 顶部固定 / 底部固定。
  final String type;

  /// 弹幕文本（已反转义）。
  final String text;

  /// 源字号（px，已按 B 站规范 clamp 12-40）。
  final int size;

  /// 颜色（#rrggbb）。
  final String color;

  @override
  bool operator ==(Object other) =>
      other is DanmakuItem &&
      other.time == time &&
      other.type == type &&
      other.text == text &&
      other.size == size &&
      other.color == color;

  @override
  int get hashCode => Object.hash(time, type, text, size, color);

  @override
  String toString() => 'DanmakuItem($time, $type, $text, $size, $color)';
}

/// 剧集级候选（comment 接口需要 episodeId）。
class DanmakuCandidate {
  const DanmakuCandidate({
    required this.episodeId,
    this.title = '',
    this.episodeTitle = '',
    this.episodeNumber = '',
    this.source = '',
    this.sourceName = '',
  });

  final int episodeId;

  /// 番剧标题。
  final String title;

  /// 剧集标题（如 第1话 / 01）。
  final String episodeTitle;

  /// 接口给的集号字段（`episodeNumber`，实测炊烟/腾讯系为 "1"/"2"…）。
  final String episodeNumber;

  /// 来源接口基础地址。
  final String source;

  /// 来源显示名。
  final String sourceName;

  @override
  bool operator ==(Object other) =>
      other is DanmakuCandidate &&
      other.episodeId == episodeId &&
      other.title == title &&
      other.episodeTitle == episodeTitle &&
      other.episodeNumber == episodeNumber &&
      other.source == source &&
      other.sourceName == sourceName;

  @override
  int get hashCode => Object.hash(
    episodeId,
    title,
    episodeTitle,
    episodeNumber,
    source,
    sourceName,
  );

  @override
  String toString() =>
      'DanmakuCandidate($episodeId, $title, $episodeTitle, ep=$episodeNumber, $source)';
}

/// 番剧级候选（`/api/v2/search/anime` 返回，剧集列表需再用 bangumiId 拉取）。
class DanmakuAnime {
  DanmakuAnime({
    required this.animeId,
    required this.title,
    int? bangumiId,
    this.kind = '',
    this.episodeCount = 0,
    this.source = '',
    this.sourceName = '',
  }) : bangumiId = bangumiId ?? animeId;

  final int animeId;

  /// 番剧标题。
  final String title;

  /// 剧集列表接口（bangumi/{bangumiId}）用的 id。
  final int bangumiId;

  /// 类型（tvseries / movie / ova 等）。
  final String kind;

  /// 条目集数（聚合源 `episodeCount`；0 = 未提供）。
  final int episodeCount;

  /// 来源接口基础地址。
  final String source;

  /// 来源显示名。
  final String sourceName;

  @override
  String toString() => 'DanmakuAnime($animeId/$bangumiId, $title, $source)';
}
