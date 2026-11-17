import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/fonts/hero_fonts.dart';
import 'package:kniephos/ui/immersive/hero_title_style.dart';

void main() {
  group('Hero 标题方案', () {
    test('日本犯罪片用毛笔字体并显示日文原名竖排', () {
      final plan = buildHeroTitlePlan(
        title: '冰冷热带鱼',
        originalTitle: '冷たい熱帯魚',
        genres: const ['剧情', '惊悚', '犯罪'],
        countries: const ['日本'],
        familyOf: (role) => role == HeroFontRole.jaCrime ? 'ja-crime' : null,
      );
      expect(plan.family, 'ja-crime');
      expect(plan.main, '冷たい熱帯魚');
      expect(plan.secondary, '冰冷热带鱼');
      expect(plan.vertical, isTrue);
      expect(plan.fontSize, lessThanOrEqualTo(72));
      expect(plan.titleTop, isNot(plan.titleBottom));
    });

    test('没有安装字体时保持中文标题与系统字体', () {
      final plan = buildHeroTitlePlan(
        title: '冰冷热带鱼',
        originalTitle: '冷たい熱帯魚',
        genres: const ['剧情', '惊悚', '犯罪'],
        countries: const ['日本'],
        familyOf: (_) => null,
      );
      expect(plan.family, isNull);
      expect(plan.main, '冰冷热带鱼');
      expect(plan.secondary, isEmpty);
      expect(plan.vertical, isFalse);
    });

    test('同地区字体互为兜底', () {
      final plan = buildHeroTitlePlan(
        title: '某个日本片',
        originalTitle: '何かの日本映画',
        genres: const ['犯罪'],
        countries: const ['日本'],
        familyOf: (role) => role == HeroFontRole.jaDrama ? 'ja-drama' : null,
      );
      expect(plan.family, 'ja-drama');
    });

    test('中国大陆爱情片 / 战争片 / 古装片使用不同字体', () {
      String? romanceRole(HeroFontRole role) =>
          role == HeroFontRole.zhRomance ? 'zh-romance' : null;
      final romance = buildHeroTitlePlan(
        title: '春天的故事',
        genres: const ['剧情', '爱情'],
        countries: const ['中国大陆'],
        familyOf: romanceRole,
      );
      expect(romance.family, 'zh-romance');

      String? warRole(HeroFontRole role) =>
          role == HeroFontRole.zhWar ? 'zh-war' : null;
      final war = buildHeroTitlePlan(
        title: '长津湖',
        genres: const ['战争', '历史'],
        countries: const ['中国大陆'],
        familyOf: warRole,
      );
      expect(war.family, 'zh-war');

      String? periodRole(HeroFontRole role) =>
          role == HeroFontRole.zhBrush ? 'zh-brush' : null;
      final period = buildHeroTitlePlan(
        title: '长安十二时辰',
        genres: const ['剧情', '古装', '历史'],
        countries: const ['中国大陆'],
        familyOf: periodRole,
      );
      expect(period.family, 'zh-brush');
    });

    test('没有豆瓣国家时中文标题仍按中文默认匹配', () {
      final plan = buildHeroTitlePlan(
        title: '无名之辈',
        genres: const ['剧情'],
        familyOf: (role) =>
            role == HeroFontRole.zhRomance ? 'zh-romance' : null,
      );
      expect(plan.family, 'zh-romance');
    });

    test('日本动画与战争使用不同槽位', () {
      final animation = buildHeroTitlePlan(
        title: '你的名字',
        originalTitle: '君の名は。',
        genres: const ['动画', '爱情'],
        countries: const ['日本'],
        familyOf: (role) =>
            role == HeroFontRole.jaAnimation ? 'ja-animation' : null,
      );
      expect(animation.family, 'ja-animation');

      final war = buildHeroTitlePlan(
        title: '永远的零',
        originalTitle: '永遠の0',
        genres: const ['战争', '历史'],
        countries: const ['日本'],
        familyOf: (role) => role == HeroFontRole.jaWar ? 'ja-war' : null,
      );
      expect(war.family, 'ja-war');
    });

    test('韩国爱情片使用韩式明朝', () {
      final plan = buildHeroTitlePlan(
        title: '我的野蛮女友',
        originalTitle: '엽기적인 그녀',
        genres: const ['爱情', '喜剧'],
        countries: const ['韩国'],
        familyOf: (role) => role == HeroFontRole.koDrama ? 'ko-drama' : null,
      );
      expect(plan.family, 'ko-drama');
      expect(plan.main, '엽기적인 그녀');
      expect(plan.secondary, '我的野蛮女友');
    });

    test('欧美动作片显示英文原名，长标题自动缩小', () {
      final shortPlan = buildHeroTitlePlan(
        title: '亡命驾驶',
        originalTitle: 'Drive',
        genres: const ['动作', '犯罪'],
        countries: const ['美国'],
        familyOf: (role) => role == HeroFontRole.latinAction ? 'latin' : null,
      );
      expect(shortPlan.family, 'latin');
      expect(shortPlan.main, 'Drive');
      expect(shortPlan.secondary, '亡命驾驶');

      final longPlan = buildHeroTitlePlan(
        title: '非常长的电影标题',
        originalTitle: 'The Extraordinarily Long Title of Something',
        genres: const ['动作'],
        countries: const ['美国'],
        familyOf: (role) => role == HeroFontRole.latinAction ? 'latin' : null,
      );
      expect(longPlan.fontSize, lessThan(shortPlan.fontSize));
    });

    test('欧美科幻 / 爱情 / 恐怖命中各自字体', () {
      final scifi = buildHeroTitlePlan(
        title: '星际穿越',
        originalTitle: 'Interstellar',
        genres: const ['科幻', '冒险'],
        countries: const ['美国'],
        familyOf: (role) =>
            role == HeroFontRole.latinScifi ? 'latin-scifi' : null,
      );
      expect(scifi.family, 'latin-scifi');

      final romance = buildHeroTitlePlan(
        title: '爱在黎明破晓前',
        originalTitle: 'Before Sunrise',
        genres: const ['爱情', '剧情'],
        countries: const ['美国'],
        familyOf: (role) =>
            role == HeroFontRole.latinRomance ? 'latin-romance' : null,
      );
      expect(romance.family, 'latin-romance');

      final horror = buildHeroTitlePlan(
        title: '闪灵',
        originalTitle: 'The Shining',
        genres: const ['恐怖', '惊悚'],
        countries: const ['美国'],
        familyOf: (role) =>
            role == HeroFontRole.latinHorror ? 'latin-horror' : null,
      );
      expect(horror.family, 'latin-horror');
    });

    test('长标题拆成上下两行', () {
      final plan = buildHeroTitlePlan(
        title: '这是一个非常非常长的中文电影标题',
        genres: const ['剧情'],
        countries: const ['中国大陆'],
        familyOf: (role) =>
            role == HeroFontRole.zhRomance ? 'zh-romance' : null,
      );
      expect(plan.lines.length, 2);
      expect(plan.stacked, isTrue);
      expect(plan.maxLines, 2);
    });

    test('长标题优先在有标点的位置断行', () {
      final plan = buildHeroTitlePlan(
        title: '哈利·波特与死亡圣器',
        genres: const ['奇幻', '冒险'],
        countries: const ['美国'],
        familyOf: (role) =>
            role == HeroFontRole.latinRomance ? 'latin-romance' : null,
      );
      expect(plan.lines, ['哈利', '波特与死亡圣器']);
    });

    test('源站 type / area 可作为豆瓣缺失时的兜底', () {
      final plan = buildHeroTitlePlan(
        title: '长津湖',
        genres: splitMetaHints('战争片,历史片'),
        countries: splitMetaHints('中国大陆'),
        familyOf: (role) => role == HeroFontRole.zhWar ? 'zh-war' : null,
      );
      expect(plan.family, 'zh-war');
    });

    test('顶部副标题优先使用类型与国家', () {
      expect(
        heroTagline(
          genres: const ['剧情', '惊悚', '犯罪', '多出来的'],
          countries: const ['日本', '美国'],
          fallback: '豆瓣 · 电影',
        ),
        '剧情 / 惊悚 / 犯罪 · 日本',
      );
      expect(
        heroTagline(genres: const [], countries: const [], fallback: 'douban'),
        'DOUBAN',
      );
    });

    test('同类型不同片名会分散到不同字体', () {
      String? familyOf(HeroFontRole role) => switch (role) {
        HeroFontRole.zhSong => 'zh-song',
        HeroFontRole.zhRomance => 'zh-romance',
        HeroFontRole.zhKai => 'zh-kai',
        HeroFontRole.zhModern => 'zh-modern',
        _ => null,
      };
      final first = buildHeroTitlePlan(
        title: '长安十二时辰',
        genres: const ['剧情'],
        countries: const ['中国大陆'],
        familyOf: familyOf,
      );
      final second = buildHeroTitlePlan(
        title: '兰香如故',
        genres: const ['剧情'],
        countries: const ['中国大陆'],
        familyOf: familyOf,
      );
      expect(first.family, 'zh-kai');
      expect(second.family, 'zh-romance');
    });

    test('没有类型元数据时也按片名分散字体', () {
      String? familyOf(HeroFontRole role) => switch (role) {
        HeroFontRole.zhRomance => 'zh-romance',
        HeroFontRole.zhKai => 'zh-kai',
        _ => null,
      };
      final first = buildHeroTitlePlan(
        title: '长安十二时辰',
        countries: const ['中国大陆'],
        familyOf: familyOf,
      );
      final second = buildHeroTitlePlan(
        title: '兰香如故',
        countries: const ['中国大陆'],
        familyOf: familyOf,
      );
      expect(first.family, 'zh-romance');
      expect(second.family, 'zh-kai');
    });

    test('不同题材使用不同标题配色', () {
      final horror = buildHeroTitlePlan(
        title: '闪灵',
        genres: const ['恐怖'],
        countries: const ['美国'],
        familyOf: (_) => null,
      );
      final romance = buildHeroTitlePlan(
        title: '爱在黎明破晓前',
        genres: const ['爱情'],
        countries: const ['美国'],
        familyOf: (_) => null,
      );
      expect(horror.titleBottom, isNot(romance.titleBottom));
      expect(horror.accent, isNot(romance.accent));
      expect(horror.titleTop, isNot(romance.titleTop));
    });

    test('四字中文标题使用大字号', () {
      final plan = buildHeroTitlePlan(
        title: '兰香如故',
        genres: const ['剧情'],
        countries: const ['中国大陆'],
        familyOf: (_) => null,
      );
      expect(plan.fontSize, greaterThanOrEqualTo(100));
      expect(plan.stacked, isFalse);
    });

    test('每个字体槽位都有唯一字体包', () {
      final roles = heroFontPacks.map((pack) => pack.role).toList();
      expect(roles.toSet().length, roles.length);
      expect(roles.length, HeroFontRole.values.length);
    });

    test('古装武侠用江湖毛笔，现代都市用现代黑体', () {
      String? familyOf(HeroFontRole role) => switch (role) {
        HeroFontRole.zhJianghu => 'zh-jianghu',
        HeroFontRole.zhModern => 'zh-modern',
        _ => null,
      };
      final wuxia = buildHeroTitlePlan(
        title: '沧海一声笑',
        genres: const ['武侠'],
        countries: const ['中国香港'],
        familyOf: familyOf,
      );
      final modern = buildHeroTitlePlan(
        title: '都市夜归人',
        genres: const ['都市', '职场'],
        countries: const ['中国大陆'],
        familyOf: familyOf,
      );
      expect(wuxia.family, 'zh-jianghu');
      expect(modern.family, 'zh-modern');
      expect(wuxia.shape, isNot(modern.shape));
    });

    test('底图主色会改变标题配色', () {
      final base = buildHeroTitlePlan(
        title: '无上神帝',
        genres: const ['动画'],
        countries: const ['中国大陆'],
        familyOf: (_) => null,
      );
      final tinted = buildHeroTitlePlan(
        title: '无上神帝',
        genres: const ['动画'],
        countries: const ['中国大陆'],
        familyOf: (_) => null,
        tint: const Color(0xFF33AA88),
      );
      expect(tinted.accent, isNot(base.accent));
      expect(tinted.titleBottom, isNot(base.titleBottom));
    });
  });
}
