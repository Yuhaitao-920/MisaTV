// Yaozhi MPV 可选扩展：桌面端按需下载，Web 端不可用。
export 'mpv_extension_io.dart'
    if (dart.library.js_interop) 'mpv_extension_web.dart';
