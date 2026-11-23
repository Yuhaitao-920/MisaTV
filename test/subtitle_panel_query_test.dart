import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/subtitle/subtitle_models.dart';
import 'package:kniephos/services/subtitle/subtitle_service.dart';

/// 面板输入框的默认值 + 检索缓存键。
///
/// 两个实测缺陷（2026-11-17）：
///   ① 输入框若直接显示 `query.title`，用户看到「自动推断：奥德赛2026（臻彩）」，
///      会以为标签没去掉；必须是 [SubtitleQuery.effectiveTitle]。
///   ② 检索缓存键若不把 `customKeyword` 算进去，用户改词搜出来的结果
///      会被存到自动推断那个键位上，下次打开面板拿回的是另一批片子。
void main() {
  group('面板输入框默认值', () {
    test('站点标签必须已剥掉', () {
      const q = SubtitleQuery(title: '奥德赛2026（臻彩）', episode: 1);
      expect(q.effectiveTitle, '奥德赛2026');
      expect(q.effectiveTitle, isNot(contains('臻彩')));
    });

    test('用户手填优先且原样使用', () {
      const q = SubtitleQuery(title: '奥德赛2026（臻彩）', customKeyword: '奥德赛');
      expect(q.effectiveTitle, '奥德赛');
    });

    test('title 为空时退回 rawName', () {
      const q = SubtitleQuery(
        title: '',
        rawName: '[1.9GB]S01E02.mkv【L-兰香如故】',
      );
      expect(q.effectiveTitle, '兰香如故');
    });
  });

  group('检索缓存键', () {
    test('改过检索词就不能复用自动推断那批结果', () async {
      final svc = SubtitleService(tokens: () => const <String, String>{});
      // 只验证缓存键这几个维度：这几个 query 都不该命中彼此的缓存。
      const base = SubtitleQuery(title: '奥德赛2026（臻彩）', episode: 1);
      final withCustom = base.withCustomKeyword('奥德赛');
      expect(svc.cachedSearch(base), isNull);
      expect(svc.cachedSearch(withCustom), isNull);
      expect(
        svc.cachedSearch(base) == null && svc.cachedSearch(withCustom) == null,
        isTrue,
      );
    });
  });
}
