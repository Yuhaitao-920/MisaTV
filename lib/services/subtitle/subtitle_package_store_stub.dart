/// 字幕包缓存落盘的 Web / 兜底实现：什么都不做。
///
/// 条件导入的默认分支（`if (dart.library.io)` 不成立时用它）。
/// Web 版没有本地文件系统，缓存只留在内存里。
library;

/// 注入 support 目录（io 版才会用到，这里空实现）。
void configurePackageStore(String supportDirPath) {}

/// 落盘键 → JSON 文本（读不到返回 null）。
String? readPackageCache(String key) => null;

/// 把 JSON 文本写到 [key]（失败静默）。
void writePackageCache(String key, String json) {}

/// 删掉全部缓存（容量清理用）。
void clearPackageCacheFiles() {}

/// 当前缓存目录（Web 无目录，恒为 null）。
String? packageCacheDirPath() => null;
