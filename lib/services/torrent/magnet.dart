// 磁力（BT）播放的**纯函数层**：不碰 electron / 子进程 / 文件系统，全部可离线单测。
//
// 分工：
//   · magnet URI 解析与 infoHash 归一（40 hex / 32 base32 → 40 hex 小写）；
//   · 公共 tracker 追加（阿里系网络下 DHT bootstrap 域易被 DNS 污染，tracker 是兜底 peer 来源）；
//   · 种子内**选片**（视频扩展名白名单 + 体积/集名线索）与「能否被内置播放器直接播」判定；
//   · piece 覆盖判定：`/bt` 中继向播放器喂字节前，必须确认该字节区间所在 piece 已落盘校验完成
//     —— 否则读到的是稀疏零（坏流）。位序按 aria2 源码口径（`BitfieldMan::setBitInternal`：
//     `mask = 128 >> (index % 8)`，即 **MSB-first**；RPC 层只是 `util::toHex(bitfield)`）。

/// 可被内置播放器（libmdk / 浏览器内核）直接播的容器（其余一律走外部播放器接力）。
const Set<String> webPlayableExts = {'mp4', 'm4v', 'webm'};

/// 种子内视为「正片」的扩展名白名单（选片用；顺序无关，取体积/线索打分）。
const Set<String> videoExts = {
  'mp4',
  'm4v',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'ts',
  'm2ts',
  'webm',
  'rmvb',
  'rm',
  'mpg',
  'mpeg',
  'vob',
  '3gp',
};

/// 兜底公共 tracker（仅在磁力自带 tracker 之外**追加**缺失项）。
///
/// 取舍：只用长期稳定、支持 UDP/HTTPS 的几家；宁少勿多（死 tracker 只会拖慢 announce）。
const List<String> publicTrackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.tracker.cl:1337/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://opentracker.i2p.rocks:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker.torrent.eu.org:451/announce',
];

class MagnetInfo {
  const MagnetInfo({
    required this.raw,
    required this.infoHash,
    required this.displayName,
    required this.trackers,
  });

  /// 原始 magnet URI（去掉首尾空白）。
  final String raw;

  /// infoHash：40 位 hex、小写（btih 给 base32 时已归一）。
  final String infoHash;

  /// `dn`（显示名，可能为空）。
  final String displayName;

  /// 磁力自带的 `tr`（去重，保持出现顺序）。
  final List<String> trackers;
}

/// btih 归一：40 位 hex（大小写不敏感）或 32 位 base32 → 40 位小写 hex；非法返回 ''。
String normalizeBtih(String raw) {
  final s = raw.trim();
  if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(s)) return s.toLowerCase();
  if (RegExp(r'^[A-Za-z2-7]{32}$').hasMatch(s)) {
    final hex = _base32ToHex(s.toUpperCase());
    return hex.length == 40 ? hex : '';
  }
  return '';
}

/// base32（RFC4648，无填充，A-Z2-7）→ hex（40 hex = 160 bit）。
String _base32ToHex(String b32) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bits = StringBuffer();
  for (var i = 0; i < b32.length; i++) {
    final value = alphabet.indexOf(b32[i]);
    if (value < 0) return '';
    bits.write(value.toRadixString(2).padLeft(5, '0'));
  }
  final all = bits.toString();
  final hex = StringBuffer();
  for (var i = 0; i + 4 <= 160; i += 4) {
    hex.write(int.parse(all.substring(i, i + 4), radix: 2).toRadixString(16));
  }
  return hex.toString();
}

/// magnet URI 解析。非法（非 magnet / 缺 `xt=urn:btih:` / infoHash 归一失败）→ null。
///
/// 说明：`xt` 可能带多个（btih + 其它 urn），只认 btih；`tr` 可重复。
/// 自己按 `&` 切分：`Uri.splitQueryString` 会把 `+` 当空格（tracker 里合法出现 `+` 的概率低，但直链参数常见）。
MagnetInfo? parseMagnet(String uri) {
  final raw = uri.trim();
  if (!RegExp(r'^magnet:\?', caseSensitive: false).hasMatch(raw)) return null;
  final query = raw.substring(raw.indexOf('?') + 1);
  var infoHash = '';
  final trackers = <String>[];
  var displayName = '';
  for (final part in query.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final key = (eq < 0 ? part : part.substring(0, eq)).toLowerCase();
    final value = eq < 0 ? '' : part.substring(eq + 1);
    if (key == 'xt' && infoHash.isEmpty) {
      final decoded = _decode(value);
      final match = RegExp(
        r'^urn:btih:(.+)$',
        caseSensitive: false,
      ).firstMatch(decoded);
      if (match != null) infoHash = normalizeBtih(match.group(1)!);
    } else if (key == 'tr') {
      final tracker = _decode(value).trim();
      if (tracker.isNotEmpty && !trackers.contains(tracker)) {
        trackers.add(tracker);
      }
    } else if (key == 'dn' && displayName.isEmpty) {
      displayName = _decode(value).trim();
    }
  }
  if (infoHash.isEmpty) return null;
  return MagnetInfo(
    raw: raw,
    infoHash: infoHash,
    displayName: displayName,
    trackers: trackers,
  );
}

String _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

/// 追加缺失的 tracker（已是 `tr=` 同一串的不再重复；返回新 URI，原样保留其它参数顺序）。
String withTrackers(String magnet, {List<String> extra = publicTrackers}) {
  final info = parseMagnet(magnet);
  if (info == null) return magnet;
  final add = extra
      .where((t) => t.isNotEmpty && !info.trackers.contains(t))
      .toList();
  if (add.isEmpty) return magnet;
  final separator = magnet.contains('?') ? '&' : '?';
  return magnet +
      separator +
      add.map((t) => 'tr=${Uri.encodeComponent(t)}').join('&');
}

/// 种子内单个文件（aria2 `getFiles` 的条目 + 我们算出的 torrent 内偏移）。
class TorrentFile {
  const TorrentFile({
    required this.index,
    required this.path,
    required this.length,
    required this.offset,
  });

  /// aria2 的 1-based 文件序号（`select-file` 用它）。
  final int index;
  final String path;
  final int length;

  /// 在 torrent 数据流中的起始偏移（标准多文件种子 = 前面所有文件长度之和）。
  final int offset;
}

/// 给 aria2 `getFiles` 结果补 torrent 内偏移（按条目顺序累加；padding 文件同样占位，累加即正确）。
List<TorrentFile> withTorrentOffsets(
  List<({int index, String path, int length})> files,
) {
  var offset = 0;
  final out = <TorrentFile>[];
  for (final file in files) {
    out.add(
      TorrentFile(
        index: file.index,
        path: file.path,
        length: file.length,
        offset: offset,
      ),
    );
    offset += file.length;
  }
  return out;
}

/// 文件名（含路径）→ 小写扩展名（无扩展名 → ''）。
String extOf(String name) {
  final base = name.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  // 点在开头（.gitignore 这类）不算扩展名。
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// 是否正片候选（按扩展名白名单）。
bool isVideoFile(String name) => videoExts.contains(extOf(name));

/// 文件名归一（去扩展名→小写→只留字母数字 CJK），用于集名线索比对。
String stemKey(String name) {
  final base = name.split(RegExp(r'[\\/]')).last;
  final ext = extOf(base);
  final noExt = ext.isEmpty
      ? base
      : base.substring(0, base.length - ext.length - 1);
  return noExt.toLowerCase().replaceAll(RegExp(r'[^0-9a-z\u4e00-\u9fff]+'), '');
}

/// 选片：**优先集名线索**（`preferName` 与文件名互为包含关系，如「第03集」↔「xx.E03」），
/// 其次取体积最大的正片；没有正片 → null。
///
/// 说明：合集包里「最大文件」几乎总是正片，但对同一剧集包的换集场景，集名线索更准。
TorrentFile? pickVideoFile(List<TorrentFile> files, {String preferName = ''}) {
  final videos = files
      .where((f) => isVideoFile(f.path) && f.length > 0)
      .toList();
  if (videos.isEmpty) return null;
  final hint = stemKey(preferName);
  if (hint.isNotEmpty) {
    for (final file in videos) {
      final key = stemKey(file.path);
      if (key.isNotEmpty && (key.contains(hint) || hint.contains(key))) {
        return file;
      }
    }
  }
  videos.sort((a, b) => b.length.compareTo(a.length));
  return videos.first;
}

/// 该文件能否交给内置播放器直接播。
///
/// 不能的两种原因：
///   · 容器不被支持（mkv/avi/mov/rmvb…）→ 外部播放器接力；
///   · HEVC（x265/H.265）编码：浏览器内核只有平台硬解时才认，命中即按外部处理（宁可外部也不要黑屏）。
/// 返回 null 表示可直连播；否则返回**人话原因**（上屏用）。
String? webPlayBlockReason(String name) {
  final ext = extOf(name);
  if (!webPlayableExts.contains(ext)) {
    return '${ext.isEmpty ? '未知' : ext.toUpperCase()} 容器内置播放器不支持';
  }
  final base = name.split(RegExp(r'[\\/]')).last;
  if (RegExp(
    r'(^|[^a-z0-9])(hevc|x265|h\.?265)([^a-z0-9]|$)',
    caseSensitive: false,
  ).hasMatch(base)) {
    return 'HEVC（H.265）编码内置播放器多数环境不支持';
  }
  return null;
}

/// aria2 addUri / addTorrent 的公共参数（纯构造，便于单测与排障对拍）。
Map<String, String> addUriOptions(String dir) => {
  // 只下元数据后**暂停**：等我们按文件清单挑好片再 unpause（aria2 官方文件选择流程）。
  'pause-metadata': 'true',
  'bt-save-metadata': 'true', // 落 .torrent，二次播放可免 DHT 拉元数据
  'bt-remove-unselected-file': 'false', // 未选中的文件不下载、也不删（避免误删用户数据）
  'seed-time': '0',
  'dir': dir,
};

/// 追加公共 tracker 后的 infoHash 键（会话表用；解析失败返回 ''）。
String magnetKey(String magnet) => parseMagnet(magnet)?.infoHash ?? '';

/// `followedBy` 解析：aria2 1.37 返回**数组**（源码 `gatherProgressCommon` 里是 List），
/// 早期版本为字符串 → 两种都吃，取第一个。
String firstFollowedBy(Object? value) {
  if (value is String) return value.trim();
  if (value is List) {
    for (final item in value) {
      if (item is String && item.trim().isNotEmpty) return item.trim();
    }
  }
  return '';
}

/// tellStatus 里我们关心的键（一次取全，减少轮询次数）。
const List<String> statusKeys = [
  'status',
  'totalLength',
  'completedLength',
  'downloadSpeed',
  'pieceLength',
  'bitfield',
  'connections',
  'numSeeders',
  'errorCode',
  'errorMessage',
  'followedBy',
];

/// piece 是否已下载（校验通过）—— 位序：hex 串第 `i>>2` 个字符、自高位起第 `i&3` 位
/// （即 aria2 `mask = 128 >> (index % 8)` + `toHex` 的字节序）。
///
/// 越界（bitfield 太短）按「未下载」处理（保守：宁可多等，不可喂零）。
bool isPieceSet(String hex, int piece) {
  if (piece < 0) return false;
  final index = piece >> 2;
  if (index >= hex.length) return false;
  final nibble = int.tryParse(hex[index], radix: 16);
  if (nibble == null) return false;
  return ((nibble >> (3 - (piece & 3))) & 1) == 1;
}

/// [first, last] 闭区间内的 piece 是否全部已下载。
bool isPieceRangeSet(String hex, int first, int last) {
  if (last < first) return true;
  for (var i = first; i <= last; i++) {
    if (!isPieceSet(hex, i)) return false;
  }
  return true;
}

/// 文件内字节区间 [start, end]（相对该文件）落在哪些 torrent piece 上。
///
/// `fileOffset` = 该文件在 torrent 内的起始偏移（见 withTorrentOffsets）。
({int first, int last}) piecesForByteRange(
  int fileOffset,
  int pieceLength,
  int start,
  int end,
) {
  if (pieceLength <= 0) return (first: 0, last: 0);
  final absStart = fileOffset + (start < 0 ? 0 : start);
  final absEnd = fileOffset + (end < 0 ? 0 : end);
  return (first: absStart ~/ pieceLength, last: absEnd ~/ pieceLength);
}

/// `/bt/<infoHash>/<fileIndex>` 路由解析（非法 → null）。
({String infoHash, int fileIndex})? parseBtRoute(String pathname) {
  final match = RegExp(r'^/bt/([0-9a-fA-F]{40})/(\d{1,6})/?$')
      .firstMatch(pathname);
  if (match == null) return null;
  final fileIndex = int.tryParse(match.group(2)!) ?? 0;
  if (fileIndex <= 0) return null;
  return (infoHash: match.group(1)!.toLowerCase(), fileIndex: fileIndex);
}

/// 本地中继播放地址（`/bt` 路由；playerBase 形如 `http://127.0.0.1:9978`）。
String btStreamUrl(String playerBase, String infoHash, int fileIndex) =>
    '${playerBase.trim().replaceAll(RegExp(r'/+$'), '')}/bt/$infoHash/$fileIndex';

/// 首段起播门控字节（返回播放地址前先等这么多数据落盘，避免播放器一上来就空转）。
const int btHeadGateBytes = 512 * 1024;
