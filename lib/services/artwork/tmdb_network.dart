/// TMDB 域名在网络层被「DNS 污染」时的诊断工具。
///
/// 实测（2026-11，中国大陆常见网络）：`api.themoviedb.org` 会被解析到 Facebook 的
/// 网段（`157.240.x.x`、`69.63.x.x`、`2a03:2880::/32`）或内网/保留地址，
/// 连过去自然握手超时——报「网络请求失败」但看日志只有 TimeoutException。
/// 这里只做纯判断与文案，真正的解析/请求在调用方做。
library;

/// 疑似被污染 / 明显不可用的地址。
bool looksLikePoisonedAddress(String address) {
  final ip = address.trim().toLowerCase();
  if (ip.isEmpty) return false;
  // 保留 / 本机 / 链路本地 / 测试网段：不可能承载 TMDB。
  if (ip == '0.0.0.0' || ip == '::' || ip == '::1') return true;
  if (ip.startsWith('127.') || ip.startsWith('10.')) return true;
  if (ip.startsWith('192.168.') || ip.startsWith('169.254.')) return true;
  if (ip.startsWith('198.18.') || ip.startsWith('198.19.')) return true;
  // Facebook 网段：GB 级 DNS 污染的典型返回。
  if (ip.startsWith('157.240.')) return true;
  if (RegExp(r'^69\.63\.').hasMatch(ip)) return true;
  if (RegExp(r'^2a03:2880:').hasMatch(ip)) return true;
  if (ip.startsWith('31.13.')) return true;
  return false;
}

/// TMDB 图床前缀，按顺序回退：官方 → 公共镜像 → 备用域名。
///
/// 国内网络下 `image.tmdb.org` 经常被阻断；镜像与备用域名走同一套
/// `/t/p/<size>/<file>` 路径，由本地 `/img` 中继在回源失败时自动换下一个。
const List<String> kTmdbImagePrefixes = [
  'https://image.tmdb.org/t/p/',
  'https://tmdb-image.nocorp.space/t/p/',
  'https://tmdb.org/t/p/',
];

/// 拼一张 TMDB 图片地址（默认原图，[size] 可传 `w780` 等）。
String tmdbImageUrl(String path, {String size = 'original'}) {
  final clean = path.trim();
  if (clean.isEmpty) return '';
  if (clean.startsWith('http')) return clean;
  final normalized = clean.startsWith('/') ? clean : '/$clean';
  return '${kTmdbImagePrefixes.first}$size$normalized';
}

/// 给定一张 TMDB 图地址，返回全部可用图床（官方在前）。
///
/// 只识别 `/t/p/<size>/<file>` 形态；非 TMDB 地址返回空列表，调用方按原地址请求。
List<String> tmdbImageMirrors(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return const [];
  final host = uri.host.toLowerCase();
  final isTmdb =
      host == 'tmdb.org' ||
      host == 'image.tmdb.org' ||
      host == 'tmdb-image.nocorp.space' ||
      host.endsWith('.tmdb.org');
  if (!isTmdb) return const [];
  const marker = '/t/p/';
  final index = uri.path.indexOf(marker);
  if (index < 0) return const [];
  final rest = uri.path.substring(index + marker.length);
  if (rest.isEmpty) return const [];
  final suffix = uri.hasQuery ? '?${uri.query}' : '';
  final out = <String>[];
  for (final prefix in kTmdbImagePrefixes) {
    final url = '$prefix$rest$suffix';
    if (!out.contains(url)) out.add(url);
  }
  return out;
}

/// 给用户看的一句话诊断。
///
/// [addresses] 是直连解析到的地址；[proxyActive] 表示当前是否已经在走代理。
String describeTmdbDns({
  required List<String> addresses,
  required bool proxyActive,
}) {
  if (proxyActive) {
    return '当前已走代理，域名由代理远端解析。';
  }
  final usable = addresses.where((a) => !looksLikePoisonedAddress(a)).toList();
  if (addresses.isEmpty) {
    return '解析不到 api.themoviedb.org 的任何地址：当前网络 DNS 有问题，改用代理即可绕过。';
  }
  if (usable.isEmpty) {
    return '当前网络把 api.themoviedb.org 解析到 ${addresses.take(2).join('、')}（Facebook/保留地址，典型 DNS 污染），'
        '直连必然超时。请在 Clash / v2rayN 打开「系统代理」后到 设置 → 播放 → 网络代理 开启「跟随系统代理」，'
        '或直接填写手动代理端口。';
  }
  return '解析到 ${usable.take(2).join('、')}，域名本身没被污染；若仍超时请检查代理是否在运行。';
}
