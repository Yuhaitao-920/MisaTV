import '../../models/vod.dart';

/// 一次「设备流转」的载荷：把当前正在播的这一集交给局域网里另一台设备。
///
/// 设计取舍（与用户确认过）：**只传已取到播放地址 + 元数据**，不传订阅信息。
///   · 优点：不要求两端装同样的订阅；对端拿到地址可直接播。
///   · 代价：地址可能是带时效的直链（网盘 / 部分 CDN）。这种情况对端可能
///     播不了，界面上会提示「地址已失效，可让对方重新流转」。
///
/// 不传站点凭据、不传 Cookie 明文 —— `headers` 里只保留播放所必需的
/// Referer / UA 一类，且只在局域网内传输。
class FlowPayload {
  const FlowPayload({
    required this.vodName,
    required this.episodeName,
    required this.episodeIndex,
    required this.url,
    required this.fromDevice,
    this.flag = '',
    this.positionMs = 0,
    this.headers = const {},
    this.pic = '',
    this.sourceName = '',
    this.sourceKey = '',
    this.vodId = '',
    this.sentAtMs = 0,
  });

  /// 剧名（用于对端显示与历史记录）。
  final String vodName;
  final String episodeName;
  final int episodeIndex;

  /// 已取到的播放地址。
  final String url;

  /// 推送方设备名（对端提示「来自 XX 的流转」）。
  final String fromDevice;
  final String flag;

  /// 从这一集的第几毫秒开始播（保持进度连续）。
  final int positionMs;
  final Map<String, String> headers;
  final String pic;
  final String sourceName;
  final String sourceKey;
  final String vodId;
  final int sentAtMs;

  Map<String, dynamic> toJson() => {
    'vodName': vodName,
    'episodeName': episodeName,
    'episodeIndex': episodeIndex,
    'url': url,
    'fromDevice': fromDevice,
    'flag': flag,
    'positionMs': positionMs,
    'headers': headers,
    'pic': pic,
    'sourceName': sourceName,
    'sourceKey': sourceKey,
    'vodId': vodId,
    'sentAtMs': sentAtMs,
  };

  factory FlowPayload.fromJson(Map<String, dynamic> j) {
    final rawHeaders = j['headers'];
    return FlowPayload(
      vodName: (j['vodName'] ?? '').toString(),
      episodeName: (j['episodeName'] ?? '').toString(),
      episodeIndex: (j['episodeIndex'] as num?)?.toInt() ?? 0,
      url: (j['url'] ?? '').toString(),
      fromDevice: (j['fromDevice'] ?? '').toString(),
      flag: (j['flag'] ?? '').toString(),
      positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
      headers: rawHeaders is Map
          ? {
              for (final e in rawHeaders.entries)
                e.key.toString(): e.value.toString(),
            }
          : const {},
      pic: (j['pic'] ?? '').toString(),
      sourceName: (j['sourceName'] ?? '').toString(),
      sourceKey: (j['sourceKey'] ?? '').toString(),
      vodId: (j['vodId'] ?? '').toString(),
      sentAtMs: (j['sentAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// 从播放器当前状态构造。只在推送方调用。
  ///
  /// [episodes] 用于还原剧集列表，让接收方也能看到选集（虽然只播这一集）。
  VodDetail toSyntheticDetail(List<Episode> episodes) => VodDetail(
    id: vodId.isEmpty ? vodName : vodId,
    name: vodName,
    pic: pic,
    flags: [flowFlag],
    episodes: {flowFlag: episodes},
    sourceKey: sourceKey,
  );

  String get flowFlag => flag.isEmpty ? '流转' : flag;

  /// 构造传给 [PlayerSession] 的播放结果。
  PlayResult toPlayResult() =>
      PlayResult(url: url, flag: flowFlag, headers: headers);
}

/// 接收方对流转请求的应答。
class FlowAck {
  const FlowAck({required this.accepted, this.message = ''});

  final bool accepted;
  final String message;

  Map<String, dynamic> toJson() => {'accepted': accepted, 'message': message};
}
