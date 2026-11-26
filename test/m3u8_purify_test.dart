// test/m3u8_purify_test.dart — m3u8 去广告（TVBox `M3u8.purify` 移植）的纯函数回归。
//
// 覆盖五级链路与三道回退：① 主导路径前缀/域名删少数派；② 订阅 rules regex 整段删/数字型 scan；
// ③ SCTE-35 / CUE-OUT~CUE-IN / DATERANGE；④ EXTINF 小数精度短块；⑤ 帧率特征短块；
// 回退：单级 >30% 作废 / 累计 >50% 整体回退 / 清洗后不可播整体回退。另测 VOD 闸门与 host 规则匹配。
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/m3u8_purify.dart';

const String base = 'https://cdn.example.com/hls/index.m3u8';

/// 拼一份清单（每行一段，段用 `名字` + 时长）
String build(List<String> lines) => '${lines.join('\n')}\n';

List<String> seg(String name, [String dur = '6.0']) => <String>[
  '#EXTINF:$dur,',
  name,
];

String num(int i) => i.toString().padLeft(4, '0');

void main() {
  group('purifyM3u8 — ① 主导路径前缀删少数派', () {
    test('主流切片区段数占优（≥80%）→ 删掉异前缀的少数派，其余原样保留', () {
      final lines = <String>['#EXTM3U', '#EXT-X-TARGETDURATION:8'];
      for (var i = 0; i < 10; i++) {
        lines.addAll(seg('live_${num(i)}.ts'));
      }
      lines.add('#EXT-X-DISCONTINUITY');
      lines.addAll(seg('other_0000.ts'));
      lines.addAll(seg('other_0001.ts'));
      lines.add('#EXT-X-ENDLIST');

      final r = purifyM3u8(build(lines), base)!;
      expect(r.removed, 2);
      expect(r.text.contains('other_0000.ts'), isFalse);
      expect(r.text.contains('live_0009.ts'), isTrue);
      expect(r.text.contains('#EXT-X-ENDLIST'), isTrue);
    });

    test('单级删除超过总段数 30% → 该级作废（回退原文，删 0 段）', () {
      final lines = <String>['#EXTM3U'];
      for (var i = 0; i < 10; i++) {
        lines.addAll(seg('live_${num(i)}.ts'));
      }
      // 6/16 = 37.5% > 30%
      for (var i = 0; i < 6; i++) {
        lines.addAll(seg('other_${num(i)}.ts'));
      }
      lines.add('#EXT-X-ENDLIST');
      final src = build(lines);
      final r = purifyM3u8(src, base)!;
      expect(r.removed, 0);
      // 该级作废后仍会走 resolve 归一 → 只断言「一段没删」
      expect(r.text.contains('other_0005.ts'), isTrue);
      expect(r.text.contains('live_0000.ts'), isTrue);
    });
  });

  group('purifyM3u8 — ② 订阅 rules 整段删', () {
    test('数字型规则（首段时长前缀匹配）→ 删掉该不连续块', () {
      final src = build(<String>[
        '#EXTM3U',
        '#EXT-X-TARGETDURATION:6',
        ...seg('main_000.ts', '10.0'),
        '#EXT-X-DISCONTINUITY',
        ...seg('ad_000.ts', '5.76'),
        '#EXT-X-DISCONTINUITY',
        ...seg('main_001.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      final r = purifyM3u8(src, base, rules: <String>['5.76'])!;
      expect(r.removed, 1);
      expect(r.text.contains('ad_000.ts'), isFalse);
      expect(r.text.contains('main_000.ts'), isTrue);
      expect(r.text.contains('main_001.ts'), isTrue);
    });

    test('带 DISCONTINUITY 的规则 → 整段（含标签）删', () {
      final src = build(<String>[
        '#EXTM3U',
        ...seg('main_000.ts', '10.0'),
        '#EXT-X-DISCONTINUITY',
        ...seg('ad_000.ts', '5.0'),
        '#EXT-X-DISCONTINUITY',
        ...seg('main_001.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      final r = purifyM3u8(
        src,
        base,
        rules: <String>[r'#EXT-X-DISCONTINUITY[\s\S]*?#EXT-X-DISCONTINUITY'],
      )!;
      expect(r.removed, 1);
      expect(r.text.contains('ad_000.ts'), isFalse);
    });

    test('订阅规则语法不兼容（非法正则）→ 跳过该条，不中断整链', () {
      final src = build(<String>[
        '#EXTM3U',
        ...seg('seg_0001.ts', '10.0'),
        ...seg('seg_0002.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      final r = purifyM3u8(
        src,
        base,
        rules: <String>['#EXT-X-DISCONTINUITY[unclosed'],
      )!;
      expect(r.removed, 0);
    });
  });

  group('purifyM3u8 — ③ SCTE-35 / CUE-OUT~CUE-IN / DATERANGE', () {
    test('CUE-OUT~CUE-IN 之间的段整段删', () {
      final src = build(<String>[
        '#EXTM3U',
        ...seg('seg_0001.ts', '10.0'),
        '#EXT-X-CUE-OUT:30',
        ...seg('seg_0002.ts', '10.0'),
        '#EXT-X-CUE-IN',
        ...seg('seg_0003.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      final r = purifyM3u8(src, base)!;
      expect(r.removed, 1);
      expect(r.text.contains('seg_0002.ts'), isFalse);
      expect(r.text.contains('seg_0001.ts'), isTrue);
      expect(r.text.contains('seg_0003.ts'), isTrue);
    });

    test('DATERANGE 广告标记（ad-break）整条删', () {
      final src = build(<String>[
        '#EXTM3U',
        '#EXT-X-DATERANGE:ID="1",CLASS="ad-break",START-DATE="2026-01-01T00:00:00Z"',
        ...seg('seg_0001.ts', '10.0'),
        ...seg('seg_0002.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      final r = purifyM3u8(src, base)!;
      expect(r.removed, greaterThanOrEqualTo(1));
      expect(r.text.contains('ad-break'), isFalse);
      expect(r.text.contains('seg_0002.ts'), isTrue);
    });
  });

  group('purifyM3u8 — ④ EXTINF 小数精度短块', () {
    test('主流 2 位小数、广告块 3 位小数（≤12 段且非末组）→ 删该块', () {
      // 全部同路径前缀，避免①先动手；由④真正命中 3 小时长精度块。
      final lines = <String>['#EXTM3U'];
      for (var i = 0; i < 10; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '6.00'));
      }
      lines.add('#EXT-X-DISCONTINUITY');
      for (var i = 10; i < 13; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '6.006'));
      }
      lines.add('#EXT-X-DISCONTINUITY');
      for (var i = 13; i < 15; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '6.00'));
      }
      lines.add('#EXT-X-ENDLIST');

      final r = purifyM3u8(build(lines), base)!;
      expect(r.removed, 3);
      expect(r.text.contains('seg_0010.ts'), isFalse);
      expect(r.text.contains('seg_0012.ts'), isFalse);
      expect(r.text.contains('seg_0014.ts'), isTrue);
    });
  });

  group('purifyM3u8 — ⑤ 帧率特征短块', () {
    test('主流段对齐 30fps（2.002）、广告块对齐 25fps（5.12）→ 删该块', () {
      final lines = <String>['#EXTM3U'];
      for (var i = 0; i < 4; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '2.002'));
      }
      lines.add('#EXT-X-DISCONTINUITY');
      for (var i = 4; i < 6; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '5.12'));
      }
      lines.add('#EXT-X-DISCONTINUITY');
      for (var i = 6; i < 10; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '2.002'));
      }
      lines.add('#EXT-X-ENDLIST');

      final r = purifyM3u8(build(lines), base)!;
      expect(r.removed, 2);
      expect(r.text.contains('seg_0004.ts'), isFalse);
      expect(r.text.contains('seg_0005.ts'), isFalse);
      expect(r.text.contains('seg_0009.ts'), isTrue);
    });
  });

  group('purifyM3u8 — 三道回退', () {
    test('累计删除超过总段数 50% → 整体回退原文', () {
      final lines = <String>['#EXTM3U'];
      for (var i = 0; i < 6; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '10.0'));
      }
      lines.add('#EXT-X-CUE-OUT:120');
      // 10/16 = 62.5%
      for (var i = 6; i < 16; i++) {
        lines.addAll(seg('seg_${num(i)}.ts', '10.0'));
      }
      lines.add('#EXT-X-CUE-IN');
      lines.add('#EXT-X-ENDLIST');
      final src = build(lines);

      final r = purifyM3u8(src, base)!;
      expect(r.removed, 0);
      expect(r.text, src);
    });

    test('清洗后不可播（留下两个连续 EXTINF）→ 整体回退原文', () {
      final src = build(<String>[
        '#EXTM3U',
        ...seg('seg_ad0.ts', '10.0'), // 规则命中：EXTINF + 分片一起删
        ...seg('seg_x0.ts', '10.0'), // 规则命中：只删分片行、留下悬空 EXTINF
        ...seg('seg_0001.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      // 规则里带 `#EXTINF` → 走 scanAd 整段删路径；第二条只覆盖分片 URI，制造「连续两个 EXTINF」
      const rule =
          '#EXTINF:10\\.0,\nhttps://[^\\n]*seg_ad0[^\\n]*|https://[^\\n]*seg_x0[^\\n]*\\.ts';

      final r = purifyM3u8(src, base, rules: const <String>[rule])!;
      expect(r.removed, 0);
      expect(r.text, src);
    });
  });

  group('purifyM3u8 — 适用性与安全性', () {
    test('非 m3u8（不以 #EXTM3U 开头 / 空）→ null（不适用）', () {
      expect(purifyM3u8('', base), isNull);
      expect(purifyM3u8(null, base), isNull);
      expect(purifyM3u8('<html>no</html>', base), isNull);
    });

    test('没有广告的清单 → 删 0 段（内容不动，绝不误删）', () {
      final src = build(<String>[
        '#EXTM3U',
        ...seg('seg_0001.ts', '10.0'),
        ...seg('seg_0002.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      final r = purifyM3u8(src, base)!;
      expect(r.removed, 0);
      expect(r.text.contains('seg_0001.ts'), isTrue);
      expect(r.text.contains('seg_0002.ts'), isTrue);
    });

    test('BOM 开头的清单也能处理', () {
      final src =
          '\ufeff${build(<String>['#EXTM3U', ...seg('seg_0001.ts', '10.0'), ...seg('seg_0002.ts', '10.0'), '#EXT-X-ENDLIST'])}';
      expect(purifyM3u8(src, base)?.removed, 0);
    });
  });

  group('purifyVodM3u8 — VOD 闸门（对位 TVBox 只在点播路径调用）', () {
    test('直播清单（无 ENDLIST）→ null（不参与清洗）', () {
      final live = build(<String>[
        '#EXTM3U',
        ...seg('seg_0001.ts', '10.0'),
        ...seg('seg_0002.ts', '10.0'),
      ]);
      expect(purifyVodM3u8(live, base), isNull);
    });

    test('点播清单（含 ENDLIST）→ 正常清洗', () {
      final vod = build(<String>[
        '#EXTM3U',
        ...seg('seg_0001.ts', '10.0'),
        '#EXT-X-CUE-OUT:30',
        ...seg('seg_0002.ts', '10.0'),
        '#EXT-X-CUE-IN',
        ...seg('seg_0003.ts', '10.0'),
        '#EXT-X-ENDLIST',
      ]);
      expect(purifyVodM3u8(vod, base)?.removed, 1);
    });
  });

  group('hostRegexFor / isAd', () {
    final rules = <dynamic>[
      <String, dynamic>{
        'host': 'other.com',
        'regex': <String>['1.23'],
      },
      <String, dynamic>{
        'host': 'cdn.example.com',
        'regex': <String>[
          r'#EXT-X-DISCONTINUITY[\s\S]*?#EXT-X-DISCONTINUITY',
          '5.76',
        ],
      },
      <String, dynamic>{
        'host': 'cdn.example.com',
        'regex': <String>['never-used'],
      },
    ];

    test('按播放地址命中第一个 host（且该条带 regex）→ 返回其规则表', () {
      expect(hostRegexFor(base, rules), <String>[
        r'#EXT-X-DISCONTINUITY[\s\S]*?#EXT-X-DISCONTINUITY',
        '5.76',
      ]);
    });

    test('没有命中 host / 没有 rules → 空数组', () {
      expect(hostRegexFor('https://nope.com/a.m3u8', rules), isEmpty);
      expect(hostRegexFor(base, null), isEmpty);
      expect(hostRegexFor(base, <dynamic>[]), isEmpty);
    });

    test('isAd：含 DISCONTINUITY/EXTINF 的规则或数字规则算广告规则', () {
      expect(isAd(r'#EXT-X-DISCONTINUITY[\s\S]*?#EXT-X-DISCONTINUITY'), isTrue);
      expect(isAd('#EXTINF:5.0,'), isTrue);
      expect(isAd('5.76'), isTrue);
      expect(isAd('abc'), isFalse);
      expect(isAd('0'), isFalse);
    });
  });
}
