/// 网盘直链持续低速时是否切换到壳内 `/chunk` 取流。
///
/// 背景（2026-11-18 日志与实测）：夸克/UC/百度直链即使能初始化，也可能长期
/// 只有 1~2 MB/s；大 mkv 会一直缓冲。壳内 serve host 的 `/chunk` 走的是另一条
/// 取流路径，同片实测能到 5~19 MB/s。这里只做判定，真正的换路在播放页完成。
class DriveSlowSwitchPolicy {
  const DriveSlowSwitchPolicy._();

  /// 起播/尾部索引/首次 seek 的宽限期，期间不采样。
  static const Duration warmup = Duration(seconds: 8);

  /// 采样间隔。
  static const Duration sampleInterval = Duration(seconds: 2);

  /// 至少累计多少个样本才允许判定（4 个 ≈ 宽限期后 8 秒）。
  static const int minSamples = 4;

  /// 其中至少多少个样本处于 buffering。
  static const int minStallSamples = 3;

  /// 其中至少多少个样本低于低速阈值。
  static const int minLowSpeedSamples = 3;

  /// 低于该速率视为低速。按 1080p 高码率也够用的下限取 2.5 MB/s；
  /// 4K 高码率通常需要更高，会更容易触发。
  static const double lowSpeedBytesPerSecond = 2.5 * 1024 * 1024;

  static bool shouldSwitch({
    required int samples,
    required int stallSamples,
    required int lowSpeedSamples,
    required bool isDriveCdn,
    required bool isJarSpider,
    required bool alreadyRetried,
  }) {
    if (!isDriveCdn || !isJarSpider || alreadyRetried) return false;
    return samples >= minSamples &&
        stallSamples >= minStallSamples &&
        lowSpeedSamples >= minLowSpeedSamples;
  }
}
