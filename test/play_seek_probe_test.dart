import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/play_seek_probe.dart';

/// 顺读看门狗的判据。
///
/// 这个类踩过三次坑，测试就是为了让第四次不再发生：
///
/// **坑 1：用 URL 作 key → 一次都没触发**
///   中继记上游地址，播放页拿中继地址，`keyOf` 出来永远不相等。
///
/// **坑 2：全局单例 + 「start==0 就重置」→ 多实例互相清零**
///   连点几集时每个实例进来 reset 一次，`elapsed` 永远到不了阈值。
///   实测 2026-11-18 13:23 连续切三集全部走满 25 秒超时。
///
/// **坑 3：滑动时间窗口 → 换路后立刻被旧样本误判死**
///   14:00:47 `/chunk` 只发了 1 条请求，但窗口里 9 条是旧直链的样本，
///   判据照样成立 → 刚打开 250 毫秒就被判死。
///
/// **现在：按文件总长分桶**，两条流交错写入互不污染。
void main() {
  final probe = PlaySeekProbe.instance;

  setUp(probe.reset);

  Future<void> feed(
    List<int> starts, {
    required int total,
    int gapMs = 900,
  }) async {
    for (final s in starts) {
      probe.noteRange(start: s, total: total);
      if (gapMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: gapMs));
      }
    }
  }

  group('认清病态顺读', () {
    test('E08 真实序列（6.0GB，25 秒只走到 3%）→ 必须判死', () async {
      await feed(
        [0, 8388608, 41943040, 75497472, 109051904, 142606336, 176160768],
        total: 6422075667,
        gapMs: 600,
      );
      expect(probe.requests, greaterThanOrEqualTo(3));
      expect(probe.tailTouched, isFalse);
      expect(probe.looksSequentialOnly(), isTrue);
    });

    test('★ 两个文件交错写入，互不污染（第三次踩的坑）', () async {
      // 旧片 E04：5.7GB，已经读到 298MB
      const oldTotal = 5666283048;
      // 新片 E06：5.7GB 但**总长不同**，刚从 0 开始
      const newTotal = 5712345678;
      probe.noteRange(start: 298169621, total: oldTotal);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      probe.noteRange(start: 0, total: newTotal);
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      probe.noteRange(start: 8388608, total: newTotal);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      probe.noteRange(start: 331724053, total: oldTotal);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      probe.noteRange(start: 41943040, total: newTotal);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      probe.noteRange(start: 365278485, total: oldTotal);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      probe.noteRange(start: 75497472, total: newTotal);

      // 活跃桶应当是样本更多的那个：新片 4 条 vs 旧片 3 条
      expect(probe.total, newTotal, reason: '活跃桶应取最后写入的那个');
      expect(probe.requests, 4);
      expect(probe.maxStart, 75497472, reason: '旧片的 365MB 不该抬高新片的 maxStart');
      expect(
        probe.looksSequentialOnly(),
        isTrue,
        reason: '新片从 0 到 75MB 顺读 4 条 —— 必须判死',
      );
    });

    test('★ 旧样本不该让新文件被判死（坑 3 的复现）', () async {
      const oldTotal = 6422075667; // 6.0GB
      const newTotal = 5666283048; // 5.3GB
      // 旧文件攒 9 条顺读样本
      for (var i = 0; i < 9; i++) {
        probe.noteRange(start: i * 33554432, total: oldTotal);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      // 新文件只发 1 条（`/chunk` 刚打开）
      probe.noteRange(start: 0, total: newTotal);
      expect(
        probe.looksSequentialOnly(),
        isFalse,
        reason: '新文件只有 1 条请求，不该被旧文件的 9 条带着判死',
      );
      // 新文件攒够 3 条后再判
      probe.noteRange(start: 8388608, total: newTotal);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      probe.noteRange(start: 41943040, total: newTotal);
      expect(probe.total, newTotal);
      expect(probe.requests, 3);
    });
  });

  group('不误伤能播的片', () {
    test('1.3GB mp4：第二个请求就到文件尾 → 不误判', () async {
      await feed([0, 1398159625, 145209], total: 1398160593, gapMs: 300);
      expect(probe.tailTouched, isTrue);
      expect(probe.looksSequentialOnly(), isFalse);
    });

    test('82.2GB Remux：会跳到尾部读 Cues → 不误判', () async {
      await feed(
        [0, 88246890315, 7369, 88246039476],
        total: 88246893816,
        gapMs: 300,
      );
      expect(probe.tailTouched, isTrue);
      expect(probe.looksSequentialOnly(), isFalse);
    });

    test('1.4GB E17：走过 16.4% → 不判死（20% 阈值的老误判）', () async {
      await feed(
        [0, 8388608, 41943040, 75497472, 243269632],
        total: 1483631041,
        gapMs: 700,
      );
      expect(probe.looksSequentialOnly(), isFalse);
    });

    test('请求太少（<3 条）不下结论', () async {
      await feed([0, 8388608], total: 6422075667, gapMs: 1500);
      expect(probe.looksSequentialOnly(), isFalse);
    });

    test('窗口跨度不够（<2.5 秒）不下结论', () async {
      await feed([0, 8388608, 41943040], total: 6422075667, gapMs: 100);
      expect(probe.looksSequentialOnly(), isFalse);
    });

    test('没有 Content-Range（total=0）时不记样本', () async {
      await feed([0, 8388608, 41943040], total: 0, gapMs: 700);
      expect(probe.hasData, isFalse);
      expect(probe.looksSequentialOnly(), isFalse);
    });
  });

  group('桶管理', () {
    test('reset 清空全部桶', () async {
      await feed([0, 8388608, 41943040], total: 6422075667, gapMs: 100);
      await feed([0, 8388608], total: 5666283048, gapMs: 0);
      expect(probe.requests, greaterThan(0));
      probe.reset();
      expect(probe.requests, 0);
      expect(probe.total, 0);
    });

    test('桶数超上限时淘汰样本最少的，但不动刚写入的那个', () async {
      for (var i = 1; i <= 10; i++) {
        for (var j = 0; j < i; j++) {
          probe.noteRange(start: j * 1024 * 1024, total: i * 1000000000);
        }
      }
      // 活跃桶 = 最后写入的第 10 个（10 条样本），必须完整保留
      expect(probe.requests, 10, reason: '刚写入的桶不能被淘汰');
      expect(probe.total, 10 * 1000000000);
    });

    test('新文件第一条样本不会被当成「样本最少」淘汰掉', () async {
      // 先塞满 8 个桶
      for (var i = 1; i <= 8; i++) {
        for (var j = 0; j < 5; j++) {
          probe.noteRange(start: j * 1024 * 1024, total: i * 1000000000);
        }
      }
      // 新文件只来 1 条（`/chunk` 刚打开）
      probe.noteRange(start: 0, total: 999 * 1000000000);
      expect(probe.requests, 1, reason: '新文件的唯一一条必须留住');
      expect(probe.total, 999 * 1000000000);
    });
  });
}
