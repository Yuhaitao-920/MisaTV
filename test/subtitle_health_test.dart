import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/subtitle/pick_entry.dart';
import 'package:kniephos/services/subtitle/subtitle_health.dart';

void main() {
  group('字幕质量体检', () {
    test('AI 摘要字幕（36s/条）判为疑似摘要', () {
      // 实测样本：assrt id=803237，104 条 / 3753 秒
      final buf = StringBuffer();
      var t = 0.0;
      for (var i = 1; i <= 104; i++) {
        final s = t;
        final e = t + 2;
        buf.writeln('$i');
        buf.writeln('${_fmt(s)} --> ${_fmt(e)}');
        buf.writeln('第 $i 句摘要');
        buf.writeln();
        t += 36.1;
      }
      final h = inspectSubtitleHealth(buf.toString());
      expect(h.entries, 104);
      expect(h.averageGapSeconds, greaterThan(30));
      expect(h.isLikelySummary, isTrue);
      expect(h.badge, contains('疑似摘要'));
    });

    test('正常对白字幕（2s/条）不判为摘要', () {
      final buf = StringBuffer();
      for (var i = 1; i <= 50; i++) {
        buf.writeln('$i');
        buf.writeln('${_fmt(i * 2.0)} --> ${_fmt(i * 2.0 + 1.5)}');
        buf.writeln('正常对白 $i');
        buf.writeln();
      }
      final h = inspectSubtitleHealth(buf.toString());
      expect(h.entries, 50);
      expect(h.averageGapSeconds, lessThan(3));
      expect(h.isLikelySummary, isFalse);
      expect(h.badge, isEmpty);
    });

    test('ASS Dialogue 行也能解析', () {
      final ass = '''
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,第一句
Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,第二句
Dialogue: 0,0:00:09.00,0:00:11.50,Default,,0,0,0,,第三句
''';
      final h = inspectSubtitleHealth(ass);
      expect(h.entries, 3);
      // 首句起 1.0s，末句止 11.5s → 跨度 10.5s，2 个间隔 → 5.25s/条
      expect(h.averageGapSeconds, closeTo(5.25, 0.1));
      expect(h.isLikelySummary, isFalse);
    });

    test('空文本 / 无时间轴 → unknown 且不误报', () {
      expect(inspectSubtitleHealth('').entries, 0);
      expect(inspectSubtitleHealth('没有时间轴的一段话').entries, 0);
      expect(inspectSubtitleHealth('').isLikelySummary, isFalse);
      expect(inspectSubtitleHealth('').badge, isEmpty);
    });

    test('少量条目（<5）不给标签，避免误伤', () {
      const two = '''
1
00:00:00,000 --> 00:00:02,000
a

2
00:01:00,000 --> 00:01:02,000
b
''';
      expect(inspectSubtitleHealth(two).badge, isEmpty);
    });
  });

  group('集号提取（决定多集字幕包能否挑对）', () {
    test('S01E03 / EP03 / 第3集', () {
      expect(epOf('Show.S01E03.1080p.mkv'), '3');
      expect(epOf('Show.EP03.1080p.mkv'), '3');
      expect(epOf('剧名.第03集.mp4'), '3');
      expect(epOf('Show.S02E12.2160p.mkv'), '12');
    });

    test('整片/合集名无集号', () {
      expect(
        epOf(
          'Unprotected Murder in Galicia 2026 1080p NF WEB-DL DDP5 1 H 264-SPWEB.chs.srt',
        ),
        '',
      );
      expect(epOf('Some Movie 2026 1080p BluRay.srt'), '');
    });
  });
}

String _fmt(double sec) {
  // 先整体取整到毫秒再拆位：直接 floor 秒 + round 毫秒会产出 ",1000"，
  // 那是非法时间码（解析器会跳过），测试就会少算条目。
  final totalMs = (sec * 1000).round();
  final ms = (totalMs % 1000).toString().padLeft(3, '0');
  final totalS = totalMs ~/ 1000;
  final s = (totalS % 60).toString().padLeft(2, '0');
  final m = ((totalS ~/ 60) % 60).toString().padLeft(2, '0');
  final h = (totalS ~/ 3600).toString().padLeft(2, '0');
  return '$h:$m:$s,$ms';
}
