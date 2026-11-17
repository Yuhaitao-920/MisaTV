import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/discover/discover_models.dart';
import 'package:kniephos/services/discover/discover_service.dart';

void main() {
  group('buildExploreUrl', () {
    test('跳过「全部」，编码 tag，带排序与分页', () {
      final url = buildExploreUrl(
        'movie',
        const ExploreQuery(
          mediaType: 'movie',
          tags: ['全部', '喜剧', '中国大陆'],
          sort: 'U',
          start: 20,
          count: 20,
        ),
      );
      expect(
        url,
        startsWith('https://m.douban.com/rexxar/api/v2/movie/recommend?'),
      );
      expect(url, contains('start=20'));
      expect(url, contains('count=20'));
      expect(url, contains('sort=U'));
      expect(
        url,
        contains(
          'tags=%E5%96%9C%E5%89%A7%2C%E4%B8%AD%E5%9B%BD%E5%A4%A7%E9%99%86',
        ),
      );
      expect(url, isNot(contains('全部')));
    });

    test('count / start 有上下限', () {
      final url = buildExploreUrl(
        'tv',
        const ExploreQuery(mediaType: 'tv', count: 999, start: 9999),
      );
      expect(url, contains('count=50'));
      expect(url, contains('start=500'));
    });
  });

  group('年份', () {
    test('从卡片副标题取年份', () {
      expect(yearFromCardSubtitle('2018 / 文牧野 徐峥'), 2018);
      expect(yearFromCardSubtitle('2018-05-01 / 中国大陆'), 2018);
      expect(yearFromCardSubtitle('暂无'), isNull);
    });

    test('年代 tag 区间', () {
      expect(yearTagRange('全部'), isNull);
      expect(yearTagRange('2024'), (from: 2024, to: 2024));
      expect(yearTagRange('2010年代'), (from: 2010, to: 2019));
      expect(yearTagRange('90年代'), (from: 1990, to: 1999));
      expect(yearTagRange('30年代'), (from: 1930, to: 1939));
      expect(yearTagRange('更早'), (from: 0, to: 1979));
    });

    test('年代选项包含今年与更早', () {
      final values = discoverYearValues(2026);
      expect(values.first, allTag);
      expect(values, contains('2026'));
      expect(values, contains('2010年代'));
      expect(values.last, '更早');
    });
  });

  group('parseDoubanExploreItems', () {
    test('丢弃榜单条目与无封面条目，按 id 去重', () {
      final items = parseDoubanExploreItems({
        'items': [
          {
            'id': '1',
            'title': '流浪地球',
            'type': 'movie',
            'card_subtitle': '2019 / 郭帆 吴京',
            'pic': {'large': 'https://img1.doubanio.com/a.jpg'},
          },
          {
            'id': '2',
            'title': '高分喜剧榜',
            'type': 'chart',
            'pic': {'large': 'https://x/a.jpg'},
          },
          {
            'id': '3',
            'title': '没有封面',
            'type': 'movie',
            'card_subtitle': '2021',
          },
          {
            'id': '1',
            'title': '重复',
            'type': 'movie',
            'pic': {'large': 'https://img1.doubanio.com/a.jpg'},
          },
        ],
      }, 'movie');
      expect(items.length, 1);
      expect(items.first.title, '流浪地球');
      expect(items.first.year, 2019);
      expect(items.first.doubanId, '1');
    });
  });

  group('parseDoubanCollectionItems', () {
    test('兼容 subject_collection_items 与 cover.url', () {
      final items = parseDoubanCollectionItems({
        'subject_collection_items': [
          {
            'id': 42,
            'title': '漫长的季节',
            'type': 'tv',
            'year': '2023',
            'cover': {'url': 'https://img9.doubanio.com/b.jpg'},
          },
          {
            'id': 43,
            'title': '不是剧集',
            'type': 'movie',
            'cover': {'url': 'https://img9.doubanio.com/c.jpg'},
          },
        ],
      }, 'tv');
      expect(items.length, 1);
      expect(items.first.year, 2023);
      expect(items.first.poster, 'https://img9.doubanio.com/b.jpg');
    });
  });

  group('pickDoubanSubject', () {
    const rows = [
      {
        'id': 35588177,
        'title': '漫长的季节',
        'type': 'tv',
        'year': '2023',
        'img': 'https://img/a.jpg',
      },
      {
        'id': 35590000,
        'title': '漫长的季节',
        'type': 'movie',
        'year': '2016',
        'img': 'https://img/b.jpg',
      },
      {'id': 'short', 'title': '漫长的季节', 'type': 'movie', 'year': '2023'},
      {'id': 99999999, 'title': '别的片', 'type': 'movie', 'year': '2023'},
    ];

    test('同名 + 同年优先', () {
      final subject = pickDoubanSubject(rows, '漫长的季节', '2023');
      expect(subject?.id, '35588177');
      expect(subject?.mediaType, 'tv');
    });

    test('没有同年时退回同名，忽略标点差异', () {
      final subject = pickDoubanSubject(rows, '漫长 的 季节', '2024');
      expect(subject?.id, '35588177');
    });

    test('最后一级允许互含（源片名带副标题）', () {
      final subject = pickDoubanSubject(rows, '漫长的季节 第一季', '');
      expect(subject?.id, '35588177');
    });

    test('非 movie/tv 或短 id 不参与匹配', () {
      expect(pickDoubanSubject(rows, '不存在的片', ''), isNull);
    });

    test('同名多季按年份取最接近的一季', () {
      const seasons = [
        {'id': 11111111, 'title': '庆余年', 'type': 'tv', 'year': '2024'},
        {'id': 22222222, 'title': '庆余年', 'type': 'tv', 'year': '2019'},
        {'id': 33333333, 'title': '庆余年 第二季', 'type': 'tv', 'year': '2024'},
      ];
      expect(pickDoubanSubject(seasons, '庆余年', '2019')?.id, '22222222');
      // 年份都对不上时取最接近的那一个（2024 而不是 2019）。
      expect(pickDoubanSubject(seasons, '庆余年', '2023')?.id, '11111111');
      // 只有续作、且年份对不上时宁可不给封面，也不能拿第二季顶第一季。
      expect(
        pickDoubanSubject(
          const [
            {'id': 33333333, 'title': '庆余年 第二季', 'type': 'tv', 'year': '2024'},
          ],
          '庆余年',
          '2019',
        ),
        isNull,
      );
    });

    test('最后一级匹配要求长度接近，避免续作串片', () {
      const rows = [
        {'id': 44444444, 'title': '流浪地球2', 'type': 'movie', 'year': '2023'},
      ];
      // 年份对不上：不能把第二部当成第一部。
      expect(pickDoubanSubject(rows, '流浪地球', '2019'), isNull);
      // 年份缺失时保留原有的宽松匹配能力。
      expect(pickDoubanSubject(rows, '流浪地球', '')?.id, '44444444');
    });

    test('subject_suggest 用 episode 字段识别剧集', () {
      final subject = pickDoubanSubject(
        const [
          {
            'id': 35588177,
            'title': '漫长的季节',
            'type': 'movie',
            'episode': '12',
            'year': '2023',
            'img':
                'https://img9.doubanio.com/view/photo/s_ratio_poster/'
                'public/p2890906384.jpg',
          },
        ],
        '漫长的季节',
        '2023',
      );
      expect(subject?.mediaType, 'tv');
      // 顺带把海报缩略图换成大图。
      expect(
        subject?.img,
        'https://img3.doubanio.com/view/photo/l/public/p2890906384.jpg',
      );
    });

    test('季号后缀参与匹配时被剥掉', () {
      const rows = [
        {'id': 11111111, 'title': '庆余年 第一季', 'type': 'tv', 'year': '2019'},
        {'id': 22222222, 'title': '庆余年 第二季', 'type': 'tv', 'year': '2024'},
      ];
      expect(pickDoubanSubject(rows, '庆余年', '2019')?.id, '11111111');
      expect(pickDoubanSubject(rows, '庆余年', '2024')?.id, '22222222');
    });

    test('官方片名带前缀时同年仍可命中', () {
      const rows = [
        {'id': 4922787, 'title': '后宫·甄嬛传', 'type': 'tv', 'year': '2011'},
      ];
      expect(pickDoubanSubject(rows, '甄嬛传', '2011')?.id, '4922787');
    });
  });

  group('parseDoubanSearchHtml', () {
    test('解析 window.__DATA__ 的条目 / 类型 / 年份 / 大图', () {
      const html = '''
<!DOCTYPE html><html><body>
<script>
window.__DATA__ = {"count": 2, "items": [
  {"id": 35588177, "title": "漫长的季节\\u200e (2023)",
   "cover_url": "https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2890906384.jpg",
   "labels": [{"text": "剧集"}],
   "more_url": "onclick=\\"moreurl(this,{from:'mv_subject_search',subject_id:'35588177',is_tv:'1'})\\"",
   "url": "https://movie.douban.com/subject/35588177/"},
  {"id": 26266893, "title": "流浪地球 (2019)",
   "cover_url": "https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2542069917.jpg",
   "labels": [],
   "url": "https://movie.douban.com/subject/26266893/"}
]};
</script></body></html>
''';
      final rows = parseDoubanSearchHtml(html);
      expect(rows.length, 2);
      expect(rows.first['id'], '35588177');
      expect(rows.first['type'], 'tv');
      expect(rows.first['title'], '漫长的季节');
      expect(rows.first['year'], '2023');
      expect(
        rows.first['img'],
        'https://img3.doubanio.com/view/photo/l/public/p2890906384.jpg',
      );
      expect(rows.last['type'], 'movie');
      expect(rows.last['year'], '2019');
    });

    test('没有 __DATA__ / JSON 残缺时返回空', () {
      expect(parseDoubanSearchHtml('<html></html>'), isEmpty);
      expect(parseDoubanSearchHtml('window.__DATA__ = {"items": ['), isEmpty);
    });

    test('中文名 + 外文原名可只用前半段匹配', () {
      const rows = [
        {
          'id': 30327897,
          'title': '漫长的离别 長いお別れ',
          'type': 'movie',
          'year': '2019',
        },
      ];
      expect(pickDoubanSubject(rows, '漫长的离别', '2019')?.id, '30327897');
    });
  });

  group('parseDoubanInfo', () {
    test('封面 / 评分 / 类型 / 演职员', () {
      final info = parseDoubanInfo({
        'id': '35588177',
        'title': '漫长的季节',
        'year': '2023',
        'intro': '  一段  漫长的  季节。 ',
        'rating': {'value': 9.4},
        'pic': {'large': 'https://img9.doubanio.com/p.jpg'},
        'genres': ['剧情', '家庭'],
        'directors': [
          {'name': '辛爽'},
        ],
        'actors': [
          {'name': '范伟'},
          {'name': '范伟'},
          {'name': '秦昊'},
        ],
      }, 'tv');
      expect(info?.title, '漫长的季节');
      expect(info?.rating, 9.4);
      expect(info?.intro, '一段 漫长的 季节。');
      expect(info?.cover, 'https://img9.doubanio.com/p.jpg');
      expect(info?.genres, ['剧情', '家庭']);
      expect(info?.directors, ['辛爽']);
      expect(info?.actors, ['范伟', '秦昊']);
    });

    test('缺 id / title 返回 null', () {
      expect(parseDoubanInfo({'title': '没有 id'}, 'movie'), isNull);
      expect(parseDoubanInfo({'id': '1'}, 'movie'), isNull);
    });

    test('原名与制片国家用于 Hero 字体匹配', () {
      final info = parseDoubanInfo({
        'id': '1',
        'title': '冰冷热带鱼',
        'original_title': '冷たい熱帯魚',
        'countries': ['日本'],
        'genres': ['剧情', '惊悚', '犯罪'],
      }, 'movie');
      expect(info?.originalTitle, '冷たい熱帯魚');
      expect(info?.countries, ['日本']);
    });
  });

  group('parseDoubanCredits / 演职员头像', () {
    test('解析头像、角色与人物分类', () {
      final credits = parseDoubanCredits({
        'items': [
          {
            'name': '张国荣',
            'avatar': {'large': 'https://img3.doubanio.com/a.jpg'},
            'roles': ['演员', '编剧'],
            'simple_character': '饰 程蝶衣',
            'category': '演员',
          },
          {
            'name': '陈凯歌',
            'avatar': {'normal': 'https://img9.doubanio.com/d.jpg'},
            'roles': ['导演'],
            'category': '导演',
          },
          {'name': '张国荣'},
        ],
      });
      expect(credits.length, 2);
      expect(credits.first.name, '张国荣');
      expect(credits.first.avatar, 'https://img3.doubanio.com/a.jpg');
      expect(credits.first.role, '饰 程蝶衣');
      expect(credits.first.looksLikeActor, isTrue);
      expect(credits.last.avatar, 'https://img9.doubanio.com/d.jpg');
      expect(credits.last.looksLikeActor, isFalse);
    });

    test('celebrities 的 actors 数组解析饰演角色', () {
      final cast = parseDoubanCredits({
        'actors': [
          {
            'name': '孟子义',
            'avatar': {'large': 'https://img3.doubanio.com/m.jpg'},
            'character': '饰 暮晚摇',
            'roles': ['演员'],
          },
          {
            'name': '秦榛',
            'avatar': {'large': 'https://img3.doubanio.com/q.jpg'},
            'character': '导演',
            'roles': ['导演'],
          },
        ],
      });
      expect(cast.length, 2);
      expect(cast.first.role, '饰 暮晚摇');
      expect(cast.first.category, '演员');
      expect(cast.last.looksLikeActor, isFalse);
    });

    test('按演员名单合并：名单顺序优先，且丢弃豆瓣演员表里没有的名字', () {
      final credits = parseDoubanCredits({
        'items': [
          {
            'name': '范伟',
            'avatar': {'large': 'https://img9.doubanio.com/f.jpg'},
            'category': '演员',
          },
          {
            'name': '秦昊',
            'avatar': {'large': 'https://img9.doubanio.com/q.jpg'},
            'category': '演员',
          },
          {
            'name': '辛爽',
            'avatar': {'large': 'https://img9.doubanio.com/x.jpg'},
            'category': '导演',
          },
        ],
      });
      // 王响 是剧中角色名，不应出现在演职员表里。
      final cast = mergeDoubanCast(['秦昊', '范伟', '王响'], credits);
      expect(cast.map((m) => m.name), ['秦昊', '范伟']);
      expect(cast[0].avatar, 'https://img9.doubanio.com/q.jpg');
      expect(cast[1].avatar, 'https://img9.doubanio.com/f.jpg');
    });

    test('豆瓣演员表缺失时保留源名单并过滤职务 / 角色说明', () {
      final cast = mergeDoubanCast([
        '秦昊',
        '导演 张三',
        '编剧 李四',
        '饰 王响',
        '范伟',
      ], const []);
      expect(cast.map((m) => m.name), ['秦昊', '范伟']);
    });

    test('castNameFromToken 从饰演格式提取人名', () {
      expect(castNameFromToken('孟子义(饰暮晚摇)'), '孟子义');
      expect(castNameFromToken('孟子义 饰 暮晚摇'), '孟子义');
      expect(castNameFromToken('主演 李四'), '李四');
      expect(castNameFromToken('饰 王响'), isNull);
      expect(castNameFromToken('导演 张三'), isNull);
    });

    test('详情演员为空时退回 credits 里的演员', () {
      final credits = parseDoubanCredits({
        'items': [
          {
            'name': '辛爽',
            'avatar': {'large': 'https://img9.doubanio.com/x.jpg'},
            'category': '导演',
          },
          {
            'name': '范伟',
            'avatar': {'large': 'https://img9.doubanio.com/f.jpg'},
            'category': '演员',
          },
        ],
      });
      final cast = mergeDoubanCast(const [], credits);
      expect(cast.map((m) => m.name), ['范伟']);
    });

    test('parseDoubanInfo 带 credits 时写入 cast', () {
      final info = parseDoubanInfo(
        {
          'id': '35588177',
          'title': '漫长的季节',
          'actors': [
            {'name': '范伟'},
          ],
        },
        'tv',
        credits: const [
          DoubanCastMember(
            name: '范伟',
            avatar: 'https://img9.doubanio.com/f.jpg',
            category: '演员',
          ),
        ],
      );
      expect(info?.actors, ['范伟']);
      expect(info?.cast.length, 1);
      expect(info?.cast.first.avatar, 'https://img9.doubanio.com/f.jpg');
    });
  });

  group('parseDoubanRecommendations / parseDoubanReviews', () {
    test('裸数组推荐条目保留年份与评分', () {
      final recs = parseDoubanRecommendations([
        {
          'id': '35590000',
          'title': '边水往事',
          'type': 'tv',
          'card_subtitle': '2024 / 中国大陆 / 剧情 冒险',
          'pic': {'large': 'https://img3.doubanio.com/r.jpg'},
          'rating': {'value': 8.4},
        },
        {'id': 'short', 'title': '坏条目'},
      ]);
      expect(recs.length, 1);
      expect(recs.first.year, 2024);
      expect(recs.first.rating, 8.4);
      expect(recs.first.mediaType, 'tv');
      expect(recs.first.poster, 'https://img3.doubanio.com/r.jpg');
    });

    test('影评摘要压成单行', () {
      final reviews = parseDoubanReviews({
        'reviews': [
          {
            'id': '1234567',
            'title': '很长的影评',
            'abstract': '第一段\n\n第二段',
            'rating': {'value': 5},
            'useful_count': 12,
            'user': {'name': '某人'},
            'create_time': '2024-01-01',
          },
        ],
      });
      expect(reviews.length, 1);
      expect(reviews.first.abstract, '第一段 第二段');
      expect(reviews.first.useful, 12);
      expect(reviews.first.author, '某人');
    });

    test('非法输入返回空表', () {
      expect(parseDoubanRecommendations(null), isEmpty);
      expect(parseDoubanReviews('bad'), isEmpty);
    });
  });

  group('parseDoubanVocab', () {
    test('电影取豆瓣类型与地区，排序带默认项', () {
      final vocab = parseDoubanVocab({
        'recommend_categories': [
          {
            'type': '类型',
            'data': [
              {'text': '类型'},
              {'text': '喜剧'},
              {'text': '动作'},
            ],
          },
          {
            'type': '地区',
            'data': [
              {'text': '中国大陆'},
              {'text': '美国'},
            ],
          },
        ],
        'sorts': [
          {'name': 'T', 'text': '综合排序'},
          {'name': 'U', 'text': '近期热度', 'checked': true},
        ],
      }, 'movie');
      expect(vocab.dimensions.first.values, [allTag, '喜剧', '动作']);
      expect(vocab.dimensions[1].values, [allTag, '中国大陆', '美国']);
      expect(vocab.dimensions[2].key, '年代');
      expect(vocab.sorts.length, 2);
      expect(vocab.defaultSort, 'U');
    });

    test('剧集忽略豆瓣一级类型，使用细分类型', () {
      final vocab = parseDoubanVocab({
        'recommend_categories': [
          {
            'type': '类型',
            'data': [
              {'text': '电视剧'},
              {'text': '综艺'},
            ],
          },
        ],
      }, 'tv');
      expect(vocab.dimensions.first.values, contains('美剧'));
      expect(vocab.dimensions.first.values, isNot(contains('电视剧')));
      expect(vocab.sorts, isNotEmpty);
      expect(vocab.defaultSort, 'T');
    });
  });
}
