import '../core/logging/app_log.dart';
import '../core/logging/log_redact.dart';
import '../core/net/app_http.dart';
import '../models/vod.dart';

/// 播放地址是否明显是图片（封面 / 截图 / 图床变换模板）而不是视频。
///
/// 少数源把海报地址当播放地址返回（如 `~tplv-xxx-image.image`）；交给
/// fvp/libmdk 会黑屏，个别机器还会在原生图像解码路径上直接闪退。
/// 这类地址在打开播放器前拦下并提示换线路，比让原生内核去试更可控。
bool looksLikeImageMediaUrl(String raw) {
  final path = Uri.tryParse(raw.trim())?.path.toLowerCase() ?? '';
  if (path.isEmpty) return false;
  const suffixes = <String>[
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.avif',
    '.svg',
    '.ico',
    '.image',
  ];
  return suffixes.any(path.endsWith);
}

/// 云播线路（`hnyun` / `mtyun` / `dbyun` 等）返回的通常是 HTML 播放/分享页，
/// 例如 `/play/<id>`、`/share/<hash>`；播放器拿到网页只会报 invalid media。
/// 这里把页面里内嵌的 m3u8 直链提取出来，再交给播放器。
class PlayPageUnwrap {
  PlayPageUnwrap(this._http);

  final AppHttp _http;
  final Map<String, String> _cache = {};
  final Set<String> _failed = {};

  /// 网盘 CDN 直链的路径通常没有扩展名（靠 query 里的 token 鉴权），
  /// 不能按「无扩展名 = 播放页」去抓取：整集文件会被 getText 拉下来并超时。


  /// 只有疑似播放页/分享页才需要抓取；带媒体扩展名的直链直接放行。
  ///
  /// ★ 网盘 CDN 直链必须放行：它们的路径是「一长串 hex 段 + 文件名哈希」，
  ///   没有扩展名，会被下面「无扩展名 → 当成播放页」的兜底误判。
  ///   误判的代价是**每次播放/换集都白抓一次**（10 秒超时），实测日志里
  ///   15 次「云播页面解析失败」间隔精确等于 10.0 秒。
  static bool needsUnwrap(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return false;
    }
    // 网盘 CDN 直链直接放行（名单见 _driveCdnSuffixes，覆盖上游原
    // _directDownloadHosts 的全部条目并多 5 个）。
    if (_isDriveCdnHost(host)) return false;
    final path = uri.path.toLowerCase();
    const media = [
      '.m3u8',
      '.mp4',
      '.flv',
      '.mkv',
      '.ts',
      '.mpd',
      '.mov',
      '.avi',
      '.webm',
      '.m4a',
      '.mp3',
    ];
    if (media.any(path.endsWith)) return false;
    if (path.contains('/play/') ||
        path.contains('/share/') ||
        path.contains('/player/') ||
        path.contains('/vodplay/')) {
      return true;
    }
    // 无扩展名的路径（不含 .php 这类接口）也当作可能的播放页。
    return !path.contains('.');
  }

  /// 网盘 CDN 取流主机：直链本身就是媒体流，抓成 HTML 解析毫无意义。
  ///
  /// 判定用「域名后缀 + 主机名前缀」，不列全量主机 —— 夸克/百度/UC 的
  /// CDN 节点是按地域动态下发的（`dl-pc-zb` / `dl-pc-zb-j` / `dl-pc-sz` /
  /// `dl-pc-bj` …），写死具体节点迟早漏。
  static bool _isDriveCdnHost(String host) {
    for (final suffix in _driveCdnSuffixes) {
      // 裸域（`drive.uc.cn`）与子域（`dl-pc-sz.drive.uc.cn`）都要命中：
      // 只写 endsWith('.$suffix') 会漏掉裸域，实测 drive.uc.cn 因此被判成
      // 「需要抓取的播放页」，每次播放白等一次 10 秒超时。
      if (host == suffix || host.endsWith('.$suffix')) return true;
    }
    return false;
  }

  /// 这个播放地址是不是网盘 CDN（夸克 / UC / 百度 …）的直链。
  ///
  /// 供播放页判断「初始化超时后该不该改用壳内 `/chunk` 重取」：这类直链经
  /// libmdk 打开大 mkv 时会纯顺读、拿不到尾部 Cues，而同一份数据经壳的
  /// `/chunk` 能秒开（实测记录见 `JarSpiderService.replayViaServe`）。
  static bool isDriveCdnUrl(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return _isDriveCdnHost(host);
  }

  /// 会触发「跨度限速」、且壳内 `/chunk` 通常更快的网盘取流域名。
  ///
  /// 只用于持续低速自动换路；115 / 阿里 / 天翼等没有这套实测数据，不参与，
  /// 避免把本来正常的播放打断。
  static bool isRangeThrottledDriveCdn(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return host.contains('drive.quark.cn') ||
        host.contains('drive.uc.cn') ||
        host.contains('pcs.baidu.com') ||
        host.contains('baidupcs.com');
  }

  /// 网盘取流域名后缀（含前导点，按后缀匹配）。
  static const _driveCdnSuffixes = <String>[
    'drive.quark.cn', // 夸克 / UC 下载节点：dl-pc-*.drive.quark.cn
    'drive.uc.cn', // UC 下载节点（裸域 drive.uc.cn 与子域都存在）
    'pcs.baidu.com', // 百度 PCS：d.pcs.baidu.com / c.pcs.baidu.com
    'baidupcs.com', // 百度 PCS 备用域
    'bcebos.com', // 百度云对象存储 / CDN
    'aliyundrive.com', // 阿里云盘
    'alipan.com', // 阿里云盘（新域）
    '123pan.com', // 123 云盘
    '189.cn', // 天翼云盘
    '115.com', // 115 网盘
    'xunlei.com', // 迅雷
    'ctyunxs.cn', // 天翼云盘取流
  ];

  /// 从页面源码里提取 m3u8 / mp4 直链，优先 `main` / `vid` 这类主清单变量。
  static String? extractMediaUrl(String html, String pageUrl) {
    final text = html.replaceAll(r'\/', '/');
    final assigned = RegExp(
      r'(?:var|let|const)\s+(?:main|vid|url|videoUrl)\s*=\s*["\x27]([^"\x27]+)["\x27]',
      caseSensitive: false,
    ).firstMatch(text);
    if (assigned != null) {
      final abs = _absolute(assigned.group(1)!, pageUrl);
      if (abs != null) return abs;
    }
    final absolute = RegExp(
      r'https?://[^"\x27<>\s\\]+?\.(?:m3u8|mp4)(?:\?[^"\x27<>\s\\]*)?',
      caseSensitive: false,
    ).firstMatch(text);
    if (absolute != null) return absolute.group(0);
    final relative = RegExp(
      r'["\x27](/[^"\x27<>\s\\]*?\.(?:m3u8|mp4)(?:\?[^"\x27<>\s\\]*)?)["\x27]',
      caseSensitive: false,
    ).firstMatch(text);
    if (relative != null) return _absolute(relative.group(1)!, pageUrl);
    return null;
  }

  static String? _absolute(String value, String pageUrl) {
    final v = value.trim();
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    if (!v.startsWith('/')) return null;
    try {
      return Uri.parse(pageUrl).resolve(v).toString();
    } catch (_) {
      return null;
    }
  }

  Future<PlayResult> unwrap(PlayResult play) async {
    if (play.parse != 0 || !play.playable) return play;
    final url = play.url.trim();
    if (!needsUnwrap(url)) return play;
    final cached = _cache[url];
    if (cached != null) return _withUrl(play, cached);
    // 解析过一次没结果的页面不再重复抓，避免每集都卡十秒。
    if (_failed.contains(url)) return play;
    try {
      final res = await _http.probeText(
        url,
        headers: play.headers,
        timeout: const Duration(seconds: 10),
        maxBytes: 512 << 10,
        skipBinaryMedia: true,
      );
      if (res != null) {
      final type = res.contentType.toLowerCase();
      // 本身已经是清单或媒体流：原地址可以直接播。
      if (type.contains('mpegurl') ||
                type.startsWith('video/') ||
          type.startsWith('audio/') || 
          type.contains('octet-stream') ||
          res.body.isEmpty ||
          res.body.trimLeft().startsWith('#EXTM3U')) {
        return play;
      }
      final extracted = extractMediaUrl(res.body, url);
      if (extracted != null && extracted != url) {
        _remember(url, extracted);
        AppLog.i('play', '云播页面解出直链 ${redactUrl(extracted)}');
        return _withUrl(play, extracted);
      }
      }
    } catch (e) {
      AppLog.w('play', '云播页面解析失败 ${redactUrl(url)}', e);
    }
    // `/play/<id>` 这类页面有时源码里没有直链，但补 `/index.m3u8` 就是清单。
    final fallback = _indexUrl(url);
    if (fallback != null) {
      try {
        final res = await _http.probeText(
          fallback,
          headers: play.headers,
          timeout: const Duration(seconds: 8),
          maxBytes: 256 << 10,
          skipBinaryMedia: true,
        );
        if (res != null) {
        final type = res.contentType.toLowerCase();
        if (type.contains('mpegurl') ||
            res.body.trimLeft().startsWith('#EXTM3U')) {
          _remember(url, fallback);
          AppLog.i('play', '云播页面补 /index.m3u8 成功 ${redactUrl(fallback)}');
          return _withUrl(play, fallback);
        }
        }
      } catch (_) {
        // 补路径也失败：保持原地址，让播放器给出明确错误
      }
    }
    _rememberFailed(url);
    return play;
  }

  static String? _indexUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.path.isEmpty) return null;
    final path = uri.path.endsWith('/')
        ? '${uri.path}index.m3u8'
        : '${uri.path}/index.m3u8';
    return uri.replace(path: path).toString();
  }

  void _remember(String pageUrl, String mediaUrl) {
    if (_cache.length >= 200) _cache.clear();
    _cache[pageUrl] = mediaUrl;
  }

  void _rememberFailed(String pageUrl) {
    if (_failed.length >= 200) _failed.clear();
    _failed.add(pageUrl);
  }

  PlayResult _withUrl(PlayResult play, String url) {
    return PlayResult(
      url: url,
      flag: play.flag,
      headers: play.headers,
      message: play.message,
    );
  }
}
