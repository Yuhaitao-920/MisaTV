import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/subtitle/normalize_query.dart';
import 'package:kniephos/services/subtitle/subtitle_models.dart';
import 'package:kniephos/services/subtitle/subtitle_service.dart';

void main() {
  group('字幕检索上下文', () {
    test('纯标题 → 干净关键词', () {
      final q = normalizeSubtitleQuery('枕边杀局');
      expect(q.title, '枕边杀局');
      expect(q.ep, '');
    });

    test('带容量/清晰度/语言标签 → 只留剧名', () {
      final q = normalizeSubtitleQuery('枕边杀局.2026.1080p.国语中字.mp4');
      expect(q.title, '枕边杀局');
    });

    test('剧集名 + 集号', () {
      final q = normalizeSubtitleQuery('繁花.2023.第11集.1080p.WEB-DL.x264-ABC');
      expect(q.title, '繁花');
      expect(q.ep, '11');
    });
  });

  group('字幕搜索失败必须留痕', () {
    test('单源异常不抛出，但结果是空列表（不影响其它源）', () async {
      // 用无效 token 触发 assrt 报错，验证 search 不抛整体失败
      final svc = SubtitleService(tokens: () => const {'assrt': 'invalid'});
      final items = await svc.search(
        SubtitleQuery(title: '枕边杀局', episode: 1),
        providers: const {'assrt'},
      );
      expect(items, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}