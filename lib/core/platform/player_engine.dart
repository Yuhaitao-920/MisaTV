// 播放内核注册入口：桌面端启用 fvp（FFmpeg/libmdk），移动端与 Web 使用官方实现。
export 'player_engine_io.dart'
    if (dart.library.js_interop) 'player_engine_web.dart';
