import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/ui/widgets/danmaku_overlay.dart';

DanmakuLine _scroll(double time, [String text = '弹幕']) =>
    DanmakuLine(time: time, type: 'scroll', text: text);

void main() {
  group('弹幕排轨', () {
    test('1/4 屏的轨道数约为全屏的 1/4', () {
      final full = danmakuLaneCount(height: 1080, fontSize: 24, regionRatio: 1);
      final quarter = danmakuLaneCount(
        height: 1080,
        fontSize: 24,
        regionRatio: 0.25,
      );
      expect(full, 33);
      expect(quarter, 8);
      expect(quarter * 4, lessThanOrEqualTo(full + 1));
      expect(danmakuLaneCount(height: 10, fontSize: 24, regionRatio: 0.25), 1);
    });

    test('4K 全屏轨道数不被 40 上限截断', () {
      expect(
        danmakuLaneCount(height: 2160, fontSize: 24, regionRatio: 1),
        greaterThan(40),
      );
      expect(
        danmakuLaneCount(height: 2160, fontSize: 24, regionRatio: 0.25),
        lessThan(40),
      );
    });

    test('滚动弹幕按空轨分配，轨道不足时丢弃而不是重叠', () {
      final items = [for (var i = 0; i < 8; i++) _scroll(i * 0.05)];
      final widths = List<double>.filled(items.length, 100);

      final many = scheduleDanmaku(
        items: items,
        widths: widths,
        width: 1000,
        laneCount: 8,
        speed: 100,
      );
      expect(many.length, 8, reason: '8 条空轨可以各放一条');
      expect(many.first.life, closeTo((1000 + 100) / 100, 1e-9));

      final few = scheduleDanmaku(
        items: items,
        widths: widths,
        width: 1000,
        laneCount: 2,
        speed: 100,
      );
      expect(few.length, 2, reason: '2 条轨道在 0.05s 内只够放两条，其余丢弃');

      // 同一轨道不会重叠：下一条要等上一条的尾巴进屏并留出 24px。
      for (final group in _byLane(many)) {
        for (var i = 1; i < group.length; i++) {
          final prev = group[i - 1];
          final curr = group[i];
          expect(
            curr.start,
            greaterThanOrEqualTo(prev.start + (widths[prev.index] + 24) / 100),
          );
        }
      }
    });

    test('同一批弹幕在 1/4 屏显示的数量明显少于全屏', () {
      final items = [for (var i = 0; i < 60; i++) _scroll(i * 0.1)];
      final widths = List<double>.filled(items.length, 100);
      final full = danmakuLaneCount(height: 1080, fontSize: 24, regionRatio: 1);
      final quarter = danmakuLaneCount(
        height: 1080,
        fontSize: 24,
        regionRatio: 0.25,
      );

      final fullSlots = scheduleDanmaku(
        items: items,
        widths: widths,
        width: 1000,
        laneCount: full,
        speed: 100,
      );
      final quarterSlots = scheduleDanmaku(
        items: items,
        widths: widths,
        width: 1000,
        laneCount: quarter,
        speed: 100,
      );
      expect(quarterSlots.length, lessThan(fullSlots.length));
    });

    test('顶部 / 底部弹幕固定占轨 4 秒，轨道满了就丢弃', () {
      final items = [
        for (var i = 0; i < 5; i++)
          DanmakuLine(time: i * 0.5, type: 'top', text: '顶部$i'),
      ];
      final widths = List<double>.filled(items.length, 80);
      final slots = scheduleDanmaku(
        items: items,
        widths: widths,
        width: 1000,
        laneCount: 10,
        speed: 100,
        fixedLanes: 2,
      );
      expect(slots.length, 2);
      expect(slots.every((s) => s.type == 'top'), isTrue);
      expect(slots.every((s) => s.life == 4), isTrue);
      expect(slots.map((s) => s.lane).toSet().length, 2);
    });

    test('同一轨道后续弹幕要等上一条尾巴进屏，并留出间距', () {
      final items = [_scroll(0), _scroll(0), _scroll(3)];
      final widths = List<double>.filled(items.length, 100);
      final slots = scheduleDanmaku(
        items: items,
        widths: widths,
        width: 1000,
        laneCount: 2,
        speed: 100,
      );
      expect(slots.length, 3);
      final groups = _byLane(slots);
      expect(groups.any((g) => g.length >= 2), isTrue);
      for (final group in groups) {
        for (var i = 1; i < group.length; i++) {
          final prev = group[i - 1];
          final curr = group[i];
          expect(
            curr.start,
            greaterThanOrEqualTo(prev.start + (widths[prev.index] + 24) / 100),
          );
        }
      }
    });

    test('空文本与非法宽度直接跳过', () {
      final items = [_scroll(0, ''), _scroll(1, '正常弹幕')];
      final slots = scheduleDanmaku(
        items: items,
        widths: const [100, 0],
        width: 800,
        laneCount: 4,
        speed: 100,
      );
      expect(slots, isEmpty);
    });
  });
}

List<List<DanmakuSlot>> _byLane(List<DanmakuSlot> slots) {
  final map = <int, List<DanmakuSlot>>{};
  for (final slot in slots) {
    map.putIfAbsent(slot.lane, () => []).add(slot);
  }
  for (final group in map.values) {
    group.sort((a, b) => a.start.compareTo(b.start));
  }
  return map.values.toList();
}
