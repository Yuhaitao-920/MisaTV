import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/live.dart';
import 'package:kniephos/services/live/epg.dart';
import 'package:kniephos/services/live/epg_service.dart';
import 'package:kniephos/services/live/live_export.dart';

const _xml = '''
<tv>
  <channel id="cctv1"><display-name>CCTV-1</display-name><icon src="http://x/logo.png"/></channel>
  <channel id="cctv2"><display-name>央视二套</display-name></channel>
  <programme channel="cctv1" start="20260101120000 +0800" stop="20260101130000 +0800"><title>新闻30分</title></programme>
  <programme channel="cctv1" start="20260101130000 +0800" stop="20260101140000 +0800"><title>今日说法</title></programme>
  <programme channel="cctv2" start="20260101120000 +0800" stop="20260101130000 +0800"><title>经济半小时</title></programme>
</tv>
''';

void main() {
  group('XMLTV 时间', () {
    test('时区偏移解析', () {
      expect(parseTzOffset('Z'), 0);
      expect(parseTzOffset('+0800'), 480);
      expect(parseTzOffset('-05:30'), -330);
      expect(parseTzOffset('+09'), 540);
      expect(parseTzOffset('bad'), isNull);
    });

    test('带偏移 / Z / 时区 / 本机四种口径', () {
      final utc = DateTime.utc(2026, 1, 1, 4).millisecondsSinceEpoch;
      expect(parseXmltvEpoch('20260101120000 +0800'), utc);
      expect(
        parseXmltvEpoch('20260101120000Z'),
        DateTime.utc(2026, 1, 1, 12).millisecondsSinceEpoch,
      );
      expect(parseXmltvEpoch('20260101120000', timeZone: 'Asia/Shanghai'), utc);
      expect(
        parseXmltvEpoch('20260101120000'),
        DateTime(2026, 1, 1, 12).millisecondsSinceEpoch,
      );
    });

    test('非法时间返回 null', () {
      expect(parseXmltvEpoch(''), isNull);
      expect(parseXmltvEpoch('20261301120000 +0800'), isNull);
      expect(parseXmltvEpoch('20260101120000 XYZ'), isNull);
    });
  });

  group('parseXmltv / buildEpgMap', () {
    test('解析频道与节目，按 tvg-id / 名称 / display-name 匹配', () {
      final parsed = parseXmltv(_xml);
      expect(parsed.channels.length, 2);
      expect(parsed.channels.first.id, 'cctv1');
      expect(parsed.channels.first.names, ['CCTV-1']);
      expect(parsed.channels.first.icon, 'http://x/logo.png');
      expect(parsed.programmes.length, 3);

      final refs = [
        const EpgChannelRef(tvgId: 'cctv1', name: 'CCTV1'),
        const EpgChannelRef(name: '央视二套'),
        const EpgChannelRef(name: '没有节目单'),
      ];
      final map = buildEpgMap([parsed], refs, timeZone: 'Asia/Shanghai');
      expect(map['cctv1']?.length, 2);
      expect(map['CCTV1']?.length, 2);
      expect(map['央视二套']?.length, 1);
      expect(map['没有节目单'], isNull);
      expect(map['cctv1']!.first.title, '新闻30分');
    });

    test('同一节目按（起止, 标题）去重', () {
      final map = buildEpgMap(
        [parseXmltv(_xml), parseXmltv(_xml)],
        [const EpgChannelRef(tvgId: 'cctv1', name: 'CCTV1')],
      );
      expect(map['cctv1']?.length, 2);
    });

    test('非法 XML 返回空结果', () {
      final parsed = parseXmltv('<tv><channel></tv>');
      expect(parsed.channels, isEmpty);
      expect(parsed.programmes, isEmpty);
    });
  });

  group('当前 / 下一档', () {
    test('落在区间内取当前，之后取下一档', () {
      final map = buildEpgMap(
        [parseXmltv(_xml)],
        [const EpgChannelRef(tvgId: 'cctv1', name: 'CCTV1')],
      );
      final programs = lookupEpg(
        map,
        const EpgChannelRef(tvgId: 'cctv1', name: 'CCTV1'),
      )!;
      final at = DateTime.utc(
        2026,
        1,
        1,
        4,
        30,
      ).millisecondsSinceEpoch; // 12:30 +0800
      final entry = pickCurrentNext(programs, at);
      expect(entry.current?.title, '新闻30分');
      expect(entry.next?.title, '今日说法');

      final entries = buildEpgEntries(map, at);
      expect(
        entryOf(
          entries,
          const EpgChannelRef(tvgId: 'cctv1', name: 'CCTV1'),
        )?.current?.title,
        '新闻30分',
      );
    });

    test('无节目表返回空 entry', () {
      final entry = pickCurrentNext(null, 0);
      expect(entry.hasData, isFalse);
    });
  });

  group('collectEpgUrls', () {
    test('只保留 http(s) 且含 xml/gz 的地址并去重', () {
      final urls = collectEpgUrls(
        'http://a/e.xml, http://a/e.xml, http://a/e.xml.gz, http://a/e.json, https://x/{date}.xml',
        const [
          EpgChannelRef(name: 'CCTV1', epg: 'http://b/ch.xml'),
          EpgChannelRef(name: 'CCTV2', epg: 'ftp://b/ch.xml'),
        ],
      );
      expect(urls, ['http://a/e.xml', 'http://a/e.xml.gz', 'http://b/ch.xml']);
    });
  });

  group('LiveExport', () {
    const groups = [
      LiveGroup(
        group: '央视',
        channels: [
          LiveChannel(name: 'CCTV1', urls: ['http://a/1.m3u8']),
          LiveChannel(
            name: 'CCTV2',
            urls: ['http://a/2.m3u8', 'http://a/2b.m3u8'],
          ),
          LiveChannel(name: '空频道', urls: []),
        ],
      ),
      LiveGroup(group: '空分组', channels: []),
    ];

    test('TXT：分组,#genre# + 每线路一行，末尾 CRLF', () {
      expect(
        LiveExport.renderTxt(groups),
        '央视,#genre#\r\nCCTV1,http://a/1.m3u8\r\nCCTV2,http://a/2.m3u8\r\nCCTV2,http://a/2b.m3u8\r\n',
      );
    });

    test('M3U：保留 tvg 信息并按线路展开', () {
      final text = LiveExport.renderM3u(groups);
      expect(text, startsWith('#EXTM3U\r\n'));
      expect(
        text,
        contains(
          '#EXTINF:-1 tvg-id="" tvg-name="" tvg-logo="" group-title="央视",CCTV1\r\nhttp://a/1.m3u8',
        ),
      );
      expect(text, contains('CCTV2\r\nhttp://a/2b.m3u8'));
      expect(text, isNot(contains('空频道')));
    });

    test('空分组返回空串；文件名过滤非法字符', () {
      expect(LiveExport.renderTxt(const []), '');
      expect(LiveExport.renderM3u(const []), '');
      expect(
        LiveExport.suggestedName('我的:线路?', '20261028', 'txt'),
        '我的_线路__20261028.txt',
      );
    });
  });
}
