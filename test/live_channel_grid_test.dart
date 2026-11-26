import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/live/channel_grid.dart';

/// 换台菜单打开时要直接定位到当前频道。网格是懒加载的，靠「列数 → 行号 → 偏移」
/// 估算后再精确居中；这里守着换算本身，避免定位跑到相邻的台上。
void main() {
  group('换台网格列数', () {
    test('与 Flutter 的 ceil(宽度 / (格宽 + 列间距)) 一致', () {
      // 960 宽：960 / 178 = 5.39 → 6 列。
      expect(
        channelGridColumns(960, maxCrossAxisExtent: 170, crossAxisSpacing: 8),
        6,
      );
      // 恰好整除时不多算一列。
      expect(
        channelGridColumns(178, maxCrossAxisExtent: 170, crossAxisSpacing: 8),
        1,
      );
      expect(
        channelGridColumns(356, maxCrossAxisExtent: 170, crossAxisSpacing: 8),
        2,
      );
    });

    test('宽度为 0 / 负数 / NaN 时退化为 1 列，不抛错', () {
      expect(channelGridColumns(0), 1);
      expect(channelGridColumns(-10), 1);
      expect(channelGridColumns(double.nan), 1);
      expect(channelGridColumns(double.infinity), 1);
    });

    test('列数上限 64，超宽屏也不会算出离谱的行数', () {
      expect(channelGridColumns(100000), 64);
    });
  });

  group('换台网格行号', () {
    test('按列数整除', () {
      expect(channelGridRow(0, columns: 6), 0);
      expect(channelGridRow(5, columns: 6), 0);
      expect(channelGridRow(6, columns: 6), 1);
      expect(channelGridRow(12, columns: 6), 2);
    });

    test('列数非法时按 1 列处理', () {
      expect(channelGridRow(3, columns: 0), 3);
      expect(channelGridRow(-1, columns: 6), 0);
    });
  });

  group('换台网格偏移', () {
    test('第一行不做负偏移', () {
      final offset = channelGridOffsetFor(
        index: 0,
        columns: 6,
        viewportExtent: 400,
        maxOffset: 1000,
      );
      expect(offset, 0);
    });

    test('当前频道按行居中', () {
      // 第 12 个 → 第 2 行，行高 62，视口 400，格子 54：
      // 2 * 62 - (400 - 54) / 2 = 124 - 173 = -49 → 夹到 0。
      final near = channelGridOffsetFor(
        index: 12,
        columns: 6,
        viewportExtent: 400,
        maxOffset: 1000,
      );
      expect(near, 0);

      // 第 60 个 → 第 10 行：620 - 173 = 447。
      final far = channelGridOffsetFor(
        index: 60,
        columns: 6,
        viewportExtent: 400,
        maxOffset: 1000,
      );
      expect(far, closeTo(447, 0.001));
    });

    test('偏移夹在 [minOffset, maxOffset] 内', () {
      expect(
        channelGridOffsetFor(
          index: 600,
          columns: 6,
          viewportExtent: 400,
          maxOffset: 500,
        ),
        500,
      );
      // maxOffset 比 minOffset 还小时以 minOffset 为准，不产生负区间。
      expect(
        channelGridOffsetFor(
          index: 600,
          columns: 6,
          viewportExtent: 400,
          minOffset: 30,
          maxOffset: 10,
        ),
        30,
      );
    });

    test('自定义行高 / 间距跟着走', () {
      final offset = channelGridOffsetFor(
        index: 4,
        columns: 2,
        viewportExtent: 200,
        maxOffset: 1000,
        cellExtent: 80,
        cellSpacing: 16,
      );
      // 第 2 行：2 * 96 - (200 - 80) / 2 = 192 - 60 = 132。
      expect(offset, closeTo(132, 0.001));
    });
  });
}
