import '../relay/local_relay.dart';

/// 点播筛选与豆瓣分类共用的「全部」文案。
const String allTag = '全部';

/// 一级分类：电影 / 剧集 / 综艺（综艺在豆瓣里同属 tv，用 tag 区分）。
class DiscoverMediaOption {
  const DiscoverMediaOption({
    required this.id,
    required this.name,
    required this.mediaType,
    this.baseTag = '',
  });

  final String id;
  final String name;

  /// 下发豆瓣请求时使用的媒体类型：`movie` / `tv`。
  final String mediaType;

  /// 该分类固定携带的豆瓣 tag（电影为空）。
  final String baseTag;
}

const List<DiscoverMediaOption> discoverMedia = [
  DiscoverMediaOption(id: 'movie', name: '电影', mediaType: 'movie'),
  DiscoverMediaOption(id: 'tv', name: '剧集', mediaType: 'tv', baseTag: '电视剧'),
  DiscoverMediaOption(
    id: 'variety',
    name: '综艺',
    mediaType: 'tv',
    baseTag: '综艺',
  ),
];

class DiscoverItem {
  const DiscoverItem({
    required this.title,
    this.year,
    this.poster = '',
    this.mediaType = 'movie',
    this.doubanId = '',
  });

  final String title;
  final int? year;

  /// 豆瓣原始封面地址（显示前经本地 `/img` 中继）。
  final String poster;
  final String mediaType;
  final String doubanId;

  String get posterUrl =>
      relayImageUrl(poster, referer: 'https://m.douban.com/');
}

class DiscoverSection {
  const DiscoverSection({
    required this.id,
    required this.title,
    required this.items,
  });

  final String id;
  final String title;
  final List<DiscoverItem> items;
}

class ExploreDimension {
  const ExploreDimension({
    required this.key,
    required this.label,
    required this.values,
  });

  /// `类型` / `地区` / `年代`。
  final String key;
  final String label;

  /// 首项固定为「全部」。
  final List<String> values;
}

class ExploreSort {
  const ExploreSort({required this.id, required this.label});

  final String id;
  final String label;
}

class ExploreVocab {
  const ExploreVocab({
    required this.dimensions,
    required this.sorts,
    required this.defaultSort,
  });

  final List<ExploreDimension> dimensions;
  final List<ExploreSort> sorts;
  final String defaultSort;
}

class ExploreVocabulary {
  const ExploreVocabulary({
    required this.movie,
    required this.tv,
    this.source = 'builtin',
  });

  final ExploreVocab movie;
  final ExploreVocab tv;

  /// 词表来自在线豆瓣（`douban`）还是内置快照（`builtin`）。
  final String source;
}

/// 豆瓣「分类浏览」查询：tags 为已选各维度的豆瓣 tag（`全部` 不下发）。
class ExploreQuery {
  const ExploreQuery({
    required this.mediaType,
    this.tags = const [],
    this.sort = '',
    this.start = 0,
    this.count = 20,
  });

  final String mediaType;
  final List<String> tags;
  final String sort;
  final int start;
  final int count;
}

class ExplorePage {
  const ExplorePage({
    this.items = const [],
    this.start = 0,
    this.total = 0,
    this.hasMore = false,
  });

  final List<DiscoverItem> items;
  final int start;
  final int total;
  final bool hasMore;
}

/// 豆瓣条目（`subject_suggest` 命中结果）。
class DoubanSubject {
  const DoubanSubject({
    required this.id,
    required this.mediaType,
    required this.title,
    this.year = '',
    this.img = '',
  });

  final String id;
  final String mediaType;
  final String title;
  final String year;
  final String img;
}

/// 源演员字段里常混入「导演 / 编剧 / 饰 xxx」这类非演员条目。
///
/// 只做保守过滤：明显是职务、角色说明、纯数字或超长文本的丢弃；
/// 正常中英文姓名保留，避免误伤冷门演员。
bool looksLikeCastName(String raw) {
  final name = raw.trim();
  if (name.isEmpty || name.length > 20) return false;
  if (RegExp(r'^\d+$').hasMatch(name)) return false;
  if (RegExp(
    r'导演|编剧|监制|出品|制片|主演|演员|饰|配音|原著|改编|摄影|美术|剪辑|特效|统筹|策划|嘉宾|主持|友情|特别|联合|执行|总导演',
  ).hasMatch(name)) {
    return false;
  }
  return true;
}

/// 从源演员字段的单个片段里提取人名。
///
/// `孟子义(饰暮晚摇)` → `孟子义`；`导演 张三` / `饰 王响` → null。
String? castNameFromToken(String raw) {
  var name = raw.trim();
  if (name.isEmpty) return null;
  final roleIndex = name.indexOf('饰');
  if (roleIndex >= 0) {
    if (roleIndex == 0) return null;
    name = name
        .substring(0, roleIndex)
        .replaceAll(RegExp(r'[（(：:\s]+$'), '')
        .trim();
  }
  name = name.replaceFirst(RegExp(r'^主演\s*[:：]?\s*'), '').trim();
  if (name.isEmpty || !looksLikeCastName(name)) return null;
  return name;
}

/// 豆瓣演职员：演员名字 + 豆瓣人物头像 + 饰演角色。
///
/// 头像与角色来自 `/{movie|tv}/{id}/celebrities`（完整演员表），
/// 图床同样有 Referer 反盗链，展示时统一走本地 `/img` 中继。
class DoubanCastMember {
  const DoubanCastMember({
    required this.name,
    this.avatar = '',
    this.role = '',
    this.category = '',
  });

  final String name;

  /// 原始豆瓣头像地址（未经过中继）。
  final String avatar;

  /// 剧中角色（如「饰 程蝶衣」）。
  final String role;

  /// 豆瓣人物分类（导演 / 演员 / 编剧…）。
  final String category;

  String get avatarUrl =>
      relayImageUrl(avatar, referer: 'https://movie.douban.com/');

  bool get looksLikeActor =>
      category == '演员' || role.contains('演员') || role.contains('饰');
}

/// 豆瓣条目详情（封面 / 简介 / 评分 / 类型 / 演职员）。
class DoubanInfo {
  const DoubanInfo({
    required this.id,
    required this.mediaType,
    required this.title,
    this.year = '',
    this.intro = '',
    this.rating,
    this.cover = '',
    this.genres = const [],
    this.countries = const [],
    this.originalTitle = '',
    this.directors = const [],
    this.actors = const [],
    this.cast = const [],
  });

  final String id;
  final String mediaType;
  final String title;
  final String year;
  final String intro;
  final double? rating;
  final String cover;
  final List<String> genres;

  /// 制片国家 / 地区（豆瓣的 `countries`）。
  final List<String> countries;

  /// 原名 / 原始片名（日文、韩文或英文），Hero 标题排版用。
  final String originalTitle;
  final List<String> directors;
  final List<String> actors;

  /// 演职员头像（按 [actors] 顺序合并 credits，缺头像的条目保留占位）。
  final List<DoubanCastMember> cast;

  String get coverUrl => relayImageUrl(cover, referer: 'https://m.douban.com/');
}

/// 豆瓣「相关推荐」条目。
class DoubanExtraItem {
  const DoubanExtraItem({
    required this.id,
    required this.title,
    this.year,
    this.poster = '',
    this.overview = '',
    this.subtitle = '',
    this.rating,
    this.mediaType = 'movie',
  });

  final String id;
  final String title;
  final int? year;
  final String poster;
  final String overview;
  final String subtitle;
  final double? rating;
  final String mediaType;

  String get posterUrl =>
      relayImageUrl(poster, referer: 'https://m.douban.com/');
}

/// 豆瓣「影评」条目（列表只带摘要）。
class DoubanReviewItem {
  const DoubanReviewItem({
    required this.id,
    required this.title,
    this.abstract = '',
    this.rating,
    this.useful = 0,
    this.comments = 0,
    this.author = '',
    this.date = '',
  });

  final String id;
  final String title;
  final String abstract;
  final double? rating;
  final int useful;
  final int comments;
  final String author;
  final String date;
}

class DoubanDetailExtra {
  const DoubanDetailExtra({
    required this.id,
    this.recommendations = const [],
    this.reviews = const [],
  });

  final String id;
  final List<DoubanExtraItem> recommendations;
  final List<DoubanReviewItem> reviews;
}

/// 年代选项（豆瓣 tag 兼容：单年 / N0年代 / 更早）。
List<String> discoverYearValues([int? nowYear]) {
  final y = nowYear ?? DateTime.now().year;
  final out = <String>[allTag];
  for (var i = 0; i < 12; i++) {
    out.add('${y - i}');
  }
  out.addAll(const ['2010年代', '2000年代', '90年代', '80年代', '更早']);
  return out;
}

/// 年代 tag → 年份区间；`全部` / 非法值返回 null。
({int from, int to})? yearTagRange(String tag) {
  final v = tag.trim();
  if (v.isEmpty || v == allTag) return null;
  if (RegExp(r'^\d{4}$').hasMatch(v)) {
    final y = int.parse(v);
    return (from: y, to: y);
  }
  final m = RegExp(r'^(\d{4})年代$').firstMatch(v);
  if (m != null) {
    final y = int.parse(m.group(1)!);
    return (from: y, to: y + 9);
  }
  final m2 = RegExp(r'^(\d{2})年代$').firstMatch(v);
  if (m2 != null) {
    final y = int.parse(m2.group(1)!);
    final base = y >= 30 ? 1900 + y : 2000 + y;
    return (from: base, to: base + 9);
  }
  if (v == '更早') return (from: 0, to: 1979);
  return null;
}

/// 把豆瓣图床地址换成中继地址（未启动中继时原样返回）。
String relayImageUrl(String raw, {String referer = ''}) {
  final u = raw.trim();
  if (u.isEmpty) return '';
  final relay = LocalRelay.instance;
  if (!relay.running) return u;
  final query = <String, String>{'u': u};
  if (referer.trim().isNotEmpty) query['ref'] = referer.trim();
  return Uri.parse('${relay.baseUrl}/img')
      .replace(queryParameters: query)
      .toString();
}
