// 独立播放器子窗口的启动入口：桌面端完整实现，Web 端为空操作。
export 'player_window_io.dart'
    if (dart.library.js_interop) 'player_window_web.dart';
