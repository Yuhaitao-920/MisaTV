import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/local_relay.dart';

/// 上游 Range 夹取（网盘 CDN 跨度限速）。
///
/// 背景（实测）：夸克 / 百度 / UC 的直链 CDN 对**一次请求跨越大**的连接做限速，
/// 同一 URL、同一 Cookie、同一节点，只改 Range 跨度：
///
/// | Range              | 速度      |
/// |--------------------|-----------|
/// | `bytes=0-`（开放式）| 0.10 MB/s |
/// | 跨度 512MB / 2GB   | 0.10 MB/s |
/// | 跨度 350MB         | 4.57 MB/s |
/// | 跨度 256MB         | 7.81 MB/s |
/// | 跨度 128MB         | 9.80 MB/s |
/// | 跨度 32MB          | 12.99 MB/s|
/// | 跨度 16MB / 8MB    | 8.5 / 19.2 MB/s |
///
/// 播放器（fvp / mpv）开场习惯发 `bytes=0-`，正好踩在最差档上，
/// 用户看到的就是「能出画面但极慢、几乎无法播放」。
///
/// **首段另有一档 8MB**（`bytes=0-`）：mkv / mp4 的时长信息在文件尾，
/// 播放器拿到第一批数据后立刻要 seek 到尾部读 Cues/moov。首段跨度越小，
/// 这段等待越短 —— 实测 8MB 档本身还更快（19.2 vs 13.0 MB/s）。
///
/// 实测对照（2026-11-17，玩偶「嫁金钗」夸克原画）：
///   1.2 / 1.89GB 版本正常出画面；
///   5.0 / 5.4 / 5.7GB 版本全部卡到 25 秒 initialize 超时。
void main() {
  const mb = 1024 * 1024;

  group('Range 夹取', () {
    test('首段（start=0）的开放区间夹成 8MB', () {
      expect(LocalRelay.clampRange('bytes=0-'), 'bytes=0-${8 * mb - 1}');
    });

    test('非首段（start>0）的开放区间夹成 32MB', () {
      expect(
        LocalRelay.clampRange('bytes=${100 * mb}-'),
        'bytes=${100 * mb}-${132 * mb - 1}',
      );
    });

    test('首段跨度超过 8MB 的夹到 8MB', () {
      expect(
        LocalRelay.clampRange('bytes=0-${2048 * mb - 1}'),
        'bytes=0-${8 * mb - 1}',
      );
      expect(
        LocalRelay.clampRange('bytes=0-${64 * mb - 1}'),
        'bytes=0-${8 * mb - 1}',
      );
      expect(
        LocalRelay.clampRange('bytes=0-${32 * mb - 1}'),
        'bytes=0-${8 * mb - 1}',
      );
    });

    test('非首段跨度超过 32MB 的夹到 32MB', () {
      expect(
        LocalRelay.clampRange('bytes=${100 * mb}-${2100 * mb - 1}'),
        'bytes=${100 * mb}-${132 * mb - 1}',
      );
    });

    test('首段跨度不超过 8MB 的原样保留', () {
      expect(LocalRelay.clampRange('bytes=0-${7 * mb}'), 'bytes=0-${7 * mb}');
      expect(LocalRelay.clampRange('bytes=0-${8 * mb - 1}'), 'bytes=0-${8 * mb - 1}');
      expect(LocalRelay.clampRange('bytes=0-1023'), 'bytes=0-1023');
      // ffmpeg 的 probesize 请求常在 1MB 上下，不能被放大
      expect(LocalRelay.clampRange('bytes=0-1048575'), 'bytes=0-1048575');
    });

    test('非首段跨度不超过 32MB 的原样保留', () {
      const small = 'bytes=${100 * mb}-${116 * mb - 1}';
      expect(LocalRelay.clampRange(small), small);
      const exact = 'bytes=${100 * mb}-${132 * mb - 1}';
      expect(LocalRelay.clampRange(exact), exact);
    });

    test('无 Range / 空串原样返回（不猜）', () {
      expect(LocalRelay.clampRange(null), isNull);
      expect(LocalRelay.clampRange(''), '');
      expect(LocalRelay.clampRange('   '), '   ');
    });

    test('多区间、后缀形态、非法语法一律原样透传', () {
      const multi = 'bytes=0-1023,2048-3071';
      expect(LocalRelay.clampRange(multi), multi);
      // 后缀形态（文件末尾 N 字节）正是播放器读 moov/Cues 用的，必须原样
      const suffix = 'bytes=-500';
      expect(LocalRelay.clampRange(suffix), suffix);
      const junk = 'items=0-';
      expect(LocalRelay.clampRange(junk), junk);
      const reversed = 'bytes=100-50';
      expect(LocalRelay.clampRange(reversed), reversed);
    });

    test('大小写与空白容错', () {
      expect(LocalRelay.clampRange('  BYTES=0-  '), 'bytes=0-${8 * mb - 1}');
      expect(
        LocalRelay.clampRange('  BYTES=${100 * mb}-  '),
        'bytes=${100 * mb}-${132 * mb - 1}',
      );
    });
    test('clampRange respects totalLength', () { expect(LocalRelay.clampRange('bytes=990763446-', totalLength: 992037521), 'bytes=990763446-992037520'); expect(LocalRelay.clampRange('bytes=0-', totalLength: 1024), 'bytes=0-1023'); });
    });
}
