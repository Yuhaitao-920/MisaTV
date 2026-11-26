import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/subtitle/normalize_query.dart';
import 'package:kniephos/services/subtitle/subtitle_models.dart';
import 'package:kniephos/services/subtitle/subtitle_service.dart';

/// 文件名 → 检索词的「垃圾词」治理。
///
/// 实测（2026-11-17 日志）：
///   兰香如故 rawName = `[1.9GB]S01E02.mkv【L-兰香如故】`
///     → kw=[兰香如故, S01E02 【L, S01E02【L, S01E02, 兰香如故 2]
///   奥德赛 rawName = `[82.2GB]2160p.UHD.Blu-ray.Remux.HDR.HEVC.DTS-HD.MA.5.1.mkv【噢/澳·嘚·噻】`
///     → kw 里混进 `UHD Remux MA 5 1 【噢`
///
/// 这些词都是文件名被 `_noise` 正则切碎后的残片：既搜不到字幕，又要多打
/// 3~4 次 assrt 请求（509 限流就是这么被自己打出来的）。
void main() {
  group('文件名残片不进检索词', () {
    test('兰香如故：只留真剧名', () {
      final q = buildSubtitleContext(
        const SubtitleQuery(
          title: '兰香如故（臻彩）',
          episode: 2,
          rawName: '[1.9GB]S01E02.mkv【L-兰香如故】',
        ),
      );
      expect(q.title, '兰香如故');
      expect(q.keywords, contains('兰香如故'));
      for (final bad in <String>['S01E02 【L', 'S01E02【L', 'S01E02']) {
        expect(q.keywords, isNot(contains(bad)), reason: '文件名残片「$bad」不该当检索词');
      }
    });

    test('奥德赛：画质/编码残片不进检索词', () {
      final q = buildSubtitleContext(
        const SubtitleQuery(
          title: '奥德赛2026（臻彩）',
          episode: 1,
          rawName: '[82.2GB]2160p.UHD.Blu-ray.Remux.HDR.HEVC.DTS-HD.MA.5.1.mkv【噢/澳·嘚·噻】',
        ),
      );
      expect(q.title, '奥德赛2026');
      expect(q.keywords, contains('奥德赛'));
      for (final kw in q.keywords) {
        expect(
          RegExp(r'[\[\]【】()（）]').hasMatch(kw),
          isFalse,
          reason: '检索词「$kw」带括号残片',
        );
        expect(
          RegExp(
            r'^(UHD|Remux|Blu|Bluray|HDR|HEVC|DTS|MA)$',
            caseSensitive: false,
          ).hasMatch(kw),
          isFalse,
          reason: '检索词「$kw」是纯画质词',
        );
      }
    });

    test('关键词数量有上限且不重复', () {
      final q = buildSubtitleContext(
        const SubtitleQuery(
          title: '人性本兽（真彩）',
          episode: 1,
          rawName: '人性本兽.Animals.2026.2160p.WEB.h265.mkv',
        ),
      );
      expect(q.keywords.length, lessThanOrEqualTo(6));
      expect(q.keywords.toSet().length, q.keywords.length);
    });

    test('纯数字片名不被当残片丢掉', () {
      for (final name in <String>['1917', '2012']) {
        expect(isJunkSubtitleKeyword(name), isFalse, reason: name);
        final q = buildSubtitleContext(SubtitleQuery(title: name));
        expect(q.keywords, contains(name));
      }
    });

    test('残片词被识别', () {
      for (final bad in <String>[
        'S01E02 【L',
        'UHD Remux MA 5 1 【噢',
        'S01E02',
        'UHD',
        'Remux',
      ]) {
        expect(isJunkSubtitleKeyword(bad), isTrue, reason: bad);
      }
    });
  });

  group('集号不能吃容量/分辨率', () {
    test('容量方括号里的数字不是集号', () {
      expect(
        extractEp('[82.2GB]2160p.UHD.Blu-ray.Remux.HDR.HEVC.mkv'),
        isNot('82'),
      );
      expect(extractEp('[1.9GB]S01E02.mkv'), '2');
    });

    test('音频声道 / 位深不是集号', () {
      expect(extractEp('DTS-HD.MA.5.1.mkv'), isNot('5'));
      expect(extractEp('movie.10bit.2160p.mkv'), isNot('10'));
    });

    test('真正的集号仍然认得出', () {
      expect(extractEp('Some.Show.S01E10.1080p'), '10');
      expect(extractEp('Show.第07集'), '7');
      expect(extractEp('Show.E12'), '12');
    });
  });
}
