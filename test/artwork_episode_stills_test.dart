import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/models/user_data.dart';
import 'package:kniephos/services/artwork/artwork_service.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('季号与集号解析', () {
    test('中文季号 / 英文季号 / Sxx', () {
      expect(ArtworkService.seasonHintOf('进击的巨人 第二季'), 2);
      expect(ArtworkService.seasonHintOf('进击的巨人 第12季'), 12);
      expect(ArtworkService.seasonHintOf('Some Show Season 3'), 3);
      expect(ArtworkService.seasonHintOf('Show S02'), 2);
      expect(ArtworkService.seasonHintOf('无季号'), isNull);
    });

    test('站点剧集名提取集号', () {
      expect(ArtworkService.episodeNumber('第3集'), 3);
      expect(ArtworkService.episodeNumber('第12话'), 12);
      expect(ArtworkService.episodeNumber('EP03'), 3);
      expect(ArtworkService.episodeNumber('03'), 3);
      expect(ArtworkService.episodeNumber('正片'), -1);
      expect(ArtworkService.episodeNumber('The.Covenant.2006.1080p.x264'), -1);
      expect(
        ArtworkService.episodeNumber('[2.04GB] The.Covenant.2006.108...'),
        -1,
      );
    });

    test('片名归一与候选', () {
      expect(
        ArtworkService.cleanMetadataTitle(
          '[2.04GB] The.Covenant.2006.1080p.BluRay',
        ),
        'The Covenant',
      );
      expect(ArtworkService.cleanMetadataTitle('犯罪都市(日本版)'), '犯罪都市');
      expect(ArtworkService.titleCandidates('犯罪都市(日本版)'), contains('犯罪都市'));
      expect(ArtworkService.titleCandidates('葬送的芙莉莲 第二季'), contains('葬送的芙莉莲'));
      // 资源站常见的营销后缀不能带进搜索引擎，否则豆瓣 / B 站都搜不到。
      expect(
        ArtworkService.cleanMetadataTitle('复仇者联盟4 加码臻享版'),
        '复仇者联盟4',
      );
      expect(
        ArtworkService.titleCandidates('复仇者联盟4 加码臻享版'),
        contains('复仇者联盟4'),
      );
      expect(ArtworkService.cleanMetadataTitle('某某剧 中字版'), '某某剧');
      expect(ArtworkService.metadataYear('The.Covenant.2006.1080p'), '2006');
    });

    test('从资源名提取真正剧名', () {
      expect(ArtworkService.dramaTitle('XXX【甄彩】'), 'XXX');
      expect(ArtworkService.dramaTitle('20261026【玉置秋】直播 丞磊徐若晗'), '玉置秋');
      expect(ArtworkService.dramaTitle('《玉置秋》尺度好大…'), '玉置秋');
      expect(ArtworkService.dramaTitle('「丞磊」玉置秋/虞昶轩/天后之后'), '玉置秋');
      expect(
        ArtworkService.dramaTitle('The.Covenant.2006.1080p'),
        'The Covenant',
      );
    });

    test('结尾续作数字只在分集刮削时当季号', () {
      expect(
        ArtworkService.seasonHintOf('赛博朋克：边缘行者 2', trailingSequel: true),
        2,
      );
      expect(ArtworkService.seasonHintOf('赛博朋克：边缘行者 2'), isNull);
      expect(
        ArtworkService.seasonHintOf('赛博朋克 2077', trailingSequel: true),
        isNull,
      );
      expect(ArtworkService.seasonHintOf('高达00', trailingSequel: true), isNull);
      expect(ArtworkService.seasonHintOf('Some Show 2nd Season'), 2);
      expect(ArtworkService.seasonHintOf('线路2'), isNull);
    });

    test('片名匹配键折叠标点 / 配音版本，但保留季与篇章', () {
      expect(
        ArtworkService.titleMatchKey('鬼灭之刃 中配版'),
        ArtworkService.titleMatchKey('鬼灭之刃'),
      );
      expect(
        ArtworkService.titleMatchKey('SPY×FAMILY'),
        ArtworkService.titleMatchKey('SPY FAMILY'),
      );
      expect(
        ArtworkService.titleMatchKey('鬼灭之刃 柱训练篇'),
        isNot(ArtworkService.titleMatchKey('鬼灭之刃')),
      );
      expect(
        ArtworkService.episodeTitleCandidates('赛博朋克：边缘行者 2'),
        contains('赛博朋克：边缘行者'),
      );
    });
  });

  group('360 图片补图', () {
    So360Image item(String title, {int w = 1920, int h = 1080}) => So360Image(
      title: title,
      url: 'https://n.sinaimg.cn/${Uri.encodeComponent(title)}.jpg',
      width: w,
      height: h,
    );

    test('解析 img/thumb、标题与宽高', () {
      final parsed = ArtworkService.parseSo360({
        'list': [
          {
            'img': 'https://p6.moimg.net/a.jpg',
            'thumb': 'https://p2.ssl.qhimgs1.com/t1.jpg',
            'title': '假面骑士ZEZTZ情报汇总',
            'width': '1080',
            'height': '1920',
          },
          {
            'thumb': 'https://p2.ssl.qhimgs1.com/t2.jpg',
            'litetitle': '备选',
          },
        ],
      });
      expect(parsed, hasLength(2));
      expect(parsed[0].url, 'https://p6.moimg.net/a.jpg');
      expect(parsed[0].width, 1080);
      expect(parsed[1].url, 'https://p2.ssl.qhimgs1.com/t2.jpg');
      expect(parsed[1].width, 0);
      expect(ArtworkService.parseSo360(null), isEmpty);
    });

    test('季号解析', () {
      expect(ArtworkService.so360SeasonNo('侠探杰克第四季'), 4);
      expect(ArtworkService.so360SeasonNo('无耻之徒 第二季'), 2);
      expect(ArtworkService.so360SeasonNo('庆余年第十二部'), 12);
      expect(ArtworkService.so360SeasonNo('狂飙'), 0);
    });

    test('相关性：共同子串 ≥4 字，季号冲突拒绝', () {
      expect(
        ArtworkService.so360RelevantHit('假面骑士ZEZTZ日语', '假面骑士zeztz情报汇总'),
        isTrue,
      );
      expect(ArtworkService.so360RelevantHit('狂飙', '《狂飙》剧照'), isTrue);
      expect(
        ArtworkService.so360RelevantHit(
          '满级茶艺师替妹手撕伪善白莲花',
          '2018茶企通《最美茶艺师》电视大赛',
        ),
        isFalse,
      );
      expect(
        ArtworkService.so360RelevantHit('侠探杰克第四季', '侠探杰克 第三季 剧情解析'),
        isFalse,
      );
      expect(
        ArtworkService.so360RelevantHit('侠探杰克第四季', '侠探杰克 剧照合集'),
        isFalse,
      );
      expect(
        ArtworkService.so360RelevantHit(
          'Inception',
          'Interstellar movie poster',
        ),
        isFalse,
      );
    });

    test('横图精选：排除竖图 / 缩略图 / 年份冲突 / 网盘文 / B站缩略图', () {
      final best = ArtworkService.pickSo360Backdrop([
        item('流浪地球 2019 剧照'),
        item('流浪地球 2023 横版'),
        item('流浪地球 海报', w: 900, h: 1350),
        item('流浪地球 缩略图', w: 400, h: 200),
        item('流浪地球 百度云下载'),
        item('流浪地球 游戏攻略', w: 1600, h: 900),
        So360Image(
          title: '流浪地球 2019 剧照',
          url: 'https://i1.hdslb.com/bfs/archive/x.jpg',
          width: 1920,
          height: 1080,
        ),
        item('狂飙 剧照'),
      ], '流浪地球', year: '2019');
      expect(best?.title, '流浪地球 2019 剧照');
    });

    test('横图精选：季号一致且去重', () {
      final good = item('庆余年第二季 横版剧照');
      final best = ArtworkService.pickSo360Backdrop([
        item('庆余年第一季 剧照'),
        item('庆余年第二季 百度云下载'),
        good,
        good,
      ], '庆余年第二季');
      expect(best?.title, '庆余年第二季 横版剧照');
    });
  });

  group('封面地址持久化', () {
    test('第二次启动直接复用落盘地址，不再请求接口', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await LocalStore.create();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        final path = request.url.path;
        if (path.contains('subject_suggest')) {
          return http.Response(
            jsonEncode([
              {
                'id': '35588177',
                'title': '漫长的季节',
                'type': 'movie',
                'episode': '12',
                'year': '2023',
                'img': '',
              },
            ]),
            200,
            // http 包默认按 latin1 编码字符串体，中文标题会直接抛
            // 「Contains invalid characters」，必须显式声明 UTF-8。
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path.contains('/photos')) {
          return http.Response(
            jsonEncode({
              'photos': [
                {
                  'image': {
                    'large': {
                      'url': 'https://img3.doubanio.com/view/photo/l/public/p1.jpg',
                      'width': 1600,
                      'height': 900,
                    },
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });
      final first = ArtworkService(
        AppHttp(client: client),
        () => const PlayerSettings(),
        store: store,
      );
      final firstUrl = await first.backdrop('漫长的季节', year: '2023');
      expect(firstUrl, contains('p1.jpg'));
      final firstRequests = requests;
      expect(firstRequests, greaterThan(0));
      // 落盘是 900ms 防抖，等它写完再模拟一次「重启」。
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final second = ArtworkService(
        AppHttp(client: client),
        () => const PlayerSettings(),
        store: store,
      );
      expect(await second.backdrop('漫长的季节', year: '2023'), firstUrl);
      expect(requests, firstRequests, reason: '命中持久化缓存后不应再请求豆瓣');
    });
  });

  group('封面来源仲裁', () {
    test('首选源拿到够用的横图就返回，不再等其它来源', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('subject_suggest')) {
          return http.Response(
            jsonEncode([
              {
                'id': '35588177',
                'title': '漫长的季节',
                'type': 'movie',
                'episode': '12',
                'year': '2023',
                'img': '',
              },
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path.contains('/photos')) {
          return http.Response(
            jsonEncode({
              'photos': [
                {
                  'image': {
                    'large': {
                      'url': 'https://img3.doubanio.com/view/photo/l/public/p1.jpg',
                      'width': 1280,
                      'height': 720,
                    },
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        // 模拟 IMDb / TVmaze 慢响应：旧逻辑会等它返回后才用豆瓣图。
        await Future<void>.delayed(const Duration(seconds: 3));
        return http.Response('{}', 404);
      });
      final service = ArtworkService(
        AppHttp(client: client),
        () => const PlayerSettings(),
      );
      final started = DateTime.now();
      final url = await service.backdrop('漫长的季节', year: '2023');
      expect(url, contains('p1.jpg'));
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
        reason: '豆瓣 1280 宽已经够用，不应等慢来源',
      );
    });
  });

  group('TMDB 季映射', () {
    final seasons = [
      {'season_number': 1, 'episode_count': 12},
      {'season_number': 2, 'episode_count': 12},
      {'season_number': 3, 'episode_count': 24},
    ];

    test('季号提示优先', () {
      expect(ArtworkService.pickSeasons(seasons, 12, 2), [2]);
      expect(ArtworkService.pickSeasons(seasons, 24, 3), [3]);
    });

    test('集数唯一匹配 / 多季同集数取最近季', () {
      // 12/12 两季集数相同，资源站通常列的是当前正在播的一季。
      expect(ArtworkService.pickSeasons(seasons, 12, null), [2]);
      expect(ArtworkService.pickSeasons(seasons, 24, null), [3]);
    });

    test('年份对得上的季优先，其次最近一季兜底', () {
      final dated = [
        {'season_number': 1, 'episode_count': 12, 'air_date': '2022-04-01'},
        {'season_number': 2, 'episode_count': 12, 'air_date': '2024-04-01'},
      ];
      expect(ArtworkService.pickSeasons(dated, 12, null, year: '2022'), [1]);
      expect(ArtworkService.pickSeasons(dated, 12, null), [2]);
      // 站点集数比最近季少（更新中 / 预告占位）→ 用最近一季补齐。
      expect(ArtworkService.pickSeasons(dated, 5, null), [2]);
    });

    test('多季集数之和一致', () {
      expect(
        ArtworkService.pickSeasons(
          [
            {'season_number': 1, 'episode_count': 12},
            {'season_number': 2, 'episode_count': 12},
          ],
          24,
          null,
        ),
        [1, 2],
      );
    });

    test('单季更新中只取前 N 集', () {
      expect(
        ArtworkService.pickSeasons(
          [
            {'season_number': 1, 'episode_count': 24},
          ],
          10,
          null,
        ),
        [1],
      );
    });

    test('季号提示下更新中 / 连续两季合并', () {
      expect(
        ArtworkService.pickSeasons(
          [
            {'season_number': 1, 'episode_count': 12},
            {'season_number': 2, 'episode_count': 12},
            {'season_number': 3, 'episode_count': 12},
          ],
          10,
          2,
        ),
        [2],
      );
      expect(
        ArtworkService.pickSeasons(
          [
            {'season_number': 1, 'episode_count': 12},
            {'season_number': 2, 'episode_count': 12},
            {'season_number': 3, 'episode_count': 12},
          ],
          24,
          2,
        ),
        [2, 3],
      );
    });
  });

  group('B 站分集匹配', () {
    test('同名续作按季号选中正确条目', () async {
      var requestedSeasonId = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('/x/frontend/finger/spi')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'b_3': 'b3', 'b_4': 'b4'},
            }),
            200,
          );
        }
        if (path.contains('/x/web-interface/search/type')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'result': [
                  {
                    'title': 'Dandadan Season 2',
                    'org_title': 'Dandadan 2nd Season',
                    'season_id': 101,
                    'ep_size': 2,
                    'pubtime': 1750000000,
                  },
                  {
                    'title': 'Dandadan',
                    'org_title': 'Dandadan',
                    'season_id': 100,
                    'ep_size': 2,
                    'pubtime': 1690000000,
                  },
                ],
              },
            }),
            200,
          );
        }
        if (path.contains('/pgc/view/web/season')) {
          requestedSeasonId = int.parse(
            request.url.queryParameters['season_id']!,
          );
          return http.Response(
            jsonEncode({
              'code': 0,
              'result': {
                'episodes': [
                  {
                    'title': 'EP01',
                    'cover': 'https://cdn.example.com/$requestedSeasonId/1.jpg',
                  },
                  {
                    'title': 'EP02',
                    'cover': 'https://cdn.example.com/$requestedSeasonId/2.jpg',
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final service = ArtworkService(
        AppHttp(client: client),
        () => const PlayerSettings(),
      );

      final season2 = await service.episodeStills(
        'Dandadan Season 2',
        episodeCount: 2,
        episodeNumbers: const [1, 2],
      );
      expect(requestedSeasonId, 101);
      expect(season2, [
        'https://cdn.example.com/101/1.jpg',
        'https://cdn.example.com/101/2.jpg',
      ]);

      final season1 = await service.episodeStills(
        'Dandadan',
        episodeCount: 2,
        episodeNumbers: const [1, 2],
      );
      expect(requestedSeasonId, 100);
      expect(season1, [
        'https://cdn.example.com/100/1.jpg',
        'https://cdn.example.com/100/2.jpg',
      ]);
    });

    test('番剧分类无结果时回退影视分类', () async {
      final types = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('/x/frontend/finger/spi')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'b_3': 'b3', 'b_4': 'b4'},
            }),
            200,
          );
        }
        if (path.contains('/x/web-interface/search/type')) {
          final type = request.url.queryParameters['search_type'] ?? '';
          types.add(type);
          final result = type == 'media_ft'
              ? [
                  {
                    'title': '古相思曲',
                    'season_id': 200,
                    'ep_size': 14,
                    'pubtime': 1688000000,
                  },
                ]
              : const [];
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'result': result},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path.contains('/pgc/view/web/season')) {
          final seasonId = request.url.queryParameters['season_id'];
          return http.Response(
            jsonEncode({
              'code': 0,
              'result': {
                'episodes': [
                  {
                    'title': 'EP01',
                    'cover': 'https://cdn.example.com/$seasonId/1.jpg',
                  },
                  {
                    'title': 'EP02',
                    'cover': 'https://cdn.example.com/$seasonId/2.jpg',
                  },
                  {
                    'title': 'EP03',
                    'cover': 'https://cdn.example.com/$seasonId/3.jpg',
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final service = ArtworkService(
        AppHttp(client: client),
        () => const PlayerSettings(),
      );

      final stills = await service.episodeStills(
        '古相思曲',
        episodeCount: 3,
        episodeNumbers: const [1, 2, 3],
      );
      expect(types, ['media_bangumi', 'media_ft']);
      expect(stills, [
        'https://cdn.example.com/200/1.jpg',
        'https://cdn.example.com/200/2.jpg',
        'https://cdn.example.com/200/3.jpg',
      ]);
    });

    test('优先使用 WBI 签名搜索', () async {
      var signedPath = '';
      var wridLength = 0;
      var wts = '';
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('/x/frontend/finger/spi')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'b_3': 'b3', 'b_4': 'b4'},
            }),
            200,
          );
        }
        if (path.contains('/x/web-interface/nav')) {
          return http.Response(
            jsonEncode({
              'code': -101,
              'data': {
                'wbi_img': {
                  'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
                  'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
                },
              },
            }),
            200,
          );
        }
        if (path.contains('search/type')) {
          signedPath = path;
          wridLength = (request.url.queryParameters['w_rid'] ?? '').length;
          wts = request.url.queryParameters['wts'] ?? '';
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'result': [
                  {
                    'title': 'TestShow',
                    'season_id': 300,
                    'ep_size': 2,
                    'pubtime': 1700000000,
                  },
                ],
              },
            }),
            200,
          );
        }
        if (path.contains('/pgc/view/web/season')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'result': {
                'episodes': [
                  {
                    'title': 'EP01',
                    'cover': 'https://cdn.example.com/300/1.jpg',
                  },
                  {
                    'title': 'EP02',
                    'cover': 'https://cdn.example.com/300/2.jpg',
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final service = ArtworkService(
        AppHttp(client: client),
        () => const PlayerSettings(),
      );

      final stills = await service.episodeStills(
        'TestShow',
        episodeCount: 2,
        episodeNumbers: const [1, 2],
      );
      expect(signedPath, '/x/web-interface/wbi/search/type');
      expect(wridLength, 32);
      expect(wts, isNotEmpty);
      expect(stills, [
        'https://cdn.example.com/300/1.jpg',
        'https://cdn.example.com/300/2.jpg',
      ]);
    });
  });

  group('TMDB 分集封面请求', () {
    test('按集号回填 still，并缓存结果', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        final path = request.url.path;
        if (path.contains('/search/multi')) {
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'media_type': 'tv',
                  'id': 123,
                  'name': 'TestShow',
                  'first_air_date': '2026-01-01',
                },
              ],
            }),
            200,
          );
        }
        if (path.endsWith('/3/tv/123')) {
          return http.Response(
            jsonEncode({
              'seasons': [
                {'season_number': 1, 'episode_count': 2},
              ],
            }),
            200,
          );
        }
        if (path.endsWith('/3/tv/123/season/1')) {
          return http.Response(
            jsonEncode({
              'episodes': [
                {'episode_number': 1, 'still_path': '/a.jpg', 'name': 'Ep1'},
                {'episode_number': 2, 'still_path': '/b.jpg', 'name': 'Ep2'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final service = ArtworkService(
        AppHttp(client: client),
        // v3 Key 是 32 位十六进制，用格式合法的假值，别把「格式校验」当成业务失败。
        () => const PlayerSettings(
          tmdbApiKey: '0123456789abcdef0123456789abcdef',
        ),
      );

      final stills = await service.episodeStills(
        'TestShow',
        year: '2026',
        episodeCount: 2,
        episodeNumbers: const [2, 1],
      );
      expect(stills, [
        'https://image.tmdb.org/t/p/w780/b.jpg',
        'https://image.tmdb.org/t/p/w780/a.jpg',
      ]);

      final firstRequests = requests;
      final cached = await service.episodeStills(
        'TestShow',
        year: '2026',
        episodeCount: 2,
        episodeNumbers: const [2, 1],
      );
      expect(cached, stills);
      expect(requests, firstRequests);
    });

    test('没有 TMDB Key 时不请求', () async {
      final service = ArtworkService(
        AppHttp(client: MockClient((_) async => http.Response('{}', 200))),
        () => const PlayerSettings(),
      );
      expect(await service.episodeStills('TestShow', episodeCount: 2), isEmpty);
    });
  });
}
