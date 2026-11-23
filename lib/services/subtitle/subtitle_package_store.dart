/// 字幕包缓存的落盘层（条件导入：io / 空实现）。
///
/// 目的：**重启 app 后仍然不用重复下载同一个字幕包**。
///
/// 为什么不用 shared_preferences 存整包字幕：
///   · 一条 srt 100~300KB，4 条就 1MB，塞进 prefs 的 JSON 会拖慢每次读写；
///   · prefs 不合适存大块文本。
/// 所以直接落盘到 `<userdata>/subtitles/cache/<key>.json`。
library;

export 'subtitle_package_store_stub.dart'
    if (dart.library.io) 'subtitle_package_store_io.dart';
