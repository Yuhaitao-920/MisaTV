/// 把 `assets://xxx` / `clan://localhost/xxx` 换算出 Flutter 打包资产键
/// `assets/xxx`。
///
/// 返回 null 表示这不是内置资产引用（普通 http(s) / file:// 都返回 null）。
///
/// ★ 抽成独立文件是为了能单测。它决定一个源「去读内置脚本」还是「当网络地址
///   下载」，判错的代价是整个源在 8 毫秒内失败 —— 而且报出来的是
///   `Unsupported scheme 'assets' in URI` 这种对用户毫无意义的 Dart 内部错误。
///
/// 实测来源（2026-11-17 12:35:35 日志）：
///
/// ```
/// [E][source] home key=hipy_js_好趣网 type=3 8ms
///   api=assets://bhdc/宝盒/lib/drpy2.min.js
///   error=Invalid argument(s): Unsupported scheme 'assets' in URI
/// ```
///
/// 这类源来自 CatVod / TVBox 离线包，`assets://` 和 `clan://localhost/` 是同一个
/// 东西的两种写法，都指包内资源。真机路径可能还带 `;md5;xxx` 校验尾缀或
/// `?name=x` 查询串，都要剥掉才是资产键。
String? bundleAssetKeyOf(String api) {
  final raw = api.trim();
  if (raw.isEmpty) return null;
  final lower = raw.toLowerCase();
  const assetsPrefix = 'assets://';
  const clanPrefix = 'clan://localhost/';
  String? relative;
  if (lower.startsWith(assetsPrefix)) {
    relative = raw.substring(assetsPrefix.length);
  } else if (lower.startsWith(clanPrefix)) {
    relative = raw.substring(clanPrefix.length);
  }
  if (relative == null) return null;
  // 去掉 query 与 `;md5;xxx` 校验尾缀，只留文件路径。
  final head = relative.split('?').first;
  final path = head.split(';').first.replaceAll('\\', '/');
  final cleaned = path.startsWith('/') ? path.substring(1) : path;
  if (cleaned.isEmpty) return null;
  return 'assets/$cleaned';
}
