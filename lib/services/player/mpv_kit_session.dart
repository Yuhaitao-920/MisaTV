import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import '../../core/logging/app_log.dart';
import '../../models/player_fit.dart';

/// 内嵌 libmpv（media_kit）播放会话。
///
/// 设计目标：对外暴露与 [VideoPlayerController] 一致的(value/addListener/控制方法)，
/// 让播放页可以在「内置 video_player」与「内嵌 mpv」之间热切换，而复用同一套
/// 进度/音量/倍速/缓冲 UI。内部用 media_kit 的 Player + VideoController，
/// 通过流订阅把状态同步进一个 [VideoPlayerValue]，驱动现有 ValueListenable 逻辑。
class MpvKitSession extends ValueNotifier<VideoPlayerValue> {
  MpvKitSession({required this.headers})
    : _player = Player(
        configuration: const PlayerConfiguration(title: 'MisaTV'),
      ),
      super(const VideoPlayerValue.uninitialized());

  final Map<String, String> headers;
  final Player _player;
  late final VideoController videoController = VideoController(_player);

  /// 用取消闭包保存订阅，规避不同 `Stream<T>` 的 `StreamSubscription<T>` 泛型不匹配。
  final List<Future<void> Function()> _cancelSubs = <Future<void> Function()>[];
  bool _disposed = false;

  // 本地镜像的状态，避免每次都重建 VideoPlayerValue。
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  String? _error;
  double _volume = 1.0;
  double _rate = 1.0;
  Size _size = Size.zero;
  Duration _buffered = Duration.zero;

  /// 原生 mpv 视频输出视图；播放页在 mpv 模式下用它替代 VideoPlayer(controller)。
  ///
  /// media_kit 的 [Video] 默认 `fit: BoxFit.contain`，在横屏上会按视频原始
  /// 宽高比letterbox，出现左右黑边。这里把播放页统一的画面比例设置透传进去，
  /// 默认与内置内核一致使用裁剪填满；同时关掉 media_kit 自带控制条，避免
  /// 与播放页自己的手势/控制栏叠加。
  Widget buildView(PlayerFit fit) {
    final (BoxFit boxFit, double? aspectRatio) = switch (fit) {
      PlayerFit.contain => (BoxFit.contain, null),
      PlayerFit.fill => (BoxFit.fill, null),
      PlayerFit.cover => (BoxFit.cover, null),
      PlayerFit.ratio169 => (BoxFit.contain, 16 / 9),
      PlayerFit.ratio43 => (BoxFit.contain, 4 / 3),
      PlayerFit.original => (BoxFit.none, null),
    };
    return Video(
      controller: videoController,
      fit: boxFit,
      aspectRatio: aspectRatio,
      controls: NoVideoControls,
    );
  }

  Future<void> open(
    String url, {
    Duration startPosition = Duration.zero,
  }) async {
    if (_disposed) return;
    _resetState();
    _bindStreams();
    final media = Media(url, httpHeaders: headers);
    await _player.open(media, play: false);
    await _player.setVolume(_volume * 100);
    await _player.setRate(_rate);
    if (startPosition > Duration.zero) {
      try {
        await _player.seek(startPosition);
      } catch (_) {
        // 直播或不可 seek 的流忽略起播跳转失败。
      }
    }
    await _player.play();
  }

  void _resetState() {
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _buffering = false;
    _completed = false;
    _error = null;
    _size = Size.zero;
    _buffered = Duration.zero;
    _publish();
  }

  void _bindStreams() {
    _cancelAllSubs();
    // 泛型辅助：把任意 Stream<T> 的订阅取消函数统一存起来。
    void listen<T>(Stream<T> stream, void Function(T) onData) {
      final sub = stream.listen(onData);
      _cancelSubs.add(sub.cancel);
    }

    listen(_player.stream.position, (v) {
      _position = v;
      _publish();
    });
    listen(_player.stream.duration, (v) {
      _duration = v;
      _publish();
    });
    listen(_player.stream.playing, (v) {
      _playing = v;
      _publish();
    });
    listen(_player.stream.buffering, (v) {
      _buffering = v;
      _publish();
    });
    listen(_player.stream.completed, (v) {
      _completed = v;
      _publish();
    });
    listen(_player.stream.volume, (v) {
      _volume = (v / 100).clamp(0.0, 1.0);
      _publish();
    });
    listen(_player.stream.rate, (v) {
      _rate = v;
      _publish();
    });
    listen(_player.stream.width, (v) {
      if (v != null && v > 0) {
        _size = Size(v.toDouble(), _size.height);
        _publish();
      }
    });
    listen(_player.stream.height, (v) {
      if (v != null && v > 0) {
        _size = Size(_size.width, v.toDouble());
        _publish();
      }
    });
    listen(_player.stream.buffer, (v) {
      _buffered = v;
      _publish();
    });
    listen(_player.stream.error, (v) {
      if (v.isEmpty) return;
      _error = v;
      AppLog.w('mpv-kit', 'libmpv 报错: $v');
      _publish();
    });
  }

  Future<void> _cancelAllSubs() async {
    final cancels = List<Future<void> Function()>.from(_cancelSubs);
    _cancelSubs.clear();
    for (final cancel in cancels) {
      try {
        await cancel();
      } catch (_) {
        // 取消失败不影响切换
      }
    }
  }

  void _publish() {
    if (_disposed) return;
    final ranges = _buffered > Duration.zero && _duration > Duration.zero
        ? <DurationRange>[
            DurationRange(Duration.zero, _buffered > _duration ? _duration : _buffered),
          ]
        : const <DurationRange>[];
    value = VideoPlayerValue(
      duration: _duration,
      size: _size,
      position: _position,
      buffered: ranges,
      isInitialized: _duration > Duration.zero || _size != Size.zero,
      isPlaying: _playing,
      isBuffering: _buffering,
      volume: _volume,
      playbackSpeed: _rate,
      isCompleted: _completed,
      errorDescription: _error,
    );
  }

  Future<void> play() async {
    if (_disposed) return;
    await _player.play();
  }

  Future<void> pause() async {
    if (_disposed) return;
    await _player.pause();
  }

  Future<void> seekTo(Duration position) async {
    if (_disposed) return;
    try {
      await _player.seek(position);
    } catch (e) {
      AppLog.w('mpv-kit', 'seek 失败: $e');
    }
  }

  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _volume = volume.clamp(0.0, 1.0);
    await _player.setVolume(_volume * 100);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (_disposed) return;
    _rate = speed;
    await _player.setRate(speed);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _cancelAllSubs();
    try {
      await _player.dispose();
    } catch (_) {
      // 释放失败不影响切换
    }
    super.dispose();
  }
}
