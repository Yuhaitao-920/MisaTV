/// 播放下行速率计量：中继 `/play` 每秒真正转发给播放器的字节数。
///
/// 为什么不用 fvp 的 `MediaInfo.bitRate`：
///   · 它是**容器里写的标称码率**，不是实时网速 —— 很多 Remux / WEB 源
///     这个字段是 0，于是「详情」右下角的实时网速永远不显示；
///   · 有值时它也只反映「这段视频有多少 bit/s」，拖动、起播缓冲、
///     从本地边播缓存命中都不会让它变化，看起来像卡住了。
///
/// 中继是播放数据唯一的必经之路（`/play` 把上游字节转发给 fvp），
/// 在这里数字节最准：它就是用户实际拿到的下行速率。
///
/// 纯 Dart、无 io 依赖，Web 端也能编译（Web 版没有中继，永远读到 0）。
class PlaySpeedMeter {
  PlaySpeedMeter._();
  static final PlaySpeedMeter instance = PlaySpeedMeter._();

  /// 累计字节（只增）。用 int 而不是 double，避免长时间播放的精度损失。
  int _total = 0;

  /// 累计转发字节数。播放页用它做「持续低速」判定，避免和
  /// [bytesPerSecond] 的采样窗口互相干扰。
  int get totalBytes => _total;

  /// 上一次采样时的累计值与时刻。
  int _sampleTotal = 0;
  Stopwatch _watch = Stopwatch()..start();

  /// 最近一次算出的速率（字节/秒）。
  double _bytesPerSecond = 0;

  /// 速率采样的最小时间窗：小于它就不重算，避免同一帧内多次读抖动。
  static const int _minWindowMs = 300;

  /// 超过这个时间没有新数据就认为停下来了（切集 / 暂停 / 播放器关掉）。
  static const int _staleMs = 3000;

  /// 中继转发一个分片时调用。
  void add(int bytes) {
    if (bytes <= 0) return;
    _total += bytes;
  }

  /// 播放器换了地址（切集 / 换线路）：累计值归零，避免把上一集的量算进来。
  void reset() {
    _total = 0;
    _sampleTotal = 0;
    _bytesPerSecond = 0;
    _watch = Stopwatch()..start();
  }

  /// 当前速率（字节/秒）；没有流量或已停止返回 0。
  double get bytesPerSecond {
    final elapsed = _watch.elapsedMilliseconds;
    if (elapsed < _minWindowMs) return _bytesPerSecond;
    final delta = _total - _sampleTotal;
    if (delta <= 0) {
      // 这段时间一个字节都没转：要么暂停了，要么播放器已经停下。
      if (elapsed >= _staleMs) _bytesPerSecond = 0;
      return _bytesPerSecond;
    }
    _bytesPerSecond = delta * 1000 / elapsed;
    _sampleTotal = _total;
    _watch = Stopwatch()..start();
    return _bytesPerSecond;
  }

  /// 是否还在流动（UI 用它决定显示「速度」还是「缓冲中」）。
  bool get flowing => _bytesPerSecond > 0;

  /// 上屏文案：`12.3 MB/s` / `860 KB/s` / `0 B/s`。
  String get text {
    final value = bytesPerSecond;
    if (value <= 0) return '';
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (value >= 1024) return '${(value / 1024).round()} KB/s';
    return '${value.round()} B/s';
  }
}
