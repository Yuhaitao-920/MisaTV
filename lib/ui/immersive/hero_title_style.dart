import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSLColor;

import '../../services/fonts/hero_fonts.dart';

/// Hero 标题的排版方向：日文原名用竖排（海报感），其余横排。
enum HeroTitleOrientation { horizontal, vertical }

/// 标题底版的形状；长标题拆成两行时两行会用不同形状。
enum HeroTitleShape { slanted, notched, torn, band }

/// 一个标题最终的字体 / 文案 / 排版 / 配色方案。
class HeroTitlePlan {
  const HeroTitlePlan({
    required this.main,
    required this.lines,
    required this.secondary,
    required this.family,
    required this.orientation,
    required this.shape,
    required this.fontSize,
    required this.letterSpacing,
    required this.maxLines,
    required this.tilt,
    required this.skew,
    required this.accent,
    required this.titleTop,
    required this.titleBottom,
    required this.plate,
  });

  /// 主标题（有合适原名时显示原名，例如 `冷たい熱帯魚`）。
  final String main;

  /// 横排时拆成的 1–2 行；长标题会在这里做成上下两块不同形状的底版。
  final List<String> lines;

  /// 副标题（主标题显示原名时，这里放中文名）。
  final String secondary;

  /// 已安装字体的 family；为 null 时用主题字体。
  final String? family;

  final HeroTitleOrientation orientation;
  final HeroTitleShape shape;
  final double fontSize;
  final double letterSpacing;
  final int maxLines;

  /// 底版轻微旋转（弧度）与横向倾斜，做出海报感。
  final double tilt;
  final double skew;

  /// 类型配色：强调色、标题上下渐变色与底版底色。
  final Color accent;
  final Color titleTop;
  final Color titleBottom;
  final Color plate;

  bool get vertical => orientation == HeroTitleOrientation.vertical;

  bool get stacked => !vertical && lines.length > 1;
}

enum _HeroRegion { china, japan, korea, latin }

enum _HeroGenre {
  horror,
  period,
  wuxia,
  war,
  crime,
  scifi,
  animation,
  fantasy,
  western,
  action,
  comedy,
  romance,
  modern,
  drama,
}

/// 按地区 / 类型挑选字体、配色与排版。
///
/// 同一类型会准备多款风格接近的字体，再按片名做稳定散列：
/// 这样同类型的不同影片也会换字体，而不是全站共用一个槽位。
/// [familyOf] 默认读 [HeroFontService]，测试时可以注入假实现。
/// [allowVertical] 为 false 时即使日文原名也不竖排（详情页用）。
HeroTitlePlan buildHeroTitlePlan({
  required String title,
  String originalTitle = '',
  List<String> genres = const [],
  List<String> countries = const [],
  String? Function(HeroFontRole role)? familyOf,
  bool allowVertical = true,
  Color? tint,
}) {
  final lookup =
      familyOf ?? ((role) => HeroFontService.instance.familyOf(role));
  final original = originalTitle.trim();
  final region = _regionOf(countries, original, title);
  final hasGenre = genres.isNotEmpty;
  final genre = _genreOf(genres);
  final palette = _paletteOf(region, hasGenre ? genre : _HeroGenre.drama, tint);

  // 已安装的候选字体里按片名散列选一个；一个都没装再退回同地区通用字体。
  final candidates = hasGenre
      ? _candidatesOf(region, genre)
      : _neutralOf(region);
  String? family;
  final available = <HeroFontRole>[
    for (final role in candidates)
      if (lookup(role) != null) role,
  ];
  if (available.isNotEmpty) {
    family = lookup(available[_stableHash(title) % available.length]);
  } else {
    for (final role in _fallbacks[region]!) {
      family = lookup(role);
      if (family != null) break;
    }
  }

  var main = title.trim();
  var secondary = '';
  if (family != null && original.isNotEmpty && original != main) {
    final matches = switch (region) {
      _HeroRegion.japan => _hasKana(original) || _hasCjk(original),
      _HeroRegion.korea => _hasHangul(original),
      _HeroRegion.latin => _isLatin(original),
      _HeroRegion.china => false,
    };
    if (matches) {
      main = original;
      secondary = title.trim();
    }
  }

  final vertical =
      allowVertical &&
      family != null &&
      region == _HeroRegion.japan &&
      secondary.isNotEmpty &&
      _hasKana(main) &&
      main.runes.length <= 10;

  final shape = _shapeOf(genre);
  final (tilt, skew) = _tiltOf(genre);
  final count = main.runes.length;
  final latin = _isLatin(main);
  final lines = _titleLines(main);
  final longest = lines
      .map((line) => line.runes.length)
      .reduce((a, b) => a > b ? a : b);

  if (vertical) {
    final double size;
    if (count <= 4) {
      size = 72;
    } else if (count <= 6) {
      size = 62;
    } else if (count <= 8) {
      size = 54;
    } else {
      size = 44;
    }
    return HeroTitlePlan(
      main: main,
      lines: [main],
      secondary: secondary,
      family: family,
      orientation: HeroTitleOrientation.vertical,
      shape: shape,
      fontSize: size,
      letterSpacing: 3,
      maxLines: count,
      tilt: tilt,
      skew: skew,
      accent: palette.accent,
      titleTop: palette.top,
      titleBottom: palette.bottom,
      plate: palette.plate,
    );
  }

  // 标题整体放大：按最长一行决定字号，长标题拆行后也能保持海报感。
  final double size;
  final double spacing;
  if (latin) {
    if (longest <= 10) {
      size = 94;
      spacing = 2;
    } else if (longest <= 16) {
      size = 78;
      spacing = 1.6;
    } else if (longest <= 24) {
      size = 62;
      spacing = 1.2;
    } else {
      size = 50;
      spacing = 0.8;
    }
  } else if (longest <= 4) {
    size = 104;
    spacing = 10;
  } else if (longest <= 6) {
    size = 90;
    spacing = 8;
  } else if (longest <= 8) {
    size = 74;
    spacing = 6;
  } else {
    size = 60;
    spacing = 4;
  }

  return HeroTitlePlan(
    main: main,
    lines: lines,
    secondary: secondary,
    family: family,
    orientation: HeroTitleOrientation.horizontal,
    shape: shape,
    fontSize: size,
    letterSpacing: spacing,
    maxLines: lines.length > 1 ? 2 : (count > 24 ? 2 : 1),
    tilt: tilt,
    skew: skew,
    accent: palette.accent,
    titleTop: palette.top,
    titleBottom: palette.bottom,
    plate: palette.plate,
  );
}

/// Hero 顶部那行小字：有元数据时显示「类型 · 国家」，否则用原来的副标题。
String heroTagline({
  required List<String> genres,
  required List<String> countries,
  required String fallback,
}) {
  final parts = <String>[];
  if (genres.isNotEmpty) parts.add(genres.take(3).join(' / '));
  if (countries.isNotEmpty) parts.add(countries.first);
  if (parts.isEmpty) return fallback.toUpperCase();
  return parts.join(' · ');
}

/// 资源站字段（`type` / `area`）按分隔符拆成标签，作为豆瓣缺失时的兜底。
List<String> splitMetaHints(String raw) => raw
    .split(RegExp(r'[,，/、|;；]+'))
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toList();

_HeroRegion _regionOf(List<String> countries, String original, String title) {
  if (_countryHas(countries, '日本')) return _HeroRegion.japan;
  if (_countryHas(countries, '韩国') || _countryHas(countries, '韓國')) {
    return _HeroRegion.korea;
  }
  final china =
      _countryHas(countries, '中国') ||
      _countryHas(countries, '中國') ||
      _countryHas(countries, '大陆') ||
      _countryHas(countries, '大陸') ||
      _countryHas(countries, '内地') ||
      _countryHas(countries, '內地') ||
      _countryHas(countries, '香港') ||
      _countryHas(countries, '台湾') ||
      _countryHas(countries, '台灣') ||
      _countryHas(countries, '澳门') ||
      _countryHas(countries, '澳門');
  if (china) return _HeroRegion.china;
  if (countries.isNotEmpty) return _HeroRegion.latin;
  // 国家缺失时用文字判断；中文资源站默认按中文处理，至少能套上默认字体。
  if (_hasKana(original) || _hasKana(title)) return _HeroRegion.japan;
  if (_hasHangul(original) || _hasHangul(title)) return _HeroRegion.korea;
  if (_isLatin(original) && !_hasCjk(title)) return _HeroRegion.latin;
  return _HeroRegion.china;
}

_HeroGenre _genreOf(List<String> genres) {
  bool has(Set<String> tags) => genres.any((g) => tags.any(g.contains));
  if (has({'恐怖', '志怪'})) return _HeroGenre.horror;
  if (has({'战争', '戰爭', '灾难', '災難'})) return _HeroGenre.war;
  if (has({'武侠', '武俠', '仙侠', '仙俠', '江湖', '功夫', '修真'})) {
    return _HeroGenre.wuxia;
  }
  if (has({'古装', '古裝', '历史', '歷史', '传记', '傳記', '年代', '民国', '民國', '宫廷', '宮廷'})) {
    return _HeroGenre.period;
  }
  if (has({'犯罪', '悬疑', '懸疑', '惊悚', '驚悚', '黑色电影', '警匪'})) {
    return _HeroGenre.crime;
  }
  if (has({'科幻'})) return _HeroGenre.scifi;
  if (has({'动画', '動畫', '动漫', '動漫', '儿童', '兒童'})) {
    return _HeroGenre.animation;
  }
  if (has({'奇幻', '魔幻', '玄幻'})) return _HeroGenre.fantasy;
  if (has({'西部'})) return _HeroGenre.western;
  if (has({'动作', '動作', '冒险', '冒險'})) return _HeroGenre.action;
  if (has({'喜剧', '喜劇'})) return _HeroGenre.comedy;
  if (has({'爱情', '愛情'})) return _HeroGenre.romance;
  if (has({'都市', '职场', '職場', '商战', '商戰', '现代', '現代', '校园', '校園', '青春'})) {
    return _HeroGenre.modern;
  }
  return _HeroGenre.drama;
}

/// 每个地区 × 类型的候选字体，第一个最贴合，后面的用于分散复用率。
List<HeroFontRole> _candidatesOf(_HeroRegion region, _HeroGenre genre) =>
    switch (region) {
      _HeroRegion.china => switch (genre) {
        _HeroGenre.horror => const [
          HeroFontRole.zhHorror,
          HeroFontRole.zhPen,
          HeroFontRole.zhSong,
        ],
        _HeroGenre.wuxia => const [
          HeroFontRole.zhJianghu,
          HeroFontRole.zhBrush,
          HeroFontRole.zhCrime,
          HeroFontRole.zhSong,
        ],
        _HeroGenre.period => const [
          HeroFontRole.zhJianghu,
          HeroFontRole.zhBrush,
          HeroFontRole.zhSong,
          HeroFontRole.zhKai,
        ],
        _HeroGenre.war => const [
          HeroFontRole.zhWar,
          HeroFontRole.zhSong,
          HeroFontRole.zhModern,
          HeroFontRole.zhKai,
        ],
        _HeroGenre.crime => const [
          HeroFontRole.zhModern,
          HeroFontRole.zhSong,
          HeroFontRole.zhKai,
          HeroFontRole.zhWar,
        ],
        _HeroGenre.scifi => const [
          HeroFontRole.zhModern,
          HeroFontRole.zhWar,
          HeroFontRole.zhAnimation,
          HeroFontRole.zhSong,
        ],
        _HeroGenre.animation => const [
          HeroFontRole.zhAnimation,
          HeroFontRole.zhModern,
          HeroFontRole.zhKai,
          HeroFontRole.zhSong,
        ],
        _HeroGenre.fantasy => const [
          HeroFontRole.zhJianghu,
          HeroFontRole.zhBrush,
          HeroFontRole.zhModern,
          HeroFontRole.zhSong,
          HeroFontRole.zhKai,
        ],
        _HeroGenre.western => const [
          HeroFontRole.zhWar,
          HeroFontRole.zhJianghu,
          HeroFontRole.zhSong,
          HeroFontRole.zhModern,
        ],
        _HeroGenre.action => const [
          HeroFontRole.zhModern,
          HeroFontRole.zhWar,
          HeroFontRole.zhSong,
        ],
        _HeroGenre.comedy => const [
          HeroFontRole.zhAnimation,
          HeroFontRole.zhModern,
          HeroFontRole.zhKai,
          HeroFontRole.zhSong,
        ],
        _HeroGenre.romance => const [
          HeroFontRole.zhRomance,
          HeroFontRole.zhKai,
          HeroFontRole.zhSong,
          HeroFontRole.zhModern,
        ],
        _HeroGenre.modern => const [
          HeroFontRole.zhModern,
          HeroFontRole.zhSong,
          HeroFontRole.zhKai,
          HeroFontRole.zhRomance,
        ],
        _HeroGenre.drama => const [
          HeroFontRole.zhSong,
          HeroFontRole.zhRomance,
          HeroFontRole.zhKai,
        ],
      },
      _HeroRegion.japan => switch (genre) {
        _HeroGenre.horror => const [
          HeroFontRole.jaCrime,
          HeroFontRole.jaBrushBold,
          HeroFontRole.jaOld,
          HeroFontRole.jaBrushLight,
        ],
        _HeroGenre.wuxia => const [
          HeroFontRole.jaWar,
          HeroFontRole.jaCrime,
          HeroFontRole.jaBrushBold,
          HeroFontRole.jaBrushLight,
        ],
        _HeroGenre.period => const [
          HeroFontRole.jaWar,
          HeroFontRole.jaOld,
          HeroFontRole.jaBrushBold,
          HeroFontRole.jaBrushLight,
          HeroFontRole.jaDrama,
        ],
        _HeroGenre.war => const [
          HeroFontRole.jaWar,
          HeroFontRole.jaBrushBold,
          HeroFontRole.jaOld,
          HeroFontRole.jaDrama,
        ],
        _HeroGenre.crime => const [
          HeroFontRole.jaCrime,
          HeroFontRole.jaOld,
          HeroFontRole.jaBrushBold,
          HeroFontRole.jaBrushLight,
        ],
        _HeroGenre.scifi => const [
          HeroFontRole.jaScifi,
          HeroFontRole.jaDeco,
          HeroFontRole.jaAnimation,
          HeroFontRole.jaPop,
        ],
        _HeroGenre.animation => const [
          HeroFontRole.jaAnimation,
          HeroFontRole.jaPop,
          HeroFontRole.jaCute,
          HeroFontRole.jaDeco,
        ],
        _HeroGenre.fantasy => const [
          HeroFontRole.jaDeco,
          HeroFontRole.jaAnimation,
          HeroFontRole.jaPop,
          HeroFontRole.jaOld,
        ],
        _HeroGenre.western => const [
          HeroFontRole.jaWar,
          HeroFontRole.jaCrime,
          HeroFontRole.jaOld,
          HeroFontRole.jaBrushBold,
        ],
        _HeroGenre.action => const [
          HeroFontRole.jaCrime,
          HeroFontRole.jaBrushBold,
          HeroFontRole.jaWar,
          HeroFontRole.jaAnimation,
        ],
        _HeroGenre.comedy => const [
          HeroFontRole.jaComedy,
          HeroFontRole.jaPop,
          HeroFontRole.jaCute,
          HeroFontRole.jaHand,
        ],
        _HeroGenre.romance => const [
          HeroFontRole.jaDrama,
          HeroFontRole.jaModern,
          HeroFontRole.jaHand,
          HeroFontRole.jaBrushLight,
        ],
        _HeroGenre.modern => const [
          HeroFontRole.jaModern,
          HeroFontRole.jaDrama,
          HeroFontRole.jaHand,
          HeroFontRole.jaOld,
        ],
        _HeroGenre.drama => const [
          HeroFontRole.jaDrama,
          HeroFontRole.jaModern,
          HeroFontRole.jaHand,
          HeroFontRole.jaOld,
          HeroFontRole.jaBrushLight,
        ],
      },
      _HeroRegion.korea => switch (genre) {
        _HeroGenre.horror => const [
          HeroFontRole.koCrime,
          HeroFontRole.koBrush,
          HeroFontRole.koHand,
          HeroFontRole.koSerif,
        ],
        _HeroGenre.wuxia => const [
          HeroFontRole.koBrush,
          HeroFontRole.koSerif,
          HeroFontRole.koCrime,
        ],
        _HeroGenre.period => const [
          HeroFontRole.koBrush,
          HeroFontRole.koSerif,
          HeroFontRole.koDrama,
        ],
        _HeroGenre.war => const [
          HeroFontRole.koCrime,
          HeroFontRole.koBrush,
          HeroFontRole.koSerif,
        ],
        _HeroGenre.crime => const [
          HeroFontRole.koCrime,
          HeroFontRole.koHand,
          HeroFontRole.koSerif,
          HeroFontRole.koBrush,
        ],
        _HeroGenre.scifi => const [
          HeroFontRole.koCrime,
          HeroFontRole.koSerif,
          HeroFontRole.koComedy,
        ],
        _HeroGenre.animation => const [
          HeroFontRole.koCute,
          HeroFontRole.koComedy,
          HeroFontRole.koPen,
          HeroFontRole.koHand,
        ],
        _HeroGenre.fantasy => const [
          HeroFontRole.koCrime,
          HeroFontRole.koBrush,
          HeroFontRole.koSerif,
          HeroFontRole.koDrama,
        ],
        _HeroGenre.western => const [
          HeroFontRole.koCrime,
          HeroFontRole.koBrush,
          HeroFontRole.koHand,
        ],
        _HeroGenre.action => const [
          HeroFontRole.koCrime,
          HeroFontRole.koHand,
          HeroFontRole.koBrush,
        ],
        _HeroGenre.comedy => const [
          HeroFontRole.koComedy,
          HeroFontRole.koCute,
          HeroFontRole.koPen,
          HeroFontRole.koHand,
        ],
        _HeroGenre.romance => const [
          HeroFontRole.koDrama,
          HeroFontRole.koSerif,
          HeroFontRole.koPen,
          HeroFontRole.koBrush,
        ],
        _HeroGenre.modern => const [
          HeroFontRole.koDrama,
          HeroFontRole.koSerif,
          HeroFontRole.koPen,
          HeroFontRole.koCrime,
        ],
        _HeroGenre.drama => const [
          HeroFontRole.koDrama,
          HeroFontRole.koSerif,
          HeroFontRole.koPen,
          HeroFontRole.koBrush,
          HeroFontRole.koHand,
        ],
      },
      _HeroRegion.latin => switch (genre) {
        _HeroGenre.horror => const [
          HeroFontRole.latinHorror,
          HeroFontRole.latinGothic,
          HeroFontRole.latinType,
          HeroFontRole.latinEpic,
        ],
        _HeroGenre.wuxia => const [
          HeroFontRole.latinEpic,
          HeroFontRole.latinGothic,
          HeroFontRole.latinSlab,
          HeroFontRole.latinWestern,
        ],
        _HeroGenre.period => const [
          HeroFontRole.latinEpic,
          HeroFontRole.latinFat,
          HeroFontRole.latinGothic,
          HeroFontRole.latinWestern,
        ],
        _HeroGenre.war => const [
          HeroFontRole.latinPoster,
          HeroFontRole.latinAction,
          HeroFontRole.latinSlab,
          HeroFontRole.latinType,
        ],
        _HeroGenre.crime => const [
          HeroFontRole.latinAction,
          HeroFontRole.latinType,
          HeroFontRole.latinPoster,
          HeroFontRole.latinGothic,
        ],
        _HeroGenre.scifi => const [
          HeroFontRole.latinScifi,
          HeroFontRole.latinRetro,
          HeroFontRole.latinDeco,
          HeroFontRole.latinPoster,
        ],
        _HeroGenre.animation => const [
          HeroFontRole.latinComedy,
          HeroFontRole.latinSlab,
          HeroFontRole.latinFat,
          HeroFontRole.latinDeco,
        ],
        _HeroGenre.fantasy => const [
          HeroFontRole.latinEpic,
          HeroFontRole.latinGothic,
          HeroFontRole.latinDeco,
          HeroFontRole.latinFat,
        ],
        _HeroGenre.western => const [
          HeroFontRole.latinWestern,
          HeroFontRole.latinType,
          HeroFontRole.latinSlab,
          HeroFontRole.latinPoster,
        ],
        _HeroGenre.action => const [
          HeroFontRole.latinAction,
          HeroFontRole.latinPoster,
          HeroFontRole.latinSlab,
          HeroFontRole.latinType,
        ],
        _HeroGenre.comedy => const [
          HeroFontRole.latinComedy,
          HeroFontRole.latinSlab,
          HeroFontRole.latinFat,
          HeroFontRole.latinDeco,
        ],
        _HeroGenre.romance => const [
          HeroFontRole.latinRomance,
          HeroFontRole.latinFat,
          HeroFontRole.latinDeco,
          HeroFontRole.latinEpic,
        ],
        _HeroGenre.modern => const [
          HeroFontRole.latinDeco,
          HeroFontRole.latinType,
          HeroFontRole.latinRomance,
          HeroFontRole.latinPoster,
        ],
        _HeroGenre.drama => const [
          HeroFontRole.latinRomance,
          HeroFontRole.latinDeco,
          HeroFontRole.latinFat,
          HeroFontRole.latinEpic,
          HeroFontRole.latinType,
        ],
      },
    };

/// 豆瓣没命中（完全不知道类型）时的中性候选：只排除过于卡通 / 恐怖的字体。
List<HeroFontRole> _neutralOf(_HeroRegion region) => switch (region) {
  _HeroRegion.china => const [
    HeroFontRole.zhSong,
    HeroFontRole.zhRomance,
    HeroFontRole.zhKai,
    HeroFontRole.zhModern,
    HeroFontRole.zhWar,
  ],
  _HeroRegion.japan => const [
    HeroFontRole.jaDrama,
    HeroFontRole.jaModern,
    HeroFontRole.jaHand,
    HeroFontRole.jaOld,
    HeroFontRole.jaCrime,
    HeroFontRole.jaComedy,
  ],
  _HeroRegion.korea => const [
    HeroFontRole.koDrama,
    HeroFontRole.koSerif,
    HeroFontRole.koPen,
    HeroFontRole.koBrush,
    HeroFontRole.koHand,
    HeroFontRole.koComedy,
  ],
  _HeroRegion.latin => const [
    HeroFontRole.latinRomance,
    HeroFontRole.latinFat,
    HeroFontRole.latinEpic,
    HeroFontRole.latinDeco,
    HeroFontRole.latinAction,
    HeroFontRole.latinPoster,
    HeroFontRole.latinType,
  ],
};

HeroTitleShape _shapeOf(_HeroGenre genre) => switch (genre) {
  _HeroGenre.horror => HeroTitleShape.torn,
  _HeroGenre.crime || _HeroGenre.action => HeroTitleShape.slanted,
  _HeroGenre.wuxia => HeroTitleShape.slanted,
  _HeroGenre.war => HeroTitleShape.notched,
  _HeroGenre.animation || _HeroGenre.comedy => HeroTitleShape.notched,
  _HeroGenre.modern => HeroTitleShape.notched,
  _HeroGenre.scifi || _HeroGenre.western => HeroTitleShape.slanted,
  _HeroGenre.fantasy => HeroTitleShape.torn,
  _ => HeroTitleShape.band,
};

/// 只保留极轻的旋转做海报感；不再横向斜切，避免正文变形难读。
(double, double) _tiltOf(_HeroGenre genre) => switch (genre) {
  _HeroGenre.horror => (-0.008, 0),
  _HeroGenre.wuxia => (-0.006, 0),
  _HeroGenre.crime || _HeroGenre.action => (-0.005, 0),
  _HeroGenre.western => (-0.004, 0),
  _ => (0, 0),
};

/// 长标题拆成上下两行；拉丁标题只在有空格时拆，避免把单词截断。
List<String> _titleLines(String text) {
  final runes = text.runes.toList();
  // 按文字本身决定断行策略：欧美片的豆瓣标题仍是中文（如《哈利·波特…》）。
  final cjk = _hasCjk(text) || _hasKana(text) || _hasHangul(text);
  final limit = cjk ? 8 : 16;
  if (runes.length <= limit) return [text];

  if (!cjk) {
    final words = text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length < 2) return [text];
    var best = 1;
    var bestDiff = 1 << 30;
    for (var i = 1; i < words.length; i++) {
      final left = words.sublist(0, i).join(' ').length;
      final right = words.sublist(i).join(' ').length;
      final diff = (left - right).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return [words.sublist(0, best).join(' '), words.sublist(best).join(' ')];
  }

  final mid = runes.length / 2;
  var cut = -1;
  var bestDist = 1e9;
  const separators = {
    '：',
    ':',
    '·',
    '・',
    '，',
    ',',
    '、',
    '；',
    ';',
    '—',
    '–',
    '-',
    '/',
    '／',
    '|',
    '｜',
    ' ',
  };
  for (var i = 1; i < runes.length - 1; i++) {
    final ch = String.fromCharCodes([runes[i]]);
    if (separators.contains(ch)) {
      final dist = (i - mid).abs();
      if (dist < bestDist) {
        bestDist = dist;
        cut = i;
      }
    }
  }
  if (cut < 0) cut = mid.round();
  var first = String.fromCharCodes(runes.sublist(0, cut)).trim();
  var second = String.fromCharCodes(runes.sublist(cut)).trim();
  first = first.replaceAll(RegExp(r'[：:·・，,、；;—–\-\s]+$'), '');
  second = second.replaceAll(RegExp(r'^[：:·・，,、；;—–\-\s]+'), '');
  if (first.isEmpty || second.isEmpty) return [text];
  return [first, second];
}

/// 同地区兜底顺序：优先中性 / 通用风格。
const _fallbacks = <_HeroRegion, List<HeroFontRole>>{
  _HeroRegion.china: [
    HeroFontRole.zhSong,
    HeroFontRole.zhRomance,
    HeroFontRole.zhKai,
    HeroFontRole.zhModern,
    HeroFontRole.zhJianghu,
    HeroFontRole.zhBrush,
    HeroFontRole.zhWar,
    HeroFontRole.zhAnimation,
    HeroFontRole.zhCrime,
    HeroFontRole.zhHorror,
    HeroFontRole.zhPen,
  ],
  _HeroRegion.japan: [
    HeroFontRole.jaDrama,
    HeroFontRole.jaModern,
    HeroFontRole.jaHand,
    HeroFontRole.jaCrime,
    HeroFontRole.jaWar,
    HeroFontRole.jaOld,
    HeroFontRole.jaAnimation,
    HeroFontRole.jaPop,
    HeroFontRole.jaCute,
    HeroFontRole.jaComedy,
    HeroFontRole.jaScifi,
    HeroFontRole.jaDeco,
    HeroFontRole.jaBrushBold,
    HeroFontRole.jaBrushLight,
  ],
  _HeroRegion.korea: [
    HeroFontRole.koDrama,
    HeroFontRole.koSerif,
    HeroFontRole.koPen,
    HeroFontRole.koBrush,
    HeroFontRole.koCrime,
    HeroFontRole.koComedy,
    HeroFontRole.koCute,
    HeroFontRole.koHand,
  ],
  _HeroRegion.latin: [
    HeroFontRole.latinRomance,
    HeroFontRole.latinFat,
    HeroFontRole.latinEpic,
    HeroFontRole.latinAction,
    HeroFontRole.latinPoster,
    HeroFontRole.latinSlab,
    HeroFontRole.latinScifi,
    HeroFontRole.latinRetro,
    HeroFontRole.latinDeco,
    HeroFontRole.latinComedy,
    HeroFontRole.latinType,
    HeroFontRole.latinGothic,
    HeroFontRole.latinHorror,
    HeroFontRole.latinWestern,
  ],
};

class _HeroPalette {
  const _HeroPalette({
    required this.top,
    required this.bottom,
    required this.accent,
    required this.plate,
  });

  final Color top;
  final Color bottom;
  final Color accent;
  final Color plate;
}

/// 电影感配色：标题本体接近白色，只在底部带一点很淡的类型色；
/// 饱和色只出现在小面积的强调线 / 光晕 / 印章上，避免整块金色渐变。
const _genrePalettes = <_HeroGenre, _HeroPalette>{
  _HeroGenre.horror: _HeroPalette(
    top: Color(0xFFFDFBFB),
    bottom: Color(0xFFE7C9C9),
    accent: Color(0xFFB23A3A),
    plate: Color(0xFF0B0505),
  ),
  _HeroGenre.period: _HeroPalette(
    top: Color(0xFFFFFDF8),
    bottom: Color(0xFFEADCC6),
    accent: Color(0xFFB06A3C),
    plate: Color(0xFF0D0905),
  ),
  _HeroGenre.wuxia: _HeroPalette(
    top: Color(0xFFFFFCF5),
    bottom: Color(0xFFF2DDC0),
    accent: Color(0xFFB03A2E),
    plate: Color(0xFF0C0604),
  ),
  _HeroGenre.war: _HeroPalette(
    top: Color(0xFFF8F9F5),
    bottom: Color(0xFFDCE0D0),
    accent: Color(0xFF7C8A6A),
    plate: Color(0xFF090B08),
  ),
  _HeroGenre.crime: _HeroPalette(
    top: Color(0xFFF6FAFF),
    bottom: Color(0xFFD3E1F2),
    accent: Color(0xFF5C87B8),
    plate: Color(0xFF05080D),
  ),
  _HeroGenre.scifi: _HeroPalette(
    top: Color(0xFFF5FDFF),
    bottom: Color(0xFFC9EEF2),
    accent: Color(0xFF2FA8B8),
    plate: Color(0xFF03090B),
  ),
  _HeroGenre.animation: _HeroPalette(
    top: Color(0xFFFFFCF4),
    bottom: Color(0xFFF8E3B8),
    accent: Color(0xFFD19A3C),
    plate: Color(0xFF0D0800),
  ),
  _HeroGenre.fantasy: _HeroPalette(
    top: Color(0xFFFBF8FF),
    bottom: Color(0xFFE3D4F5),
    accent: Color(0xFF8A6BB0),
    plate: Color(0xFF08040D),
  ),
  _HeroGenre.western: _HeroPalette(
    top: Color(0xFFFFFAF2),
    bottom: Color(0xFFEAD8BE),
    accent: Color(0xFFB07A4A),
    plate: Color(0xFF0C0703),
  ),
  _HeroGenre.action: _HeroPalette(
    top: Color(0xFFFFF9F4),
    bottom: Color(0xFFF5D7BE),
    accent: Color(0xFFC96A2B),
    plate: Color(0xFF0D0500),
  ),
  _HeroGenre.comedy: _HeroPalette(
    top: Color(0xFFFFFCF3),
    bottom: Color(0xFFF7E4B8),
    accent: Color(0xFFC98F2E),
    plate: Color(0xFF0D0800),
  ),
  _HeroGenre.romance: _HeroPalette(
    top: Color(0xFFFFF8FA),
    bottom: Color(0xFFF5D8DF),
    accent: Color(0xFFC97B8A),
    plate: Color(0xFF0D0508),
  ),
  _HeroGenre.modern: _HeroPalette(
    top: Color(0xFFF7FCFC),
    bottom: Color(0xFFD4EAE6),
    accent: Color(0xFF3F9A8C),
    plate: Color(0xFF040A08),
  ),
  _HeroGenre.drama: _HeroPalette(
    top: Color(0xFFFFFDF9),
    bottom: Color(0xFFEDE6DA),
    accent: Color(0xFFB7A78C),
    plate: Color(0xFF090806),
  ),
};

_HeroPalette _paletteOf(_HeroRegion region, _HeroGenre genre, Color? tint) {
  final base = switch (region) {
    // 和风朱色 / 韩式青瓷：同类型的中日韩标题也有地区差异。
    _HeroRegion.japan => _HeroPalette(
      top: _genrePalettes[genre]!.top,
      bottom: Color.lerp(
        _genrePalettes[genre]!.bottom,
        const Color(0xFFF2B8B8),
        0.25,
      )!,
      accent: Color.lerp(
        _genrePalettes[genre]!.accent,
        const Color(0xFFD94F4F),
        0.4,
      )!,
      plate: _genrePalettes[genre]!.plate,
    ),
    _HeroRegion.korea => _HeroPalette(
      top: _genrePalettes[genre]!.top,
      bottom: Color.lerp(
        _genrePalettes[genre]!.bottom,
        const Color(0xFFBFEFE4),
        0.25,
      )!,
      accent: Color.lerp(
        _genrePalettes[genre]!.accent,
        const Color(0xFF56C7B0),
        0.4,
      )!,
      plate: _genrePalettes[genre]!.plate,
    ),
    _ => _genrePalettes[genre]!,
  };
  if (tint == null) return base;
  return _blendTint(base, tint);
}

/// 把底图取样的主色混进类型配色：主色主要影响强调色和标题底部的浅色，
/// 标题本体仍保持接近白色，避免整行变成高饱和渐变。
_HeroPalette _blendTint(_HeroPalette base, Color tint) {
  final hsl = HSLColor.fromColor(tint);
  if (hsl.saturation < 0.12) return base;
  final sat = hsl.saturation.clamp(0.30, 0.62);
  final accent = HSLColor.fromAHSL(1, hsl.hue, sat, 0.56).toColor();
  final bottom = HSLColor.fromAHSL(1, hsl.hue, 0.22, 0.84).toColor();
  final top = Color.lerp(
    const Color(0xFFFFFFFF),
    HSLColor.fromAHSL(1, hsl.hue, 0.08, 0.98).toColor(),
    0.4,
  )!;
  final plate = HSLColor.fromAHSL(1, hsl.hue, 0.22, 0.035).toColor();
  return _HeroPalette(
    top: Color.lerp(base.top, top, 0.5)!,
    bottom: Color.lerp(base.bottom, bottom, 0.55)!,
    accent: Color.lerp(base.accent, accent, 0.65)!,
    plate: Color.lerp(base.plate, plate, 0.55)!,
  );
}

/// 片名稳定散列：同一部片每次启动都选同一款字体。
int _stableHash(String value) {
  var hash = 7;
  for (final rune in value.runes) {
    hash = (hash * 31 + rune) & 0x7fffffff;
  }
  return hash;
}

bool _countryHas(List<String> countries, String needle) =>
    countries.any((country) => country.contains(needle));

bool _hasKana(String text) => RegExp(r'[\u3040-\u30ff]').hasMatch(text);

bool _hasHangul(String text) =>
    RegExp(r'[\uac00-\ud7af\u1100-\u11ff\u3130-\u318f]').hasMatch(text);

bool _hasCjk(String text) => RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

bool _isLatin(String text) =>
    RegExp(r'[A-Za-z]').hasMatch(text) &&
    !RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]').hasMatch(text);
