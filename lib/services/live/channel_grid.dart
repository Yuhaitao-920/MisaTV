/// 换台菜单频道网格的几何换算。
///
/// 换台菜单要在打开时直接定位到「当前正在看的台」，而列表是懒加载的：
/// 目标项还没被建出来时只能按行高估算偏移，先粗定位到附近，下一帧再精确居中。
/// 估算的关键就是「一行放几个」，算错一个就会落到相邻的台上，所以这部分
/// 单独拎出来，与 Flutter 网格的真实算法对齐并有单测守着。
library;

/// 一行放几个频道卡。
///
/// 必须与 `SliverGridDelegateWithMaxCrossAxisExtent` 的算法一致：
/// `ceil(可用宽度 / (最大格宽 + 列间距))`。少加那个列间距会让列数偏大，
/// 行号随之偏小，定位就会停到当前频道的上一档去。
int channelGridColumns(
  double gridWidth, {
  double maxCrossAxisExtent = 170,
  double crossAxisSpacing = 8,
}) {
  if (!gridWidth.isFinite || gridWidth <= 0) return 1;
  final unit = maxCrossAxisExtent + crossAxisSpacing;
  if (unit <= 0) return 1;
  return (gridWidth / unit).ceil().clamp(1, 64);
}

/// 第 [index] 个频道落在第几行（从 0 开始）。
int channelGridRow(int index, {required int columns}) {
  if (index <= 0) return 0;
  final safe = columns <= 0 ? 1 : columns;
  return index ~/ safe;
}

/// 把第 [index] 个频道滚到可视区中间时，列表应有的偏移。
///
/// [viewportExtent] 是网格可视高度，[cellExtent] / [cellSpacing] 与网格的
/// `mainAxisExtent` / `mainAxisSpacing` 一致。返回值已夹到
/// `[minOffset, maxOffset]`，可以直接喂给 `ScrollController.jumpTo`。
double channelGridOffsetFor({
  required int index,
  required int columns,
  required double viewportExtent,
  required double maxOffset,
  double minOffset = 0,
  double cellExtent = 54,
  double cellSpacing = 8,
}) {
  final row = channelGridRow(index, columns: columns);
  final rowExtent = cellExtent + cellSpacing;
  final target = row * rowExtent - (viewportExtent - cellExtent) / 2;
  final upper = maxOffset < minOffset ? minOffset : maxOffset;
  return target.clamp(minOffset, upper).toDouble();
}
