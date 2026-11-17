import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/subtitle/normalize_query.dart';

/// 站点常见的「线路标签」后缀必须剥掉，否则 assrt 精确匹配搜不到。
///
/// 实测：`枕边杀局（臻彩）` → 0 条；`枕边杀局` → 1 条（id=803237）。
void main() {
  group('剧名标签剥离', () {
    test('中文括号里的线路标签', () {
      expect(normalizeTitle('枕边杀局（臻彩）'), '枕边杀局');
      expect(normalizeTitle('枕边杀局(4K)'), '枕边杀局');
      expect(normalizeTitle('枕边杀局【HDR】'), '枕边杀局');
    });

    test('裸标签词也剥', () {
      expect(normalizeTitle('枕边杀局 臻彩'), '枕边杀局');
      expect(normalizeTitle('枕边杀局 原画'), '枕边杀局');
      expect(normalizeTitle('枕边杀局 HDR10+'), '枕边杀局');
    });

    test('正常剧名不受影响', () {
      expect(normalizeTitle('枕边杀局'), '枕边杀局');
      expect(normalizeTitle('繁花'), '繁花');
      expect(normalizeTitle('走向共和'), '走向共和');
    });

    test('带清晰度 + 语言标签', () {
      expect(normalizeTitle('枕边杀局.2026.1080p.国语中字.mp4'), '枕边杀局');
    });
  });
  group('括号段保守剥离（不能误伤剧名本身）', () {
    test('外文原名括号要保留', () {
      // 剥掉就搜不到日文原名对应的字幕
      expect(normalizeTitle('Legal High (リーガルハイ)'), 'Legal High (リーガルハイ)');
    });

    test('版本区分括号要保留', () {
      // 剥掉会搜到别的版本
      expect(normalizeTitle('三体（腾讯版）'), '三体（腾讯版）');
    });

    test('集数说明括号要剥', () {
      expect(normalizeTitle('长安十二时辰（48集全）'), '长安十二时辰');
      expect(normalizeTitle('剧名（全12集）'), '剧名');
    });
  });

  group('年份不能被误吃（原有 bug）', () {
    test('剧名自带年份不能剥', () {
      // `\b(19|20)\d{2}\b` 在 CJK 前也成立，原实现把《请回答1988》截成《请回答》
      expect(normalizeTitle('请回答1988'), '请回答1988');
    });

    test('独立出现的年份要剥', () {
      expect(normalizeTitle('枕边杀局 2026'), '枕边杀局');
      expect(normalizeTitle('Show 2024 1080p'), 'Show');
    });

    test('数字结尾的剧名不受影响', () {
      expect(normalizeTitle('流浪地球2'), '流浪地球2');
      expect(normalizeTitle('长安十二时辰'), '长安十二时辰');
    });
  });
}