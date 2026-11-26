import 'dart:convert';

import 'package:xml/xml.dart';

/// PROPFIND 请求体：只问展示需要的几个属性。
const String propfindBody =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/><d:getcontenttype/>'
    '</d:prop></d:propfind>';

/// 归一服务器基址：去空白与尾斜杠。
String normalizeDavBase(String url) =>
    (url).trim().replaceAll(RegExp(r'/+$'), '');

/// 基址 + 服务器路径 → 可请求的绝对 URL（逐段编码，中文/空格文件名安全）。
///
/// `path` 为 `/` 或空时只返回基址。
String davJoin(String base, String path) {
  final b = normalizeDavBase(base);
  final segments = (path.trim().isEmpty ? '/' : path)
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((s) => Uri.encodeComponent(s))
      .toList();
  return segments.isEmpty ? b : '$b/${segments.join('/')}';
}

/// Basic 认证头值（无用户名则空串）。
String davBasicAuth(String username, String password) {
  final u = username.trim();
  if (u.isEmpty) return '';
  return 'Basic ${base64Encode(utf8.encode('$u:$password'))}';
}

/// PROPFIND 应答里的一行原始数据。
class DavRawEntry {
  const DavRawEntry({
    required this.href,
    required this.displayName,
    required this.isDir,
    required this.size,
    required this.mtime,
  });

  /// 原始 href（可能是绝对 URL 或绝对路径）。
  final String href;
  final String displayName;
  final bool isDir;
  final int size;

  /// 原始 Last-Modified 串（RFC1123）。
  final String mtime;
}

String _elementText(XmlElement element) => element.innerText.trim();

XmlElement? _childElement(XmlElement parent, String localName) {
  for (final child in parent.childElements) {
    if (child.localName.toLowerCase() == localName) return child;
  }
  return null;
}

/// 取 `propstat` 里状态 200 的那份 `prop`（没有 200 时退第一份）。
XmlElement? _firstProp(XmlElement response) {
  XmlElement? fallback;
  for (final child in response.childElements) {
    if (child.localName.toLowerCase() != 'propstat') continue;
    final prop = _childElement(child, 'prop');
    if (prop == null) continue;
    final status = _childElement(child, 'status');
    final text = status == null ? '' : _elementText(status);
    if (text.contains('200')) return prop;
    fallback ??= prop;
  }
  return fallback;
}

/// 解析 `<D:multistatus>`（容错：结构不符 → 空数组，不抛）。
///
/// 各家服务的前缀写法不一（`d:` / `D:` / `dav:`），统一按 `localName` 匹配。
List<DavRawEntry> parsePropfind(String xmlText) {
  final out = <DavRawEntry>[];
  final text = xmlText.trim();
  if (text.isEmpty) return out;
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } catch (_) {
    return out;
  }
  final root = doc.rootElement;
  if (root.localName.toLowerCase() != 'multistatus') return out;
  for (final response in root.childElements) {
    if (response.localName.toLowerCase() != 'response') continue;
    final hrefElement = _childElement(response, 'href');
    final href = hrefElement == null ? '' : _elementText(hrefElement);
    if (href.isEmpty) continue;
    final prop = _firstProp(response);
    if (prop == null) continue;
    final resourceType = _childElement(prop, 'resourcetype');
    var isDir = false;
    if (resourceType != null) {
      for (final child in resourceType.childElements) {
        if (child.localName.toLowerCase() == 'collection') {
          isDir = true;
          break;
        }
      }
    }
    final lengthElement = _childElement(prop, 'getcontentlength');
    final length = lengthElement == null
        ? 0
        : (int.tryParse(_elementText(lengthElement)) ?? 0);
    final nameElement = _childElement(prop, 'displayname');
    final mtimeElement = _childElement(prop, 'getlastmodified');
    out.add(
      DavRawEntry(
        href: href,
        displayName: nameElement == null ? '' : _elementText(nameElement),
        isDir: isDir,
        size: length > 0 ? length : 0,
        mtime: mtimeElement == null ? '' : _elementText(mtimeElement),
      ),
    );
  }
  return out;
}

/// href → 服务器上的解码路径（含前导 `/`）；解析失败返回空串。
String hrefToPath(String href, String base) {
  try {
    final root = Uri.parse('${normalizeDavBase(base)}/');
    final uri = root.resolve(href.trim());
    var path = uri.path;
    // Dart 的 Uri.path 仍保留百分号编码（与浏览器 URL.pathname 一致），这里只解一次：
    // 文件名里含字面 `%` 时会被编码成 `%25`，解一次正好还原。
    try {
      path = Uri.decodeComponent(path);
    } catch (_) {
      // 非法百分号编码 → 保持原样
    }
    if (path.isEmpty) return '/';
    return path.startsWith('/') ? path : '/$path';
  } catch (_) {
    return '';
  }
}

/// 服务器基址自带的路径（如 `/dav`；无则空串）。
///
/// PROPFIND 的 href 会带上它 —— 浏览结果统一剥掉，让 UI 与「再次请求」都以基址相对路径为准。
String davBasePath(String base) {
  try {
    final path = Uri.parse(normalizeDavBase(base)).path
        .replaceAll(RegExp(r'/+$'), '');
    return path == '/' ? '' : path;
  } catch (_) {
    return '';
  }
}

/// 从服务器绝对路径剥离基址路径（`/dav/movie/a.mp4` → `/movie/a.mp4`）。
String stripDavBase(String path, String basePath) {
  if (basePath.isEmpty) return path;
  if (path == basePath) return '/';
  if (path.startsWith('$basePath/')) return path.substring(basePath.length);
  return path;
}
