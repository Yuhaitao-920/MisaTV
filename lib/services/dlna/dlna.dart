// DLNA / UPnP 投屏的契约与纯逻辑（SSDP 报文 / 设备描述 / DIDL / SOAP 外壳）。
//
// 口径（对位旧版 Win-Box，来源为 TVBox `osc/dlna` 的移植）：
//   只覆盖 AVTransport:1 三动作 `SetAVTransportURI → Play →（有续播位置才）Seek REL_TIME`；
//   不做 Gena 事件订阅、不做 RenderingControl 音量、不做设备租约刷新。
import 'dart:convert';

import 'package:xml/xml.dart';

const String ssdpAddress = '239.255.255.250';
const int ssdpPort = 1900;
const String rendererTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';
const String avTransportType = 'urn:schemas-upnp-org:service:AVTransport:1';
const String renderingControlType =
    'urn:schemas-upnp-org:service:RenderingControl:1';

const String _soapNs = 'http://schemas.xmlsoap.org/soap/envelope/';
const String _avTransportNs = 'urn:schemas-upnp-org:service:AVTransport:1';

/// 一台 MediaRenderer。
class DlnaDevice {
  const DlnaDevice({
    required this.udn,
    required this.name,
    required this.controlUrl,
    required this.location,
    this.renderingControlUrl,
  });

  final String udn;
  final String name;

  /// AVTransport:1 的 controlURL（已按 location 解析成绝对地址）。
  final String controlUrl;
  final String? renderingControlUrl;
  final String location;
}

/// 一次投屏请求。
class DlnaCastTarget {
  const DlnaCastTarget({
    required this.url,
    required this.name,
    required this.positionMs,
    this.headers = const {},
    this.davId = '',
    this.localRelay = false,
  });

  final String url;
  final String name;

  /// 防盗链头（序列化进 DIDL 的 `dc:description`，对齐 TVBox）。
  final Map<String, String> headers;

  /// 续播位置（ms，>0 才发 Seek）。
  final int positionMs;

  /// WebDAV 服务器 id（投屏时用来补 Authorization 头）。
  final String davId;

  /// 本机中继地址（`/bt/…`、`/proxy/…` 等）无法解出真实上游 → 电视端多半拉不到流。
  final bool localRelay;
}

class DlnaCastResult {
  const DlnaCastResult({required this.ok, this.error = '', this.device = ''});

  final bool ok;
  final String error;
  final String device;
}

// ───────────────────────── SSDP 发现 ─────────────────────────

/// M-SEARCH 请求体（对位 Cling 的定向搜索）。
String buildSearchRequest({int mxSeconds = 2}) {
  return 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $ssdpAddress:$ssdpPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'ST: $rendererTarget\r\n'
      'MX: $mxSeconds\r\n'
      '\r\n';
}

class SsdpResponse {
  const SsdpResponse({
    required this.usn,
    required this.location,
    required this.st,
  });

  final String usn;
  final String location;
  final String st;
}

/// 解析一条 SSDP 应答。
///
/// 只认 200 且带 LOCATION 的；NOTIFY 广播（`NTS: ssdp:alive`）也吃 ——
/// 很多电视主动 announce 而不回 M-SEARCH。
SsdpResponse? parseSsdpResponse(String message) {
  final text = message.trim();
  if (text.isEmpty) return null;
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final first = lines.first;
  // 首行必须是状态行（HTTP/1.1 200 OK）或 NOTIFY —— 别把自己的 M-SEARCH 读回来。
  if (!RegExp(r'^HTTP/', caseSensitive: false).hasMatch(first) &&
      !RegExp(r'^NOTIFY', caseSensitive: false).hasMatch(first)) {
    return null;
  }
  var location = '';
  var usn = '';
  var st = '';
  for (final line in lines.skip(1)) {
    final index = line.indexOf(':');
    if (index <= 0) continue;
    final key = line.substring(0, index).trim().toUpperCase();
    final value = line.substring(index + 1).trim();
    if (key == 'LOCATION') {
      location = value;
    } else if (key == 'USN') {
      usn = value;
    } else if (key == 'ST') {
      st = value;
    } else if (key == 'NT' && st.isEmpty) {
      st = value;
    }
  }
  if (location.isEmpty) return null;
  return SsdpResponse(
    usn: usn.isEmpty ? location : usn,
    location: location,
    st: st.isEmpty ? rendererTarget : st,
  );
}

// ───────────────────────── 设备描述 ─────────────────────────

/// `location` + 相对 `controlURL` → 绝对地址。
///
/// UPnP 的 controlURL 一律相对**设备根**（不是 descriptor 所在目录），所以只取 scheme+authority 再拼。
String combineUrl(String location, String controlUrl) {
  final control = controlUrl.trim();
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(control)) {
    return control;
  }
  try {
    final loc = Uri.parse(location);
    final root = '${loc.scheme}://${loc.authority}'.replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final tail = control.startsWith('/') ? control : '/$control';
    return '$root$tail';
  } catch (_) {
    return control;
  }
}

/// 解析设备描述 XML（无 AVTransport 的设备返回 null —— TVBox 同样不列出）。
DlnaDevice? parseDeviceDescription(String xmlText, String location) {
  final text = xmlText.trim();
  if (text.isEmpty) return null;
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } catch (_) {
    return null;
  }
  var udn = '';
  var friendly = '';
  var avt = '';
  var rc = '';
  for (final element in doc.descendants.whereType<XmlElement>()) {
    final name = element.localName;
    if (name == 'UDN' && udn.isEmpty) {
      udn = element.innerText.trim();
    } else if (name == 'friendlyName' && friendly.isEmpty) {
      friendly = element.innerText.trim();
    } else if (name == 'service') {
      var type = '';
      var control = '';
      for (final child in element.childElements) {
        if (child.localName == 'serviceType') type = child.innerText.trim();
        if (child.localName == 'controlURL') control = child.innerText.trim();
      }
      if (type.isEmpty || control.isEmpty) continue;
      final lower = type.toLowerCase();
      if (avt.isEmpty && lower == avTransportType.toLowerCase()) avt = control;
      if (rc.isEmpty && lower == renderingControlType.toLowerCase()) {
        rc = control;
      }
    }
  }
  if (avt.isEmpty) return null;
  return DlnaDevice(
    udn: udn.isEmpty ? location : udn,
    name: friendly.isEmpty ? '未命名设备' : friendly,
    controlUrl: combineUrl(location, avt),
    renderingControlUrl: rc.isEmpty ? null : combineUrl(location, rc),
    location: location,
  );
}

// ───────────────────────── DIDL-Lite ─────────────────────────

/// 与 TVBox `escapeXml` 同覆盖面：5 个预定义实体 + 引号。
String escapeXml(String? value) {
  if (value == null || value.isEmpty) return '';
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// headers → `{"K":"V",…}`（TVBox 把防盗链头序列化成 JSON 塞进 `dc:description`）。
String headersJson(Map<String, String> headers) {
  final parts = headers.entries.map(
    (e) => '${_jsonString(e.key)}:${_jsonString(e.value)}',
  );
  return '{${parts.join(',')}}';
}

String _jsonString(String value) {
  final escaped = value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  return '"$escaped"';
}

/// 构造 `CurrentURIMetaData`（对位 `DLNACastManager.buildMetaData`）。
String buildMetaData(DlnaCastTarget target) {
  const head =
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="0">';
  final title =
      '<dc:title>${escapeXml(target.name)}</dc:title>'
      '<dc:creator></dc:creator><upnp:class>object.item.videoItem</upnp:class>';
  final desc = target.headers.isEmpty
      ? ''
      : '<dc:description>${escapeXml(headersJson(target.headers))}</dc:description>';
  final res =
      '<res protocolInfo="http-get:*:video/*:*">${escapeXml(target.url)}</res>';
  return '$head$title$desc$res</item></DIDL-Lite>';
}

/// 毫秒 → UPnP 的 `H:MM:SS.mmm`（Seek REL_TIME 用）。
String formatMs(int ms) {
  final value = ms > 0 ? ms : 0;
  final totalSec = value ~/ 1000;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  final millis = value % 1000;
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${p2(h)}:${p2(m)}:${p2(s)}.${millis.toString().padLeft(3, '0')}';
}

// ───────────────────────── SOAP ─────────────────────────

String _soapBody(String action, String args) {
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="$_soapNs" s:encodingStyle="$_soapNs-encoding">'
      '<s:Body><u:$action xmlns:u="$_avTransportNs">$args</u:$action></s:Body></s:Envelope>';
}

/// `SetAVTransportURI` 请求体。
///
/// DIDL 必须**再整体转义一层**（它是字符串实参，不是内联 XML）——
/// 漏这层是「投屏没反应」最常见的根因。
String buildSetUriBody(String uri, String didl) {
  return _soapBody(
    'SetAVTransportURI',
    '<InstanceID>0</InstanceID>'
        '<CurrentURI>${escapeXml(uri)}</CurrentURI>'
        '<CurrentURIMetaData>${escapeXml(didl)}</CurrentURIMetaData>',
  );
}

String buildPlayBody() =>
    _soapBody('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');

String buildStopBody() => _soapBody('Stop', '<InstanceID>0</InstanceID>');

String buildSeekBody(String relTime) => _soapBody(
  'Seek',
  '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>$relTime</Target>',
);

/// SOAP 1.1 要求 SOAPACTION 是**带引号**的 `#` 形式动作名。
String soapActionHeader(String action) => '"$_avTransportNs#$action"';

// ───────────────────────── 地址 → 投屏目标 ─────────────────────────

/// 播放地址 → 投屏目标。
///
/// 播放器里的地址通常是本机 `/play?url=<真实地址>&ua=&referer=&cookie=` 中继：
/// 电视端**够不到 127.0.0.1**，所以必须把真实上游地址解出来投出去（防盗链头随 DIDL 一起带）。
/// 解不出来的本机中继（BT `/bt/…`、蜘蛛 JVM `/proxy/…`）标 `localRelay`，由 UI 提示可能失败。
DlnaCastTarget parseCastTarget(
  String playUrl,
  String name,
  int positionMs, {
  String relayBase = '',
  Map<String, String> extraHeaders = const {},
}) {
  final raw = playUrl.trim();
  final title = name.trim().isEmpty ? 'MisaTV 投屏' : name.trim();
  final ms = positionMs > 0 ? positionMs : 0;
  final base = DlnaCastTarget(
    url: raw,
    name: title,
    positionMs: ms,
    headers: Map<String, String>.from(extraHeaders),
  );
  if (raw.isEmpty) {
    return DlnaCastTarget(
      url: raw,
      name: title,
      positionMs: ms,
      headers: base.headers,
      localRelay: true,
    );
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return base;
  }

  var relayPort = 9978;
  if (relayBase.trim().isNotEmpty) {
    final relay = Uri.tryParse(relayBase.trim());
    if (relay != null && relay.hasPort) relayPort = relay.port;
  }
  final host = uri.host.toLowerCase();
  final isLocal =
      (host == '127.0.0.1' || host == 'localhost' || host == '::1') &&
      (!uri.hasPort || uri.port == relayPort);
  if (!isLocal) return base; // 外部地址：原样投出去

  if (uri.path == '/play') {
    final inner = (uri.queryParameters['url'] ?? '').trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(inner)) {
      return DlnaCastTarget(
        url: raw,
        name: title,
        positionMs: base.positionMs,
        headers: base.headers,
        localRelay: true,
      );
    }
    final headers = Map<String, String>.from(extraHeaders);
    final ua = (uri.queryParameters['ua'] ?? '').trim();
    final referer = (uri.queryParameters['referer'] ?? '').trim();
    final cookie = (uri.queryParameters['cookie'] ?? '').trim();
    if (ua.isNotEmpty) headers['User-Agent'] = ua;
    if (referer.isNotEmpty) headers['Referer'] = referer;
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    final extra = (uri.queryParameters['h'] ?? '').trim();
    if (extra.isNotEmpty) {
      try {
        final decoded = jsonDecode(extra);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            headers[entry.key.toString()] = entry.value.toString();
          }
        }
      } catch (_) {
        // 非法扩展头忽略
      }
    }
    return DlnaCastTarget(
      url: inner,
      name: title,
      positionMs: base.positionMs,
      headers: headers,
      davId: (uri.queryParameters['dav'] ?? '').trim(),
    );
  }
  // `/bt/…`（磁力中继）、`/proxy/<port>`（蜘蛛 JVM 代理）等：只有本机能取，电视端拉不到。
  return DlnaCastTarget(
    url: raw,
    name: title,
    positionMs: base.positionMs,
    headers: base.headers,
    localRelay: true,
  );
}
