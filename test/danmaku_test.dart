import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/services/danmaku/danmaku.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
const _xmlHeaders = {'content-type': 'text/xml; charset=utf-8'};

void main() {
  group('parseXml', () {
    test('模式 / 字号 / 颜色 / 实体 / 异常行', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<i>
<d p="1.5,1,25,16777215,0,0,0,0">滚动 &amp; &lt;实体&gt;</d>
<d p="2,4,30,255">底部</d>
<d p='3,5,5,0'><![CDATA[顶部<测试>]]></d>
<d p="4,2,99,-1">两号滚动</d>
<d p="4.5,3,40,16711680">三号滚动</d>
<d p="5,6,35,65280">六号滚动\r带回车</d>
<d foo="x" p="6,7,25,16777215">高级弹幕丢弃</d>
<d p="7,1,25,16777215"></d>
<d p="bad,1,25,16777215">时间非法</d>
<d foo="1">缺 p</d>
<d p="8,1,25,16777215"/>
</i>
''';
      final items = parseDanmakuXml(xml);
      expect(items.length, 6);

      expect(items[0].time, 1.5);
      expect(items[0].type, 'scroll');
      expect(items[0].size, 25);
      expect(items[0].color, '#ffffff');
      expect(items[0].text, '滚动 & <实体>');

      expect(items[1].type, 'bottom');
      expect(items[1].size, 30);
      expect(items[1].color, '#0000ff');

      expect(items[2].type, 'top');
      expect(items[2].size, 12, reason: '字号 clamp 到下限 12');
      expect(items[2].color, '#000000');
      expect(items[2].text, '顶部<测试>');

      expect(items[3].type, 'scroll', reason: 'mode 2 也算滚动');
      expect(items[3].size, 40, reason: '字号 clamp 到上限 40');
      expect(items[3].color, '#ffffff', reason: '负数颜色按 32 位无符号');

      expect(items[4].type, 'scroll', reason: 'mode 3 也算滚动');
      expect(items[4].size, 40);
      expect(items[4].color, '#ff0000');

      expect(items[5].type, 'scroll', reason: 'mode 6 也算滚动');
      expect(items[5].size, 35);
      expect(items[5].color, '#00ff00');
      expect(items[5].text, '六号滚动带回车', reason: '去掉 \\r');
    });

    test('空文本 / 字数为 0 回退 25 / 自闭合丢弃', () {
      const xml = '''
<d p="1,1,0,16777215"> </d>
<d p="2,1,0,16777215">有内容</d>
<d p="3,1,25,16777215"/>
''';
      final items = parseDanmakuXml(xml);
      expect(items.length, 1);
      expect(items.single.size, 25);
      expect(items.single.text, '有内容');
    });

    test('非法/空输入返回空表', () {
      expect(parseDanmakuXml(''), isEmpty);
      expect(parseDanmakuXml('<i></i>'), isEmpty);
      expect(parseDanmakuXml('不是 xml'), isEmpty);
    });

    test('JSON 弹幕（p=时间,模式,颜色）与首字符探测', () {
      final json = jsonEncode({
        'count': 2,
        'comments': [
          {'p': '1.25,1,16711680,abc', 'm': '红色滚动'},
          {'p': '2,4,0,abc', 'm': '底部'},
          {'p': '3,7,0,abc', 'm': '高级丢弃'},
        ],
      });
      final jsonItems = parseDanmakuResponse(json);
      expect(jsonItems.length, 2);
      expect(jsonItems[0].color, '#ff0000');
      expect(jsonItems[0].size, 25);
      expect(jsonItems[1].type, 'bottom');
      expect(jsonItems[1].color, '#000000');

      final xmlItems = parseDanmakuResponse(
        '<i><d p="1,1,25,16777215">x</d></i>',
      );
      expect(xmlItems.single.text, 'x');
      expect(parseDanmakuResponse('  '), isEmpty);
    });
  });

  group('内置接口清单', () {
    test('28 个内置接口，默认只启用炊烟袅袅', () {
      expect(builtinDanmakuEndpoints.length, 28);
      final enabled = builtinDanmakuEndpoints.where((e) => e.enabled).toList();
      expect(enabled.length, 1);
      expect(enabled.single.name, '炊烟袅袅');
      expect(enabled.single.url, 'https://danmu.cynn.top/cynnsq');
    });

    test('defaultDanmakuEndpoints 返回新副本', () {
      final a = defaultDanmakuEndpoints();
      final b = defaultDanmakuEndpoints();
      expect(identical(a, b), isFalse);
      a[0] = const DanmakuEndpoint(
        name: 'x',
        url: 'https://x.test',
        enabled: false,
      );
      expect(builtinDanmakuEndpoints.first.name, '炊烟袅袅');
      expect(defaultDanmakuEndpoints().first.name, '炊烟袅袅');
    });
  });

  group('RankAnimes', () {
    DanmakuAnime anime(String title, {required String source, int ec = 0}) =>
        DanmakuAnime(
          animeId: title.hashCode & 0xFFFF,
          title: title,
          episodeCount: ec,
          source: source,
        );

    test('同季优先 + 集数多者优先，稳定不重排', () {
      final list = [
        anime('绝命毒师 花絮', source: 'A', ec: 1),
        anime('绝命毒师 第一季', source: 'A', ec: 7),
        anime('绝命毒师 第二季', source: 'A', ec: 10),
        anime('绝命毒师 第2季', source: 'B', ec: 12),
        anime('绝命毒师', source: 'C', ec: 0),
      ];
      final ranked = rankDanmakuAnimes(list, '绝命毒师', 2);
      expect(ranked.map((e) => e.title).toList(), [
        '绝命毒师',
        '绝命毒师 第2季',
        '绝命毒师 第二季',
        '绝命毒师 花絮',
        '绝命毒师 第一季',
      ]);
    });

    test('完全同名优先于包含关系；同来源同名去重', () {
      final list = [
        anime('斗罗大陆2', source: 'A'),
        anime('斗罗大陆', source: 'A'),
        anime('斗罗大陆', source: 'A'),
        anime('斗罗大陆 年番', source: 'B'),
      ];
      final ranked = rankDanmakuAnimes(list, '斗罗大陆');
      expect(ranked.first.title, '斗罗大陆');
      expect(ranked.where((e) => e.title == '斗罗大陆').length, 1);
      expect(ranked.length, 3);
    });

    test('未给季号时保持原相对顺序', () {
      final list = [
        anime('甲', source: 'A'),
        anime('乙', source: 'A'),
        anime('丙', source: 'B'),
      ];
      final ranked = rankDanmakuAnimes(list, '不存在');
      expect(ranked.map((e) => e.title).toList(), ['甲', '乙', '丙']);
    });
  });

  group('EpNumber / CandidateMatchesEp / SortByEp', () {
    DanmakuCandidate c({
      String title = '',
      String epTitle = '',
      String epNum = '',
    }) => DanmakuCandidate(
      episodeId: 1,
      title: title,
      episodeTitle: epTitle,
      episodeNumber: epNum,
    );

    test('接口集号字段优先', () {
      expect(epNumberOf(c(epTitle: '第9集', epNum: '4')), 4);
      expect(epNumberOf(c(epNum: '10')), 10);
    });

    test('标题显式写法：第N集 / SxxExx / 更新至N', () {
      expect(epNumberOf(c(epTitle: '第12集')), 12);
      expect(epNumberOf(c(epTitle: '第3话')), 3);
      expect(epNumberOf(c(epTitle: 'S02E07')), 7);
      expect(epNumberOf(c(epTitle: '更新至5')), 5);
      expect(epNumberOf(c(epTitle: '至8')), 8);
      expect(epNumberOf(c(epTitle: '01')), 1);
    });

    test('兜底只认独立数字，排除 4K / 年份', () {
      expect(epNumberOf(c(epTitle: '4K 超清')), isNull);
      expect(epNumberOf(c(epTitle: '2024')), isNull);
      expect(epNumberOf(c(epTitle: '第4集 4K')), 4);
      expect(epNumberOf(c(epTitle: '第4集')), 4);
      expect(epNumberOf(c(epTitle: '')), isNull);
      expect(epNumberOf(c(epTitle: '花絮')), isNull);
    });

    test('CandidateMatchesEp', () {
      expect(candidateMatchesEp(c(epNum: '04'), '4'), isTrue);
      expect(candidateMatchesEp(c(epNum: '4'), '004'), isTrue);
      expect(candidateMatchesEp(c(epTitle: '第3集'), '3'), isTrue);
      expect(candidateMatchesEp(c(epNum: '5'), '4'), isFalse);
      expect(candidateMatchesEp(c(epNum: '4'), ''), isFalse);
      expect(candidateMatchesEp(c(epTitle: '4K'), '4'), isFalse);
    });

    test('SortByEp：有集号升序在前，无集号保持原序在后', () {
      final list = [
        c(epTitle: '花絮'),
        c(epNum: '10'),
        c(epNum: '2'),
        c(epTitle: '预告'),
        c(epNum: '1'),
      ];
      final sorted = sortCandidatesByEp(list);
      expect(sorted.map((e) => e.episodeNumber).toList(), [
        '1',
        '2',
        '10',
        '',
        '',
      ]);
      expect(sorted[3].episodeTitle, '花絮');
      expect(sorted[4].episodeTitle, '预告');
    });

    test('rankCandidates：同集优先 + 集号升序', () {
      final list = [
        c(title: '斗罗大陆', epNum: '3'),
        c(title: '斗罗大陆', epNum: '1'),
        c(title: '斗罗大陆 年番', epNum: '1'),
      ];
      final ranked = DanmakuService.rankCandidates(list, '斗罗大陆', ep: '1');
      expect(ranked.first.title, '斗罗大陆');
      expect(ranked.first.episodeNumber, '1');
      expect(ranked.last.title, '斗罗大陆 年番');
    });
  });

  group('自定义接口 / 地址归一', () {
    test('normalizeEndpointBase', () {
      expect(
        normalizeEndpointBase(' https://a.test/x/// '),
        'https://a.test/x',
      );
      expect(normalizeEndpointBase('a.test'), 'https://a.test');
      expect(normalizeEndpointBase('ftp://a.test'), '');
      expect(normalizeEndpointBase(''), '');
      expect(normalizeEndpointBase('不是地址'), '');
      expect(normalizeEndpointBase('https://中文.test'), '');
      expect(endpointLabel('https://www.a.test/x'), 'a.test');
      expect(joinApi('a.test/', '/api/v2/x'), 'https://a.test/api/v2/x');
    });

    test('名字@URL 解析 / 注释 / 去重 / 非法忽略', () {
      const text = '''
名字@https://a.test/token
https://b.test/
# 注释行
不是地址
https://a.test/token/
C@http://c.test:8080/x?y=1
''';
      final list = parseCustomEndpoints(text);
      expect(list.length, 3);
      expect(list[0].name, '名字');
      expect(list[0].url, 'https://a.test/token');
      expect(list[0].enabled, isTrue);
      expect(list[1].name, 'b.test');
      expect(list[1].url, 'https://b.test');
      expect(list[2].name, 'C');
      expect(list[2].url, 'http://c.test:8080/x?y=1');
    });

    test('mergeEndpoints 保留开关状态与回显', () {
      final current = [
        ...defaultDanmakuEndpoints(),
        const DanmakuEndpoint(name: '旧名', url: 'https://a.test/token'),
      ];
      current[0] = current[0].copyWith(enabled: false);
      current.last = current.last.copyWith(enabled: false);

      final merged = mergeEndpoints(
        current,
        '新名@https://a.test/token\nhttps://d.test',
      );
      expect(merged.length, 30);
      expect(merged.first.name, '炊烟袅袅');
      expect(merged.first.enabled, isFalse, reason: '既有开关状态保留');
      expect(merged.where((e) => e.url == 'https://d.test').length, 1);
      expect(
        merged.firstWhere((e) => e.url == 'https://a.test/token').enabled,
        isFalse,
        reason: '自定义项沿用旧开关',
      );

      final echo = customEndpointsText(merged);
      expect(echo.split('\n').length, 2);
      expect(echo, contains('https://a.test/token'));
      expect(echo, isNot(contains('cynn.top')));
      expect(isBuiltinEndpoint('https://danmu.cynn.top/cynnsq/'), isTrue);
      expect(isBuiltinEndpoint('https://d.test'), isFalse);
    });
  });

  group('normalizeQuery', () {
    test('danmakuQueryCandidates 生成清洗候选', () {
      final list = danmakuQueryCandidates('斗罗大陆 第12集');
      expect(list.first, '斗罗大陆 第12集');
      expect(list, contains('斗罗大陆'));
      expect(list.length, lessThanOrEqualTo(6));
      expect(danmakuQueryCandidates(''), isEmpty);
    });

    test('parseEpisodeInput', () {
      expect(parseEpisodeInput('S01E10').season, 1);
      expect(parseEpisodeInput('S01E10').ep, '10');
      expect(parseEpisodeInput('2x3').season, 2);
      expect(parseEpisodeInput('2x3').ep, '3');
      expect(parseEpisodeInput('第10集').ep, '10');
      expect(parseEpisodeInput('E05').ep, '5');
      expect(parseEpisodeInput('第2季').season, 2);
      expect(parseEpisodeInput('随便').ep, isNull);
    });

    test('episodeFieldFromName', () {
      expect(episodeFieldFromName('斗罗大陆.S02E03.1080p'), 'S2E03');
      expect(episodeFieldFromName('某某 第10集'), '10');
      expect(episodeFieldFromName('某某 12'), '12');
      expect(episodeFieldFromName('无集号'), '');
    });

    test('formatCandidateLabel 压缩显示', () {
      expect(formatCandidateLabel(title: '斗破苍穹年番 第212话'), '斗破苍穹年番 · 第212集');
      expect(
        formatCandidateLabel(title: '斗罗大陆系列小剧场(2026)【动漫】from tencent'),
        '斗罗大陆系列小剧场（2026）',
      );
      expect(formatCandidateLabel(title: '某剧 第二季 第3集'), '某剧 · 第2季 · 第3集');
      expect(formatCandidateLabel(), '');
    });
  });

  group('DanmakuSettings', () {
    test('默认值：仅炊烟袅袅启用', () {
      final s = DanmakuSettings.defaults();
      expect(s.enabled, isFalse);
      expect(s.regionRatio, 1);
      expect(s.fontSize, 24);
      expect(s.opacity, 0.85);
      expect(s.density, 1);
      expect(s.speed, 110);
      expect(s.offset, 0);
      expect(s.blockWords, isEmpty);
      expect(s.endpoints.length, 28);
      expect(s.endpoints.where((e) => e.enabled).length, 1);
    });

    test('JSON 读写往返', () {
      final s = DanmakuSettings.defaults().copyWith(
        enabled: true,
        opacity: 0.5,
        regionRatio: 0.43,
        blockWords: normalizeDanmakuBlockWords('剧透\n广告,spoiler'),
      );
      final back = DanmakuSettings.fromJsonString(s.toJsonString());
      expect(back.enabled, isTrue);
      expect(back.opacity, 0.5);
      expect(back.regionRatio, 0.43);
      expect(back.blockWords, ['剧透', '广告', 'spoiler']);
      expect(back.endpoints.length, 28);
      expect(back.endpoints.first.enabled, isTrue);
    });

    test('屏蔽词：字符串形式兼容 / 旧 region 迁移 / 非法值回退全屏', () {
      final s = DanmakuSettings.fromJson({
        'region': 'threeQuarter',
        'blockWords': '剧透、广告\nspoiler',
        'endpointsRev': 2,
      });
      expect(s.regionRatio, 0.75);
      expect(s.blockWords, ['剧透', '广告', 'spoiler']);

      final bad = DanmakuSettings.fromJson({
        'region': 'half-screen',
        'endpointsRev': 2,
      });
      expect(bad.regionRatio, 1);
      expect(bad.blockWords, isEmpty);

      final clamped = DanmakuSettings.fromJson({
        'regionRatio': 2,
        'endpointsRev': 2,
      });
      expect(clamped.regionRatio, 1);
    });

    test('脏数据：非法地址剔除 / 尾斜杠归一 / 同地址去重 / 非法区域回退', () {
      final s = DanmakuSettings.fromJsonString(
        jsonEncode({
          'enabled': true,
          'region': 'half-screen',
          'endpoints': [
            {'name': '', 'url': 'https://a.test/x/', 'enabled': true},
            {'name': '重复', 'url': 'https://a.test/x', 'enabled': false},
            {'name': '坏', 'url': '不是地址', 'enabled': true},
          ],
          'endpointsRev': 2,
        }),
      );
      expect(s.regionRatio, 1);
      expect(s.endpoints.length, 1);
      expect(s.endpoints.single.url, 'https://a.test/x');
      expect(s.endpoints.single.name, 'a.test');
      expect(s.endpoints.single.enabled, isTrue);
    });

    test('旧配置（rev<2）内置项回到默认开关，自定义项保留', () {
      final s = DanmakuSettings.fromJson({
        'endpoints': [
          {
            'name': '炊烟袅袅',
            'url': 'https://danmu.cynn.top/cynnsq',
            'enabled': false,
          },
          {'name': '自定义', 'url': 'https://a.test/x', 'enabled': false},
        ],
      });
      expect(s.endpoints.length, 29);
      expect(s.endpoints.where((e) => e.enabled).length, 1);
      expect(s.endpoints.first.enabled, isTrue);
      expect(s.endpoints.last.url, 'https://a.test/x');
      expect(s.endpoints.last.enabled, isFalse);
    });

    test('非法 JSON 返回默认值', () {
      expect(DanmakuSettings.fromJsonString('{').endpoints.length, 28);
      expect(DanmakuSettings.fromJsonString(null).endpoints.length, 28);
    });
  });

  group('弹幕屏蔽词', () {
    test('归一：行 / 逗号 / 顿号 / 分号，去重保留 /正则/', () {
      final words = normalizeDanmakuBlockWords(
        ' 剧透 \n广告,广告，spoiler、/ab+c/;/ab+c/ ;  ',
      );
      expect(words, ['剧透', '广告', 'spoiler', '/ab+c/']);
    });

    test('关键词子串匹配（大小写不敏感）', () {
      const words = ['剧透', 'AD'];
      expect(isDanmakuBlocked('前方剧透预警', words), isTrue);
      expect(isDanmakuBlocked('含广告内容', words), isFalse);
      expect(isDanmakuBlocked('这里有 ad 字样', words), isTrue);
      expect(isDanmakuBlocked('普通弹幕', words), isFalse);
      expect(isDanmakuBlocked('', words), isFalse);
      expect(isDanmakuBlocked('剧透', const []), isFalse);
    });

    test('正则匹配 / 非法正则忽略', () {
      const words = ['/^\\d+\$/', '/[a-/'];
      expect(isDanmakuBlocked('12345', words), isTrue);
      expect(isDanmakuBlocked('12345 个', words), isFalse);
      expect(isDanmakuBlocked('普通弹幕', words), isFalse, reason: '非法正则不影响其他项');
    });

    test('copyWith 保留屏蔽词', () {
      final s = DanmakuSettings.defaults().copyWith(blockWords: const ['x']);
      expect(s.copyWith(speed: 200).blockWords, ['x']);
      expect(s.copyWith(blockWords: const []).blockWords, isEmpty);
    });
  });

  group('DanmakuService', () {
    test('搜索：search/anime → bangumi 展开并按集号排序；失败源隔离 + 冷却', () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        if (req.url.host == 'dead.test') return http.Response('boom', 500);
        final path = req.url.path;
        if (path.endsWith('/api/v2/search/anime')) {
          return http.Response(
            jsonEncode({
              'animes': [
                {
                  'animeId': 1,
                  'bangumiId': 1,
                  'animeTitle': '斗罗大陆',
                  'episodeCount': 100,
                },
              ],
            }),
            200,
            headers: _jsonHeaders,
          );
        }
        if (path.endsWith('/api/v2/bangumi/1')) {
          return http.Response(
            jsonEncode({
              'bangumi': {
                'animeTitle': '斗罗大陆',
                'episodes': [
                  {'episodeId': 110, 'episodeTitle': '', 'episodeNumber': 10},
                  {'episodeId': 101, 'episodeTitle': '第1话'},
                ],
              },
            }),
            200,
            headers: _jsonHeaders,
          );
        }
        return http.Response('boom', 500);
      });
      final service = DanmakuService(client: client);
      final list = await service.search(
        '斗罗大陆',
        endpoints: const [
          DanmakuEndpoint(name: '好源', url: 'https://ok.test/base'),
          DanmakuEndpoint(name: '死源', url: 'https://dead.test'),
        ],
      );
      expect(list.length, 2);
      expect(list[0].episodeId, 101);
      expect(list[0].episodeNumber, '');
      expect(list[0].episodeTitle, '第1话');
      expect(list[0].title, '斗罗大陆');
      expect(list[0].source, 'https://ok.test/base');
      expect(list[0].sourceName, '好源');
      expect(list[1].episodeId, 110);
      expect(list[1].episodeNumber, '10');
      expect(service.health.isCooling('https://dead.test'), isTrue);
      expect(service.health.isCooling('https://ok.test/base'), isFalse);
      final keywordParam = Uri.encodeQueryComponent('斗罗大陆');
      expect(
        calls.map((u) => u.toString()),
        contains(
          'https://ok.test/base/api/v2/search/anime?keyword=$keywordParam',
        ),
      );
      expect(
        calls.map((u) => u.toString()),
        contains('https://dead.test/api/v2/search/anime?keyword=$keywordParam'),
      );
      service.close();
    });

    test('搜索：全部源冷却 / 空关键词 → 空表', () async {
      final service = DanmakuService(
        client: MockClient((req) async => http.Response('x', 500)),
      );
      expect(await service.search(''), isEmpty);
      expect(await service.search('x', endpoints: const []), isEmpty);
      service.health.markFail('https://a.test');
      expect(
        await service.search(
          'x',
          endpoints: const [DanmakuEndpoint(name: 'a', url: 'https://a.test')],
        ),
        isEmpty,
      );
      service.close();
    });

    test('并发上限 4', () async {
      var active = 0;
      var peak = 0;
      final client = MockClient((req) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        if (req.url.path == '/api/v2/search/anime') {
          return http.Response(
            jsonEncode({
              'animes': [
                {'animeId': 1, 'animeTitle': '同名剧'},
              ],
            }),
            200,
            headers: _jsonHeaders,
          );
        }
        return http.Response(
          jsonEncode({
            'bangumi': {
              'episodes': [
                {'episodeId': 1, 'episodeNumber': 1},
              ],
            },
          }),
          200,
          headers: _jsonHeaders,
        );
      });
      final service = DanmakuService(client: client);
      final endpoints = [
        for (var i = 0; i < 6; i++)
          DanmakuEndpoint(name: 's$i', url: 'https://s$i.test'),
      ];
      final list = await service.search('同名剧', endpoints: endpoints);
      expect(list.length, 4);
      expect(peak, lessThanOrEqualTo(4));
      service.close();
    });

    test('取弹幕：XML 解析 + 内存缓存 + 失败冷却', () async {
      var commentCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/api/v2/comment/12')) {
          commentCalls++;
          return http.Response(
            '<i><d p="1.5,1,25,16777215">缓存弹幕</d><d p="2,5,30,16711680">顶部</d></i>',
            200,
            headers: _xmlHeaders,
          );
        }
        return http.Response('nope', 500);
      });
      final service = DanmakuService(client: client);
      const candidate = DanmakuCandidate(
        episodeId: 12,
        source: 'https://ok.test/base',
      );
      final first = await service.fetch(candidate);
      expect(first.length, 2);
      expect(first[0].text, '缓存弹幕');
      expect(first[1].type, 'top');
      expect(first[1].color, '#ff0000');
      final second = await service.fetch(candidate);
      expect(second.length, 2);
      expect(commentCalls, 1, reason: '第二次走内存缓存');

      expect(
        await service.fetch(
          const DanmakuCandidate(episodeId: 0, source: 'https://ok.test/base'),
        ),
        isEmpty,
      );
      expect(
        await service.fetch(const DanmakuCandidate(episodeId: 1, source: '')),
        isEmpty,
      );
      expect(
        await service.fetch(
          const DanmakuCandidate(episodeId: 1, source: 'https://dead.test'),
        ),
        isEmpty,
      );
      expect(service.health.isCooling('https://dead.test'), isTrue);
      service.close();
    });

    test('settings 由注入的 JSON 回调提供', () {
      final service = DanmakuService(
        client: MockClient((req) async => http.Response('{}', 200)),
        settingsJson: () => {
          'danmaku': jsonEncode({
            'enabled': true,
            'region': 'quarter',
            'fontSize': 30,
            'endpointsRev': 2,
            'endpoints': [
              {'name': 'x', 'url': 'https://x.test', 'enabled': true},
            ],
          }),
        },
      );
      final s = service.settings;
      expect(s.enabled, isTrue);
      expect(s.regionRatio, 0.25);
      expect(s.fontSize, 30);
      expect(s.endpoints.single.url, 'https://x.test');
      expect(
        DanmakuService(
          client: MockClient((req) async => http.Response('{}', 200)),
        ).settings.endpoints.length,
        28,
      );
      service.close();
    });

    test('parseXml 静态方法', () {
      expect(
        DanmakuService.parseXml('<d p="1,1,25,16777215">x</d>').single.text,
        'x',
      );
    });
  });
}
