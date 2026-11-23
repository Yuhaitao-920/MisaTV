// UC 网盘「免转存」直链解析（纯 Dart，供桌面端原生通道使用）。
//
// 只做直链：绝不转存到用户网盘、不轮询任务、不删除。
//
// 取链契约（复刻 winbox 的真机结论）：
//   POST /share/sharepage/token  { pwd_id, passcode }                     → data.stoken
//   GET  /share/sharepage/detail?pwd_id&stoken&pdir_fid&_page&_size       → data.list[]
//   POST /file/download          { fids, fid_token_list, pwd_id, stoken } → data[0].download_url
//
// 直链取流必须带 Cookie + Referer(https://drive.uc.cn/) + UA；
// 部分 CDN 节点会在 download 响应里下发新会话 Cookie，必须并入播放 Cookie。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'drive_descriptor.dart';
import 'quark_session_io.dart' show mergeSetCookies, sanitizeCookie;

const _ref = 'https://drive.uc.cn/';
const _base = 'https://pc-api.uc.cn/1/clouddrive';
const _query = 'pr=UCBrowser&fr=pc';
const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.6478.61 Safari/537.36';

const _pageSize = 50;
const _maxTotal = 500;

final _httpUrlRe = RegExp(r'^https?://', caseSensitive: false);
final _ucFlagRe = RegExp(r'^(?:UC(?:\b|网盘)|优汐)', caseSensitive: false);
final _ucCompoundRe = RegExp(
  r'^(.*?)__([0-9a-f]{32})\+([0-9a-z]{10,32})\+([0-9a-f]{32})$',
  caseSensitive: false,
);
final _ucShareIdRe =
    RegExp(r'(?:drive|fast)\.uc\.cn/s/([0-9a-zA-Z_-]+)', caseSensitive: false);
final _shareIdCharsRe = RegExp(r'^[0-9a-z_-]+$', caseSensitive: false);
final _fidBadRe = RegExp(r'[/:?]');
final _pwdRe = RegExp(
  r'[?&](?:pwd|password|passcode)=([0-9a-zA-Z]{4})',
  caseSensitive: false,
);
final _totalSizeRe = RegExp(r'/([0-9]+)$');
final _mediaTypeRe = RegExp(
  r'video|audio|octet-stream|matroska|mpeg|mp4|webm|quicktime',
  caseSensitive: false,
);

typedef _Node = Map<Object?, Object?>;

/// UC 分享解析结果。
class UcShareRef {
  const UcShareRef({
    required this.pwdId,
    this.passcode = '',
    this.fileId = '',
    this.name = '',
  });

  final String pwdId;
  final String passcode;
  final String fileId;
  final String name;
}

class _UcShareFile {
  const _UcShareFile({
    required this.fid,
    required this.token,
    required this.name,
    required this.size,
  });

  final String fid;
  final String token;
  final String name;
  final int size;
}

class _HttpResult {
  const _HttpResult({
    required this.status,
    required this.text,
    required this.json,
    required this.setCookies,
  });

  final int status;
  final String text;
  final Map<String, dynamic> json;
  final List<String> setCookies;
}

/// 全局串行锁：分享会话与 download 下发 Cookie 属共享状态机，并发会互相污染。
Future<void> _ucChain = Future<void>.value();

Future<NativeDriveLink> _enqueueUc(
  Future<NativeDriveLink> Function() task,
) {
  final run = _ucChain.then((_) async {
    try {
      return await task();
    } catch (e) {
      return NativeDriveLink.failed('UC 请求失败（${_briefError(e)}）');
    }
  });
  _ucChain = run.then<void>((_) {}, onError: (Object e, StackTrace s) {});
  return run;
}

/// 该文本是否是 UC 分享（描述符 / `drive.uc.cn/s/<id>` / `fast.uc.cn/s/<id>`）。
bool looksLikeUcShare(String text, {String flag = ''}) {
  final desc = parseDriveDescriptor(text);
  if (desc != null) return desc.provider == 'uc';
  return extractUcShare(text, flag: flag) != null;
}

/// 是否是 FTY 系 UC 复合集地址（`<name>__<fid>+<pwdId>+<token>`）。
///
/// 结构本身就能确定是 UC：夸克复合串用 `~~`，且分享 id 不在这个位置。
bool looksLikeUcCompound(String text) =>
    _ucCompoundRe.hasMatch(text.trim());

/// 从文本解析 UC 分享 `pwd_id`、提取码与内层 fid。
UcShareRef? extractUcShare(String text, {String flag = ''}) {
  final desc = parseDriveDescriptor(text);
  if (desc != null && desc.provider == 'uc') {
    final pwdId = descriptorField(
      desc.data,
      <String>['shareId', 'pwdId', 'sId'],
    );
    if (pwdId.isNotEmpty) {
      final passcode = _str(desc.data['passcode']).isNotEmpty
          ? _str(desc.data['passcode'])
          : _str(desc.data['pwd']);
      final fileId = descriptorField(
        desc.data,
        <String>['fileId', 'fid', 'fs_id', 'file_id'],
      );
      final name = descriptorField(
        desc.data,
        <String>['name', 'fileName', 'file_name'],
      );
      return UcShareRef(
        pwdId: pwdId,
        passcode: passcode,
        fileId: fileId,
        name: name,
      );
    }
  }

  // FTY 系复合集地址：`<name>__<fid>+<pwdId>+<share_fid_token>`。
  // 结构是 UC 专有的（夸克复合串用 `~~`，且 pwd_id 在末段），不能只看线路名：
  // 实测「夸克无限」线路会直接下发 UC 分享，按线路名过滤会误判成夸克。
  final compound = _ucCompoundRe.firstMatch(text.trim());
  if (compound != null) {
    return UcShareRef(
      pwdId: compound.group(3)!,
      fileId: compound.group(2)!,
      name: compound.group(1) ?? '',
    );
  }

  // 逐项 JSON 描述（sId/fid）仍只在明确 UC 线路时解释，避免与夸克抢同一批 id。
  if (_ucFlagRe.hasMatch(flag)) {
    try {
      final d = _asMap(jsonDecode(text));
      if (d != null) {
        final sid = d['sId'];
        final fid = d['fid'];
        if (sid is String &&
            _shareIdCharsRe.hasMatch(sid) &&
            fid is String &&
            fid.isNotEmpty &&
            !_fidBadRe.hasMatch(fid)) {
          final passcode = _str(d['passcode']).isNotEmpty
              ? _str(d['passcode'])
              : _str(d['pwd']);
          return UcShareRef(
            pwdId: sid,
            passcode: passcode,
            fileId: fid,
            name: _str(d['name']),
          );
        }
      }
    } catch (_) {
      // 仍尝试显式 UC 分享 URL。
    }
  }

  for (final candidate in shareTextCandidates(text)) {
    final match = _ucShareIdRe.firstMatch(candidate);
    if (match == null) continue;
    final pwd = _pwdRe.firstMatch(candidate);
    return UcShareRef(
      pwdId: match.group(1)!,
      passcode: pwd?.group(1) ?? '',
    );
  }
  return null;
}

/// 把文本解析为可播直链（全局串行；无转存兜底）。
Future<NativeDriveLink> resolveUcDirect(
  String text, {
  required String cookie,
  String flag = '',
  String episodeName = '',
}) {
  return _enqueueUc(
    () => _resolveUcDirectInner(
      text,
      cookie: cookie,
      flag: flag,
      episodeName: episodeName,
    ),
  );
}

Future<NativeDriveLink> _resolveUcDirectInner(
  String text, {
  required String cookie,
  required String flag,
  required String episodeName,
}) async {
  if (cookie.trim().isEmpty) {
    return NativeDriveLink.failed('未绑定 UC 账号（Cookie 缺失）');
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) return NativeDriveLink.failed('播放地址为空');

  final desc = parseDriveDescriptor(trimmed);
  final ref = extractUcShare(trimmed, flag: flag);
  if (ref == null) {
    if (desc != null) {
      return NativeDriveLink.failed('不是 UC 网盘分享（provider=${desc.provider}）');
    }
    return NativeDriveLink.failed('未识别 UC 分享链接');
  }
  if (ref.pwdId.trim().isEmpty) {
    return NativeDriveLink.failed('分享 ID 为空');
  }
  final accountCookie = sanitizeCookie(cookie);

  // 1) 取分享 stoken（token 接口按 winbox 行为不带账号 Cookie）。
  final tokenResult = await _post(
    '/share/sharepage/token',
    null,
    <String, Object?>{'pwd_id': ref.pwdId, 'passcode': ref.passcode},
  );
  final stoken = _str(_dig(tokenResult.json, <Object>['data', 'stoken']));
  if (stoken.isEmpty) {
    final message = _str(tokenResult.json['message']);
    final code = _intOrNull(tokenResult.json['code']);
    final detail = message.isNotEmpty
        ? message
        : (code == null ? 'HTTP ${tokenResult.status}' : 'code=$code');
    return NativeDriveLink.failed('分享不可用（${_clip(detail, 120)}）');
  }

  // 2) 分页枚举分享目录树，按 fid 精确 / 集名唯一匹配定位目标文件。
  Future<List<dynamic>> fetchPage(String pdirFid, int offset) async {
    final page = offset ~/ _pageSize + 1;
    final result = await _get(
      '/share/sharepage/detail'
      '?pwd_id=${Uri.encodeQueryComponent(ref.pwdId)}'
      '&stoken=${Uri.encodeQueryComponent(stoken)}'
      '&pdir_fid=${Uri.encodeQueryComponent(pdirFid)}'
      '&force=0&_page=$page&_size=$_pageSize'
      '&_fetch_banner=0&_fetch_share=0&_fetch_total=1',
      accountCookie,
    );
    final code = _intOrNull(result.json['code']);
    if (result.status != 200 || code != 0) {
      throw StateError(
        'UC 分享列表失败 HTTP ${result.status}, '
        'code=${result.json['code'] ?? '-'}',
      );
    }
    final list = _dig(result.json, <Object>['data', 'list']);
    return list is List ? list : const <dynamic>[];
  }

  final preferName =
      episodeName.trim().isNotEmpty ? episodeName.trim() : ref.name;
  _UcShareFile? file;
  try {
    file = await _resolveShareFile(ref.fileId, fetchPage, preferName);
  } catch (e) {
    return NativeDriveLink.failed('分享列表读取失败（${_briefError(e)}）');
  }
  if (file == null) {
    return NativeDriveLink.failed('分享内未定位到目标文件（可能已失效或集数不匹配）');
  }
  if (file.token.isEmpty) {
    final label = file.name.isNotEmpty ? file.name : file.fid;
    return NativeDriveLink.failed('目标文件「${_clip(label, 30)}」缺少分享令牌');
  }

  // 3) 免转存直链：带分享 token 直接 download，不写本人盘。
  final direct = await _post(
    '/file/download',
    accountCookie,
    <String, Object?>{
      'fids': <String>[file.fid],
      'fid_token_list': <String>[file.token],
      'pwd_id': ref.pwdId,
      'stoken': stoken,
    },
  );
  final directUrl = _str(_dig(direct.json, <Object>['data', 0, 'download_url']));
  if (directUrl.isEmpty) {
    final message = _str(direct.json['message']);
    final code = _intOrNull(direct.json['code']);
    final detail = message.isNotEmpty
        ? message
        : (code == null ? 'HTTP ${direct.status}' : 'code=$code');
    return NativeDriveLink.failed('未取到下载直链（${_clip(detail, 100)}）');
  }

  // The URL is bound to the session cookie returned by /file/download on
  // some UC CDN nodes; merge it before validating and playback.
  final playCookie = mergeSetCookies(accountCookie, direct.setCookies);
  final playHeaders = <String, String>{
    'User-Agent': _ua,
    'Referer': _ref,
    'Cookie': playCookie,
  };
  final invalid = await _validateUcMediaUrl(
    directUrl,
    file.size,
    playHeaders,
  );
  if (invalid != null) {
    return NativeDriveLink.failed('免转存直链不可用（$invalid）');
  }
  return NativeDriveLink(ok: true, url: directUrl, headers: playHeaders);
}

/// 分享目录树解析（复刻 winbox `resolveShareFile` 的护栏逻辑）。
///
/// ① 分页枚举（单目录上限 500 条）；
/// ② 有 fid 必须精确命中，全树找不到不盲选；
/// ③ fid 未命中时按集名唯一匹配兜底；
/// ④ 无 fid / 集名时，仅整树唯一文件才自动选中。
Future<_UcShareFile?> _resolveShareFile(
  String preferFid,
  Future<List<dynamic>> Function(String pdirFid, int offset) fetcher,
  String preferName,
) async {
  Future<List<_Node>> listAll(String pdirFid) async {
    final out = <_Node>[];
    final seen = <String>{};
    for (var offset = 0; offset * _pageSize < _maxTotal; offset++) {
      final page = await fetcher(pdirFid, offset * _pageSize);
      if (page.isEmpty) break;
      for (final raw in page) {
        final node = _asMap(raw);
        if (node == null) continue;
        final fid = _str(node['fid']);
        final key = fid.isNotEmpty
            ? fid
            : '${_str(node['pdir_fid'])}:${_str(node['file_name'])}';
        if (!seen.add(key)) continue;
        out.add(node);
      }
      if (page.length < _pageSize) break;
    }
    return out;
  }

  if (preferFid.isNotEmpty || preferName.isNotEmpty) {
    _Node? hit;
    final seenDirs = <String>{};
    Future<bool> dfs(String pdirFid, int depth) async {
      if (depth > 8 || !seenDirs.add(pdirFid)) return false;
      final list = await listAll(pdirFid);
      if (preferFid.isNotEmpty) {
        for (final node in list) {
          if (_str(node['fid']) == preferFid) {
            hit = node;
            return true;
          }
        }
      }
      for (final node in list) {
        if (!_isDirNode(node)) continue;
        final fid = _str(node['fid']);
        if (fid.isEmpty) continue;
        if (await dfs(fid, depth + 1)) return true;
      }
      return false;
    }

    if (preferFid.isNotEmpty) {
      final found = await dfs('0', 0);
      if (found) return _toShareFile(hit);
    }

    final key = _episodeKeyOf(preferName);
    if (key.isNotEmpty) {
      final all = <_Node>[];
      final seen2 = <String>{};
      Future<void> collect(String pdirFid, int depth) async {
        if (depth > 8 || !seen2.add(pdirFid)) return;
        final list = await listAll(pdirFid);
        for (final node in list) {
          if (_isDirNode(node)) {
            final fid = _str(node['fid']);
            if (fid.isNotEmpty) await collect(fid, depth + 1);
          } else if (_str(node['fid']).isNotEmpty) {
            all.add(node);
          }
        }
      }

      await collect('0', 0);
      final matches = all.where((node) {
        final name = _str(node['file_name']).isNotEmpty
            ? _str(node['file_name'])
            : _str(node['fname']);
        return _episodeKeyOf(name) == key;
      }).toList();
      if (matches.length == 1) return _toShareFile(matches.first);
    }
    return null;
  }

  final outer = await listAll('0');
  Future<List<_Node>> collectCandidates(List<_Node> nodes, int depth) async {
    final files = <_Node>[];
    for (final node in nodes) {
      if (_isDirNode(node)) {
        if (depth > 2) continue;
        final fid = _str(node['fid']);
        if (fid.isEmpty) continue;
        files.addAll(await collectCandidates(await listAll(fid), depth + 1));
      } else {
        files.add(node);
      }
    }
    return files;
  }

  final candidates = await collectCandidates(outer, 0);
  if (candidates.length != 1) return null;
  return _toShareFile(candidates.first);
}

_UcShareFile? _toShareFile(_Node? item) {
  if (item == null) return null;
  final fid = _str(item['fid']);
  if (fid.isEmpty) return null;
  var token = _str(item['share_fid_token']);
  if (token.isEmpty) token = _str(item['fid_token']);
  if (token.isEmpty) token = _str(item['token']);
  final name = _str(item['file_name']).isNotEmpty
      ? _str(item['file_name'])
      : _str(item['fname']);
  return _UcShareFile(
    fid: fid,
    token: token,
    name: name,
    size: _intOrNull(item['size']) ?? 0,
  );
}

bool _isDirNode(_Node node) {
  final dir = node['dir'];
  if (dir is bool) return dir;
  final fileType = _intOrNull(node['file_type']);
  if (fileType == 0 || fileType == 2) return true;
  final format = node['format_type'];
  if (fileType == 1 || (format != null && _str(format).isNotEmpty)) {
    return false;
  }
  final size = node['size'];
  if (size is num) return size == 0;
  return !node.containsKey('size');
}

/// 集名归一：优先集号（S01E06 / 第6集 / E06 / 06.mp4 → ep6），否则去扩展名。
String _episodeKeyOf(String name) {
  final s = name
      .trim()
      .replaceFirst(
        RegExp(
          r'\[\s*\d+(?:\.\d+)?\s*(?:[KMGT]i?B)\s*\]$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceFirst(
        RegExp(
          r'\.(?:mp4|mkv|avi|mov|m4v|ts|m2ts|flv|wmv|webm|m3u8)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  if (s.isEmpty) return '';
  final seasonEpisode = RegExp(r'[Ss]\d{1,2}\s*[Ee]\s*0*(\d{1,4})').firstMatch(s);
  if (seasonEpisode != null) {
    return 'ep${int.parse(seasonEpisode.group(1)!)}';
  }
  final chineseEpisode =
      RegExp(r'第\s*0*(\d{1,4})\s*[集话期]').firstMatch(s);
  if (chineseEpisode != null) {
    return 'ep${int.parse(chineseEpisode.group(1)!)}';
  }
  final ep = RegExp(
    r'(?:^|[^a-z0-9])[Ee][Pp]?\s*0*(\d{1,4})(?![0-9])',
    caseSensitive: false,
  ).firstMatch(s);
  if (ep != null) return 'ep${int.parse(ep.group(1)!)}';
  final quality = RegExp(
    r'(?:^|[\]\s._-])0*(\d{1,3})[\s.~_-]+(?:4k|2k|2160p|1080p|720p)(?![a-z0-9])',
    caseSensitive: false,
  ).firstMatch(s);
  if (quality != null) return 'ep${int.parse(quality.group(1)!)}';
  final bare = RegExp(
    r'(?:^|[^a-z0-9])0*(\d{1,3})(?=\.[a-z0-9]{1,5}$|\s*$)',
    caseSensitive: false,
  ).firstMatch(s);
  if (bare != null) return 'ep${int.parse(bare.group(1)!)}';
  return s.replaceFirst(RegExp(r'\.[a-z0-9]{1,6}$'), '').trim();
}

Future<String?> _validateUcMediaUrl(
  String url,
  int expectedSize,
  Map<String, String> headers,
) async {
  if (!_httpUrlRe.hasMatch(url)) return '下载地址不是 HTTP(S)';
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  try {
    final request =
        await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
    request.followRedirects = true;
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final status = response.statusCode;
    if (status < 200 || status > 299) return 'CDN 响应 HTTP $status';

    final contentType = _headerFirst(
      response.headers,
      HttpHeaders.contentTypeHeader,
    ).toLowerCase();
    final contentRange =
        _headerFirst(response.headers, 'content-range');
    final contentLength = _headerFirst(
      response.headers,
      HttpHeaders.contentLengthHeader,
    );
    final length = int.tryParse(contentLength) ?? 0;
    final bytes = await _readPrefix(response, 4096)
        .timeout(const Duration(seconds: 20));

    final magic = bytes.isNotEmpty &&
        (bytes[0] == 0x47 ||
            (bytes.length >= 4 &&
                bytes[0] == 0x1a &&
                bytes[1] == 0x45 &&
                bytes[2] == 0xdf &&
                bytes[3] == 0xa3) ||
            (bytes.length >= 8 &&
                bytes[4] == 0x66 &&
                bytes[5] == 0x74 &&
                bytes[6] == 0x79 &&
                bytes[7] == 0x70));
    if (!magic && !_mediaTypeRe.hasMatch(contentType)) {
      final type = contentType.isEmpty ? '未知类型' : contentType;
      return 'CDN 返回非媒体内容（$type）';
    }

    final totalMatch = _totalSizeRe.firstMatch(contentRange);
    final reportedSize =
        totalMatch != null ? int.tryParse(totalMatch.group(1)!) ?? 0 : length;
    if (expectedSize > 0 &&
        reportedSize > 0 &&
        reportedSize != expectedSize) {
      return 'CDN 文件大小 $reportedSize 与目标 $expectedSize 不一致';
    }
    return null;
  } catch (e) {
    return 'CDN 媒体校验异常：${_briefError(e)}';
  } finally {
    client.close(force: true);
  }
}

/// 只读取前 [max] 字节后取消订阅，绝不把整集下载完。
Future<List<int>> _readPrefix(HttpClientResponse response, int max) {
  final out = <int>[];
  final done = Completer<List<int>>();
  late StreamSubscription<List<int>> subscription;
  void finish() {
    if (!done.isCompleted) done.complete(out);
  }

  subscription = response.listen(
    (chunk) {
      final need = max - out.length;
      if (need > 0) {
        out.addAll(chunk.length <= need ? chunk : chunk.sublist(0, need));
      }
      if (out.length >= max) {
        unawaited(subscription.cancel());
        finish();
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
    onDone: finish,
    cancelOnError: true,
  );
  return done.future;
}

Future<_HttpResult> _post(String path, String? cookie, Object body) {
  final headers = <String, String>{
    'User-Agent': _ua,
    'Referer': _ref,
    'Origin': 'https://drive.uc.cn',
    'Content-Type': 'application/json',
  };
  if (cookie != null && cookie.isNotEmpty) headers['Cookie'] = cookie;
  return _http(
    Uri.parse('$_base$path?$_query'),
    method: 'POST',
    body: jsonEncode(body),
    headers: headers,
  );
}

Future<_HttpResult> _get(String path, String cookie) {
  final separator = path.contains('?') ? '&' : '?';
  return _http(
    Uri.parse('$_base$path$separator$_query'),
    headers: <String, String>{
      'User-Agent': _ua,
      'Referer': _ref,
      'Origin': 'https://drive.uc.cn',
      'Cookie': cookie,
    },
  );
}

Future<_HttpResult> _http(
  Uri uri, {
  String method = 'GET',
  String? body,
  Map<String, String> headers = const <String, String>{},
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  try {
    final request =
        await client.openUrl(method, uri).timeout(const Duration(seconds: 12));
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null) request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 20));
    final setCookies = <String>[];
    response.headers.forEach((name, values) {
      if (name.toLowerCase() == HttpHeaders.setCookieHeader) {
        setCookies.addAll(values);
      }
    });
    var json = <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // 非 JSON：交给调用方看 text。
    }
    return _HttpResult(
      status: response.statusCode,
      text: text,
      json: json,
      setCookies: setCookies,
    );
  } finally {
    client.close(force: true);
  }
}

String _headerFirst(HttpHeaders headers, String name) {
  final values = headers[name];
  return values != null && values.isNotEmpty ? values.first : '';
}

Map<Object?, Object?>? _asMap(Object? value) => value is Map ? value : null;

Object? _dig(Object? node, List<Object> path) {
  var current = node;
  for (final key in path) {
    if (current is Map) {
      current = current[key];
    } else if (current is List && key is int) {
      if (key < 0 || key >= current.length) return null;
      current = current[key];
    } else {
      return null;
    }
  }
  return current;
}

String _str(Object? value) {
  if (value is String) return value.trim();
  if (value is num) return value.toString();
  if (value is bool) return value ? '1' : '0';
  return '';
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String _clip(String text, int max) =>
    text.length <= max ? text : text.substring(0, max);

String _briefError(Object error) {
  final text = error.toString().replaceAll('\n', ' ');
  return text.length > 80 ? text.substring(0, 80) : text;
}
