// test/subtitle_test.dart — 外挂字幕纯服务（normalizeQuery / 解析 / 解包 / 源解析）回归。
//
// 全部离线：压缩包用内存 zip 样本，assrt/SubtitleCat 用固定 fixture 字符串，
// 服务层用 MockClient 注入假的 HTTP 响应（默认不联网）。
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/services/subtitle/subtitle.dart';

const Map<String, String> _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

List<int> buildZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return ZipEncoder().encode(archive);
}

List<int> utf16leBytes(String s) {
  final out = <int>[];
  for (final unit in s.codeUnits) {
    out.add(unit & 0xff);
    out.add((unit >> 8) & 0xff);
  }
  return out;
}

const String assText =
    '[Script Info]\n'
    'ScriptType: v4.00+\n'
    '\n'
    '[Events]\n'
    'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}你好\\N世界\n'
    'Dialogue: 0,0:00:04.00,0:00:02.00,Default,,0,0,0,,倒序应被丢弃\n';

const String srtText =
    '1\n'
    '00:00:01,000 --> 00:00:03,500\n'
    '你好\n'
    '世界\n'
    '\n'
    '2\n'
    '00:00:04.250 --> 00:00:06,000\n'
    'Hi\n';

const String assrtSearchJson =
    '{"status":0,"sub":{"subs":['
    '{"id":123,"native_name":"繁花","videoname":"繁花.S01E01.1080p.mkv",'
    '"subtype":"ASS","release_site":"subhd","lang":{"desc":"简中"}},'
    '{"id":"456","native_name":"繁花 沪语","lang":{"desc":"简体"}}'
    ']}}';

const String assrtDetailJson =
    '{"status":0,"sub":{"subs":[{'
    '"url":"https://file0.assrt.net/download/pkg.zip",'
    '"filename":"繁花.zip",'
    '"filelist":['
    '{"url":"https://file0.assrt.net/download/pkg.zip","f":"繁花.zip"},'
    '{"url":"https://file0.assrt.net/download/ep1.ass","f":"繁花.EP01.ass"}'
    ']}]}}';

const String catSearchHtml =
    '<table>'
    '<tr><td><a href="subs/1594/Fan.Hua.html">繁花</a></td>'
    '<td>Size 143 KB</td><td>Downloads 7 downloads</td>'
    '<td>Languages 3 languages</td></tr>'
    '<tr><td><a href="subs/1600/Other.Show.html">Other Show</a></td>'
    '<td>Size 90 KB</td><td>Downloads 2 downloads</td></tr>'
    '<tr><td><a href="subs/1594/Fan.Hua-zh-CN.srt">繁花</a></td></tr>'
    '</table>';

const String catDetailHtml =
    '<table>'
    '<tr><td>English</td>'
    '<td><a href="subs/1594/Fan.Hua-en.srt">Download</a></td></tr>'
    '<tr><td>Chinese (Simplified)</td>'
    '<td><a href="subs/1594/Fan.Hua-zh-CN.srt">Download</a></td></tr>'
    '</table>';

http.Response htmlResponse(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
);

http.Response textResponse(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: <String, String>{'content-type': 'text/plain; charset=utf-8'},
);

http.Response jsonResponse(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('normalizeQuery', () {
    test('第N集 + 年份/清晰度噪声 → 剧名与集号', () {
      final q = normalizeSubtitleQuery('繁花.2023.第11集.1080p.WEB-DL.x264-ABC');
      expect(q.title, '繁花');
      expect(q.ep, '11');
    });

    test('S01E10 取集号 E10，且前导零被去掉', () {
      expect(extractEp('Some.Show.S01E10.1080p'), '10');
      expect(extractEp('Show.第01集'), '1');
      expect(extractEp('Show.E07'), '7');
      expect(extractEp('no episode here'), '');
    });

    test('normalizeTitle 去副标题/中文集名', () {
      expect(normalizeTitle('繁花 - 第01集'), '繁花');
      expect(normalizeTitle('繁花 沪语版'), '繁花 沪语版');
    });

    test('titleVariants 去空格变体并截断到 4 条', () {
      final variants = titleVariants('繁花 沪语版');
      expect(variants.first, '繁花 沪语版');
      expect(variants, contains('繁花沪语版'));
      expect(variants, contains('繁花'));
      expect(variants.length, lessThanOrEqualTo(4));
      expect(titleVariants('  '), isEmpty);
    });

    test('buildSearchQuery / animeTitleForQuery', () {
      expect(buildSearchQuery('繁花.2023.第11集.1080p'), '繁花 11');
      expect(animeTitleForQuery('繁花-第1集', '繁花副名'), '繁花副名');
      expect(animeTitleForQuery('繁花-第1集'), '繁花');
    });
  });

  group('SubtitleText.decode', () {
    test('严格 UTF-8 成功 → UTF-8', () {
      final bytes = utf8.encode('字幕：你好');
      expect(SubtitleText.decode(bytes), '字幕：你好');
    });

    test('UTF-8 BOM 被去掉', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('你好')];
      expect(SubtitleText.decode(bytes), '你好');
    });

    // 用固定字节样本而不是 gbk 编码器现场生成：一是让这条用例不再依赖任何
    // GBK 库的初始化（那正是偶发崩溃的来源），二是样本本身就是回归样本。
    test('非 UTF-8 → GBK 兜底', () {
      // “中文字幕测试”的 GBK 字节：D6D0 CEC4 D7D6 C4BB B2E2 CAD4
      const bytes = [
        214,
        208,
        206,
        196,
        215,
        214,
        196,
        187,
        178,
        226,
        202,
        212,
      ];
      expect(utf8.decode(bytes, allowMalformed: true), isNot('中文字幕测试'));
      expect(SubtitleText.decode(bytes), '中文字幕测试');
    });

    test('UTF-16LE BOM', () {
      final bytes = <int>[0xFF, 0xFE, ...utf16leBytes('字幕')];
      expect(SubtitleText.decode(bytes), '字幕');
    });
  });

  group('SRT / ASS / VTT 解析', () {
    test('parseSrt 解析两条 cue（逗号/点毫秒都支持）', () {
      final cues = parseSrt(srtText);
      expect(cues.length, 2);
      expect(cues[0].start, 1.0);
      expect(cues[0].end, 3.5);
      expect(cues[0].text, '你好\n世界');
      expect(cues[1].start, 4.25);
      expect(cues[1].text, 'Hi');
    });

    test('parseAss 去样式/换行转义，并丢弃倒序区间', () {
      final cues = parseAss(assText);
      expect(cues.length, 1);
      expect(cues.first.text, '你好\n世界');
      expect(cues.first.start, 1.0);
      expect(cues.first.end, 3.0);
    });

    test('parseVtt 跳过 NOTE 区块', () {
      const vtt =
          'WEBVTT\n\nNOTE 这是注释\n\n'
          '1\n00:00:01.000 --> 00:00:02.000\n你好\n';
      final cues = parseVtt(vtt);
      expect(cues.length, 1);
      expect(cues.first.text, '你好');
    });

    test('扩展名与内容不符时按内容嗅探', () {
      final cues = parseSubtitleFile('其实是ass的.srt', assText);
      expect(cues.length, 1);
      expect(cues.first.text, '你好\n世界');
    });

    test('shiftCues 穿零钳 0、完全移出丢弃', () {
      final cues = <SubtitleCue>[
        const SubtitleCue(start: 0.5, end: 1.5, text: 'a'),
        const SubtitleCue(start: 1.0, end: 2.0, text: 'b'),
        const SubtitleCue(start: 2.0, end: 3.0, text: 'c'),
      ];
      final shifted = shiftCues(cues, -1.5);
      expect(shifted.length, 2);
      expect(shifted[0].text, 'b');
      expect(shifted[0].start, 0.0);
      expect(shifted[0].end, 0.5);
      expect(shifted[1].start, 0.5);
      expect(shifted[1].end, 1.5);
    });

    test('cuesToSrt 序列化', () {
      final out = cuesToSrt(parseSrt(srtText));
      expect(out, contains('1\r\n00:00:01,000 --> 00:00:03,500\r\n你好\n世界'));
      expect(out, contains('2\r\n00:00:04,250 --> 00:00:06,000'));
    });
  });

  group('压缩包识别 / 挑条目 / 解包', () {
    final zip = buildZip(<String, String>{
      'readme.txt': '这是一个说明文件。' * 10,
      '__MACOSX/._junk': 'x',
      'sub/繁花.EP01.ass': assText,
      'sub/繁花.EP01.srt': srtText,
      'sub/繁花.EP02.srt': srtText,
    });

    test('detectArchiveKind 魔数', () {
      expect(detectArchiveKind(zip), ArchiveKind.zip);
      expect(detectArchiveKind(<int>[0x1f, 0x8b, 1, 2]), ArchiveKind.gz);
      expect(
        detectArchiveKind(<int>[0x52, 0x61, 0x72, 0x21, 0, 0]),
        ArchiveKind.rar,
      );
      expect(detectArchiveKind(utf8.encode('plain')), isNull);
    });

    test('zip 解包 + 按视频名/集号挑 ass', () {
      final entries = extractArchiveEntries(zip);
      expect(entries.length, 5);
      final picked = pickSubtitleEntry<ArchiveEntry>(
        entries,
        opts: const PickOptions(videoName: '繁花.EP01.1080p.mkv', ep: '1'),
      );
      expect(picked, isNotNull);
      expect(picked!.name, endsWith('.ass'));
      expect(extOf(picked.name), 'ass');
      expect(epOf('Show.S01E12.mkv'), '12');
      expect(epOf('Show.EP07.mkv'), '7');
      expect(epOf('Show.第03集.mkv'), '3');
    });

    // 2026-11-16：RAR / 7Z / BZ2 现在通过 koni_archive 异步解包，
    // 同步入口仍会抛（提示改用 async 版）—— 保留这条是为了钉住
    // 「同步 API 不会静默返回空数组」这个契约。
    test('rar/7z/bz2 走异步，同步入口明确提示', () {
      final rar = <int>[0x52, 0x61, 0x72, 0x21, 0, 0];
      expect(
        () => extractArchiveEntries(rar),
        throwsA(
          isA<SubtitleException>().having(
            (e) => e.message,
            'message',
            contains('需要异步解包'),
          ),
        ),
      );
      final sevenZip = <int>[0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 0];
      expect(
        () => extractArchiveEntries(sevenZip),
        throwsA(
          isA<SubtitleException>().having(
            (e) => e.message,
            'message',
            contains('7Z'),
          ),
        ),
      );
    });

    test('subtitleFromBytes：zip → 解压挑条目 → 解码', () {
      final file = subtitleFromBytes(
        zip,
        fileName: '繁花.zip',
        videoName: '繁花.EP01.1080p.mkv',
        ep: '1',
      );
      expect(file.name, endsWith('.ass'));
      expect(file.format, 'ass');
      expect(file.text, contains('你好'));
    });

    test('subtitleFromBytes：纯文本直接解码', () {
      final file = subtitleFromBytes(utf8.encode(srtText), fileName: '繁花.srt');
      expect(file.name, '繁花.srt');
      expect(file.format, 'srt');
      expect(file.text, contains('你好'));
    });
  });

  group('assrt 响应解析', () {
    test('parseAssrtSearch 字段映射', () {
      final list = parseAssrtSearch(assrtSearchJson);
      expect(list.length, 2);
      expect(list[0].providerId, 'assrt');
      expect(list[0].id, '123');
      expect(list[0].title, '繁花');
      expect(list[0].language, '简中');
      expect(list[0].format, 'ass');
      expect(list[0].subname, '繁花.S01E01.1080p.mkv');
      expect(list[1].id, '456');
    });

    test('parseAssrtDetail 取整包与包内直链', () {
      final detail = parseAssrtDetail(assrtDetailJson);
      expect(detail.url, contains('pkg.zip'));
      expect(detail.filename, '繁花.zip');
      expect(detail.direct, endsWith('ep1.ass'));
      expect(detail.directName, '繁花.EP01.ass');
      expect(parseAssrtDetail('{"status":0,"sub":{"subs":[]}}').url, '');
    });

    test('HTTP 400 / 业务错误给中文原因', () {
      expect(
        () => parseAssrtSearch('', statusCode: 400),
        throwsA(
          isA<SubtitleException>().having(
            (e) => e.message,
            'message',
            contains('关键词过短'),
          ),
        ),
      );
      expect(
        () => parseAssrtSearch('{"status":1,"errmsg":"invalid token"}'),
        throwsA(
          isA<SubtitleException>().having(
            (e) => e.message,
            'message',
            contains('invalid token'),
          ),
        ),
      );
    });
  });

  group('SubtitleCat 页面解析', () {
    test('parseCatSearch 只要详情页链接并读统计', () {
      final rows = parseCatSearch(catSearchHtml);
      expect(rows.length, 2);
      expect(rows[0].url, 'https://www.subtitlecat.com/subs/1594/Fan.Hua.html');
      expect(rows[0].name, '繁花');
      expect(rows[0].size, '143 KB');
      expect(rows[0].downloads, 7);
      expect(rows[0].languages, 3);
      expect(rows.any((r) => r.url.endsWith('.srt')), isFalse);
    });

    test('rankCatRows 过滤无关命中、精确命中优先', () {
      final rows = parseCatSearch(catSearchHtml);
      final ranked = rankCatRows(rows, <String>['繁花']);
      expect(ranked.length, 1);
      expect(ranked.first.name, '繁花');
      expect(catRelevant('Other Show', <String>['繁花']), isFalse);
      expect(catRelevant('繁花 Fan Hua', <String>['繁花']), isTrue);
    });

    test('parseCatDetail + pickCatDownload 简中优先', () {
      final rows = parseCatDetail(catDetailHtml);
      expect(rows.length, 2);
      final picked = pickCatDownload(rows);
      expect(picked, isNotNull);
      expect(picked!.label, '简中');
      expect(picked.url, endsWith('-zh-CN.srt'));
      expect(pickCatDownload(const <CatLangRow>[]), isNull);
    });
  });

  group('SubtitleService（MockClient，离线）', () {
    test('无 assrt token → 该源跳过且不发请求', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return textResponse('');
      });
      final service = SubtitleService(
        tokens: () => const <String, String>{},
        client: client,
      );
      final list = await service.search(
        const SubtitleQuery(title: '繁花'),
        providers: const <String>{'assrt'},
      );
      expect(list, isEmpty);
      expect(calls, 0);
    });

    test('SubtitleCat 搜索 + 下载（选择简中直链）', () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/index.php')) return htmlResponse(catSearchHtml);
        if (url.endsWith('.srt')) return textResponse(srtText);
        return htmlResponse(catDetailHtml);
      });
      final service = SubtitleService(
        tokens: () => const <String, String>{},
        client: client,
      );
      final list = await service.search(
        const SubtitleQuery(title: '繁花', episode: 1),
        providers: const <String>{'subtitlecat'},
      );
      expect(list, isNotEmpty);
      expect(list.first.providerId, 'subtitlecat');
      expect(list.first.id, contains('/subs/1594/'));

      final file = await service.download(list.first);
      expect(file.format, 'srt');
      expect(file.name, 'Fan.Hua-zh-CN.srt');
      expect(file.text, contains('你好'));
    });

    test('assrt 搜索 + detail 直链下载', () async {
      final client = MockClient((request) async {
        final url = request.url;
        if (url.host == 'api.assrt.net' && url.path == '/v1/sub/search') {
          return jsonResponse(assrtSearchJson);
        }
        if (url.host == 'api.assrt.net' && url.path == '/v1/sub/detail') {
          return jsonResponse(assrtDetailJson);
        }
        if (url.host == 'file0.assrt.net') return textResponse(assText);
        return http.Response('not found', 404);
      });
      final service = SubtitleService(
        tokens: () => const <String, String>{'assrt': 'token-1'},
        client: client,
      );
      final list = await service.search(
        const SubtitleQuery(
          title: '繁花',
          episode: 1,
          rawName: '繁花.EP01.1080p.mkv',
        ),
        providers: const <String>{'assrt'},
      );
      expect(list, isNotEmpty);
      expect(list.first.id, '123');
      expect(list.first.format, 'ass');

      final file = await service.download(list.first);
      expect(file.name, '繁花.EP01.ass');
      expect(file.format, 'ass');
      expect(file.text, contains('你好'));
    });

    test('单源失败隔离：assrt 500 不影响 SubtitleCat', () async {
      final client = MockClient((request) async {
        final url = request.url;
        if (url.host == 'api.assrt.net') {
          return http.Response('server error', 500);
        }
        if (url.toString().contains('/index.php')) {
          return htmlResponse(catSearchHtml);
        }
        return htmlResponse(catDetailHtml);
      });
      final service = SubtitleService(
        tokens: () => const <String, String>{'assrt': 'bad-token'},
        client: client,
      );
      final list = await service.search(
        const SubtitleQuery(title: '繁花', episode: 1),
        providers: const <String>{'assrt', 'subtitlecat'},
      );
      expect(list, isNotEmpty);
      expect(list.every((c) => c.providerId == 'subtitlecat'), isTrue);
    });

    test('自定义字幕 API：解析配置与模板展开', () {
      final apis = parseCustomSubtitleApis(
        '简体@https://sub.example.com/api?title={title}&ep={episode}\n'
        '# 注释\n'
        '不是地址\n'
        '备用@https://sub.example.com/backup.srt',
      );
      expect(apis.length, 2);
      expect(apis.first.name, '简体');
      expect(apis.first.id, 'custom:0');
      expect(
        customSubtitleUrl(
          apis.first.urlTemplate,
          const SubtitleQuery(title: '繁花', year: 2023, episode: 11),
        ),
        'https://sub.example.com/api?title=%E7%B9%81%E8%8A%B1&ep=11',
      );
    });

    test('自定义字幕 API：JSON 候选 / 直链字幕 / 下载', () async {
      final api = CustomSubtitleApi(
        id: 'custom:0',
        name: '自己的字幕源',
        urlTemplate: 'https://sub.example.com/api?title={title}&ep={episode}',
      );
      const query = SubtitleQuery(title: '繁花', year: 2023, episode: 11);

      final jsonClient = MockClient((request) async {
        if (request.url.path.endsWith('.srt')) {
          return http.Response.bytes(
            utf8.encode(srtText),
            200,
            headers: const {'content-type': 'text/plain; charset=utf-8'},
          );
        }
        return http.Response(
          jsonEncode({
            'results': [
              {
                'url': '/files/1.srt',
                'title': '繁花 简中',
                'language': '简中',
                'format': 'srt',
              },
            ],
          }),
          200,
          headers: _jsonHeaders,
        );
      });
      final jsonHttp = SubtitleHttp(client: jsonClient);
      final candidates = await searchCustomSubtitleApi(jsonHttp, api, query);
      expect(candidates.length, 1);
      expect(candidates.first.providerId, 'custom:0');
      expect(
        candidates.first.downloadUrl,
        'https://sub.example.com/files/1.srt',
      );
      expect(candidates.first.language, '简中');

      final file = await downloadCustomSubtitleApi(
        jsonHttp,
        api,
        candidates.first,
      );
      expect(file.text, contains('你好'));
      expect(file.format, 'srt');

      final directApi = CustomSubtitleApi(
        id: 'custom:1',
        name: '直链源',
        urlTemplate: 'https://sub.example.com/direct.srt',
      );
      final direct = await searchCustomSubtitleApi(jsonHttp, directApi, query);
      expect(direct.length, 1);
      expect(direct.first.format, 'srt');
      final directFile = await downloadCustomSubtitleApi(
        jsonHttp,
        directApi,
        direct.first,
      );
      expect(directFile.text, contains('你好'));
    });

    test('中文候选优先排序', () {
      final sorted = sortSubtitleCandidates(const <SubtitleCandidate>[
        SubtitleCandidate(
          providerId: 'subtitlecat',
          providerName: 'SubtitleCat',
          id: '1',
          title: '繁花',
          language: '英文',
          format: 'srt',
          downloadUrl: '',
        ),
        SubtitleCandidate(
          providerId: 'subtitlecat',
          providerName: 'SubtitleCat',
          id: '2',
          title: '繁花',
          language: '简中',
          format: 'srt',
          downloadUrl: '',
        ),
      ], '繁花');
      expect(sorted.first.language, '简中');
    });
  });
}
