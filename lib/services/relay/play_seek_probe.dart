/// 播放器读盘行为的观测：按「文件总长」分桶，各自独立判定。
///
/// 存在的唯一目的：识别「播放器在纯顺序读、从不 seek 到文件尾」这种病态模式。
///
/// 为什么需要它（2026-11-17 实测，玩偶「嫁金钗」[6.0GB]E08.mkv，夸克直链）：
///
/// ```
/// 18:50:41  开始打开
/// 18:50:41  Range bytes=0-          → 8MB
/// 18:50:42  Range bytes=8388608-    → +32MB
/// 18:50:45  Range bytes=41943040-   → +32MB
/// …         每 2~3 秒推进 32MB
/// 18:51:06  打开失败 TimeoutException after 0:00:25
/// ```
///
/// mkv 的 Cues 索引在文件尾 6.42GB 处，读不到索引就没有首帧，只能一直顺扫。
/// 作为对照，同一部剧的 mp4（1.3GB）第二个请求就是 `bytes=1398159625-`
/// （正好文件尾），968ms 就出画面。
///
/// ★ 演变历史（三次踩坑，全部记在这里防止再犯）
///
/// **第一版：用 URL 作 key → 一次都没触发**
///
///   中继记的是**上游**地址（`dl-pc-zb.drive.quark.cn/…`），播放页拿的是
///   **中继**地址（`http://127.0.0.1:9978/play?url=…`）。两者 `keyOf` 出来的
///   字符串永远不相等，看门狗每次读到的都是空记录（实测 2026-11-17 全天
///   `判定为纯顺序读` 出现 0 次）。
///
/// **第二版：全局单例 + 「start==0 就重置」→ 多实例互相清零**
///
///   连点几集时旧实例还在读，新实例的第一个 `start==0` 把整份记录清空；
///   再连点一次又被清空，`elapsed` 永远到不了阈值。实测 2026-11-18：
///   单独播放时 13:15 / 13:16 / 13:31 正常判死，而 13:23 连续切三集全部
///   走满 25 秒超时。
///
/// **第三版：滑动时间窗口 → 换路后立刻被旧样本误判死**
///
///   换成时间窗口后没有「清零」了，但换路那一刻窗口里积压的还是旧的直链
///   样本：实测 14:00:47 `/chunk` 只发了 1 条请求，窗口里 10 条里 9 条是
///   直链的，判据照样成立 → 刚打开 250 毫秒就被判死。
///
/// **现在：按「文件总长」分桶 + 只看最后写入的那个桶**
///
///   不同文件的总长天然不同，用它当分组键，两条流交错写入时互不污染：
///   上一集的 298MB 偏移不会抬高这一集的 `maxStart`，两个文件的总长也不会
///   混在一起算百分比。
///
///   活跃桶取「最后写入的那个」而不是「样本最多的」：连点换集时旧那一集的
///   样本还在累积（它的播放器没立刻断），条数往往比刚打开的新文件更多 ——
///   实测 14:09 E04 的 9 条压过 E06 的 3 条，看门狗盯着旧文件判，E06 自己
///   走满 25 秒。
class PlaySeekProbe {
  PlaySeekProbe._();
  static final PlaySeekProbe instance = PlaySeekProbe._();

  /// 样本存活上限。超过这么久的老记录对「刚才这几秒在读什么」没有意义。
  static const Duration _window = Duration(seconds: 30);

  /// 单个桶内的样本上限。真在顺读时几秒就有十几条，128 条绰绰有余。
  static const int _maxPerBucket = 128;

  /// 最多保留几个桶（同时播放的文件数，正常最多 2~3 个）。
  static const int _maxBuckets = 8;

  /// `总长 → 样本列表`。不同文件按总长天然分开。
  final Map<int, List<({int start, DateTime at})>> _buckets = {};

  /// 最后一次 `noteRange` 写入的文件总长（= 当前正在读的文件）。
  int _lastTotal = 0;

  /// 记一条上游 Range 结果。
  ///
  /// [start] 是本次请求的起始偏移，[total] 取自 Content-Range 的 `/总长`。
  /// [total] <= 0 时不记 —— 没有总长就算不出百分比，记了也没用。
  ///
  /// ★ 这里既不做「start==0 就清空」，也不跨文件共享：靠分桶隔离。
  void noteRange({required int start, required int total}) {
    if (start < 0 || total <= 0) return;
    final now = DateTime.now();
    _lastTotal = total;
    final list = _buckets.putIfAbsent(total, () => []);
    list.add((start: start, at: now));
    final cutoff = now.subtract(_window);
    var drop = 0;
    while (drop < list.length && list[drop].at.isBefore(cutoff)) {
      drop++;
    }
    if (drop > 0) list.removeRange(0, drop);
    if (list.length > _maxPerBucket) {
      list.removeRange(0, list.length - _maxPerBucket);
    }
    _pruneBuckets();
  }

  /// 桶太多时淘汰样本最少的 —— 但**绝不淘汰刚写入的那个**。
  ///
  /// 少了这层保护，新文件的第一条样本会被当成「样本最少」立刻淘汰，
  /// 于是它永远攒不够 3 条（这个坑写测试时才暴露）。
  void _pruneBuckets() {
    if (_buckets.length <= _maxBuckets) return;
    final candidates = _buckets.keys.where((k) => k != _lastTotal).toList()
      ..sort((a, b) => _buckets[a]!.length.compareTo(_buckets[b]!.length));
    final need = _buckets.length - _maxBuckets;
    for (final k in candidates.take(need)) {
      _buckets.remove(k);
    }
  }

  /// 清空全部桶（换片 / 换线路时调用）。
  void reset() {
    _buckets.clear();
    _lastTotal = 0;
  }

  /// 活跃桶里的样本列表（只读）。
  List<({int start, DateTime at})> get _active =>
      _buckets[_lastTotal] ?? const [];

  int get requests => _active.length;

  /// 活跃文件的总长。
  int get total => _lastTotal;

  /// 活跃文件里读到过的最大偏移。
  int get maxStart {
    var max = 0;
    for (final s in _active) {
      if (s.start > max) max = s.start;
    }
    return max;
  }

  /// 活跃文件里是否摸过尾部（>80% 位置）。
  bool get tailTouched {
    final size = total;
    if (size <= 0) return false;
    for (final s in _active) {
      if (s.start > size * 0.8) return true;
    }
    return false;
  }

  /// 活跃桶里第一条到最后一条的跨度。
  Duration get span {
    final list = _active;
    if (list.length < 2) return Duration.zero;
    return list.last.at.difference(list.first.at);
  }

  bool get hasData => requests > 0 && total > 0;

  /// 是否像「只顺读、不 seek 尾部」的病态模式。
  ///
  /// 判据全部基于活跃桶（最后写入的那个文件）：
  ///   · ≥3 条请求；
  ///   · 窗口跨度至少 [minSpan]（默认 2.5 秒）；
  ///   · 从没摸过尾部；
  ///   · 最大偏移不到总长的 [progressLimit]（默认 5%）。
  ///
  /// [progressLimit] 为什么是 5% 而不是 20%（2026-11-17 23:25 实测）：
  ///
  ///   ```
  ///   E08 6.0GB  maxStart=41,943,040  total=6,422,075,667  = 0.65%  → 该判死
  ///   E17 1.4GB  maxStart=243,269,632 total=1,483,631,041  = 16.4%  → 误判
  ///   ```
  ///
  ///   E17 只有 1.4GB，一路顺读也能在几秒内读到尾，本来能正常播。20% 会把
  ///   它也算成病态，白换一次壳内取流。真正读不动的都在 1% 以内。
  bool looksSequentialOnly({
    Duration minSpan = const Duration(milliseconds: 2500),
    double progressLimit = 0.05,
  }) {
    if (!hasData || requests < 3) return false;
    if (span < minSpan) return false;
    if (tailTouched) return false;
    return maxStart < total * progressLimit;
  }

  @override
  String toString() =>
      'bucket=$total requests=$requests maxStart=$maxStart '
      'tail=$tailTouched span=${span.inMilliseconds}ms '
      'buckets=${_buckets.length}';
}
