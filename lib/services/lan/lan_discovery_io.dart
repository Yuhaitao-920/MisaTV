import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/logging/app_log.dart';

/// 局域网里一台可被流转的设备。
class LanDevice {
  const LanDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.platform,
    required this.lastSeenAt,
  });

  /// 稳定标识（设备首次启动时生成并持久化），用于去重。
  final String id;
  final String name;

  /// 对方 HTTP 服务的地址（LanServer 的 `/flow` 就挂在上面）。
  final String host;
  final int port;

  /// `windows` / `android` / `macos` / `linux` / `web`。
  final String platform;
  final DateTime lastSeenAt;

  String get baseUrl => 'http://$host:$port';

  LanDevice copyWith({DateTime? lastSeenAt}) => LanDevice(
    id: id,
    name: name,
    host: host,
    port: port,
    platform: platform,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'port': port,
    'platform': platform,
  };

  @override
  String toString() => '$name($platform) $host:$port';
}

/// UDP 广播发现：让同一局域网内的 MisaTV 互相看见。
///
/// 设计取舍：
///   · 用 UDP 广播而不是 mDNS —— 不引入额外依赖，安卓/iOS 的 NSD 实现差异大；
///   · 广播内容只含 `id/name/port/platform`，**不带任何凭据**，同一网段任何人都能收到；
///     真正的流转请求走 HTTP `/flow`，由对端决定是否接受；
///   · 只做单向「我在这里」的公告 + 被动收集，不需要应答包：省一次往返，
///     且设备数量多时不会产生广播风暴（每 [announceInterval] 一次）。
class LanDiscovery {
  LanDiscovery({required this.deviceId, required this.deviceName});

  /// 固定端口：所有设备都往这个端口广播 / 监听，才能互相收到。
  static const int discoveryPort = 9981;

  static const Duration announceInterval = Duration(seconds: 5);

  /// 超过这个时间没收到公告就从列表里剔除（容忍丢几个广播包）。
  static const Duration deviceTtl = Duration(seconds: 18);

  final String deviceId;
  final String Function() deviceName;
  RawDatagramSocket? _socket;
  Timer? _timer;
  final Map<String, LanDevice> _devices = {};
  final StreamController<List<LanDevice>> _controller =
      StreamController<List<LanDevice>>.broadcast();

  /// 本机 HTTP 端口（LanServer 启动后设置；为 0 时不公告）。
  int localPort = 0;

  /// 平台标识，供对端在列表里展示图标。
  String platform = 'unknown';

  bool get running => _socket != null;

  /// 当前已知设备（按最近见到时间排序，自己排除在外）。
  List<LanDevice> get devices {
    final now = DateTime.now();
    final alive =
        _devices.values
            .where((d) => now.difference(d.lastSeenAt) < deviceTtl)
            .toList()
          ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return alive;
  }

  /// 设备列表变化时推送（界面订阅它刷新）。
  Stream<List<LanDevice>> get changes => _controller.stream;

  /// 是否处于「主动寻找」模式（用户打开了流转面板）。
  ///
  /// 区分两种运行态：
  ///   · **被动就绪**（[listenOnly]）：只监听别人的 probe 并应答，不广播。
  ///     应用启动后只要有局域网服务就进入这个状态，别的设备才找得到本机。
  ///   · **主动寻找**（[start]）：周期广播 probe，并在面板里列出发现的设备。
  bool _active = false;

  bool get active => _active;

  /// 进入被动监听：只应答 probe，不主动广播。
  ///
  /// 与 [start] 共用同一个 socket；已经 start 过就直接标记为 active。
  Future<bool> listenOnly() async {
    if (_socket != null) {
      _active = true;
      _timer?.cancel();
      _timer = Timer.periodic(announceInterval, (_) => probeNow());
      probeNow();
      return true;
    }
    final opened = await _openSocket();
    if (opened) {
      _active = true;
      _timer?.cancel();
      _timer = Timer.periodic(announceInterval, (_) => probeNow());
      probeNow();
    }
    return opened;
  }

  Future<bool> _openSocket() async {
    if (_socket != null) return true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      socket.broadcastEnabled = true;
      socket.listen(
        _onEvent,
        onError: (Object e) {
          AppLog.w('lan', '设备发现监听异常：$e');
        },
      );
      _socket = socket;
      return true;
    } catch (e) {
      AppLog.w('lan', '设备发现启动失败：$e');
      return false;
    }
  }

  Future<void> start() async {
    if (_socket != null) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      socket.broadcastEnabled = true;
      socket.listen(
        _onEvent,
        onError: (Object e) {
          AppLog.w('lan', '设备发现监听异常：$e');
        },
      );
      _socket = socket;
      // 打开面板期间周期广播「谁在？」：接收方只在被问到时才应答，
      // 所以本机不需要常驻公告，关掉面板就不再有任何广播。
      _timer = Timer.periodic(announceInterval, (_) => probeNow());
      probeNow();
      AppLog.i('lan', '设备发现已启动（UDP $discoveryPort）');
    } catch (e) {
      // 端口被占用等：不影响播放，只是发现不了设备。
      AppLog.w('lan', '设备发现启动失败：$e');
    }
  }

  /// 结束「主动寻找」：停止广播与设备列表刷新，但**保留 socket**。
  ///
  /// 保留是为了继续被动应答别人的 probe —— 否则本机在别人眼里就消失了。
  /// 真正关闭 socket 见 [close]。
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _active = false;
    _devices.clear();
    AppLog.i('lan', '设备发现已转为被动监听');
  }

  /// 彻底关闭（应用退出时调用）。
  Future<void> close() async {
    await stop();
    _socket?.close();
    _socket = null;
    AppLog.i('lan', '设备发现已关闭');
  }

  void dispose() {
    unawaited(close());
    unawaited(_controller.close());
  }

  /// 主动清掉某台设备（流转成功后从列表移除也可以，但通常保留更方便）。
  void forget(String id) {
    if (_devices.remove(id) != null) _emit();
  }

  /// 应答别人的「谁在？」探测。
  ///
  /// 流转是一次性操作：推送方点开面板时才广播 probe，接收方**只在被问到时**
  /// 回一条 announce。这样接收端不需要常驻广播，也能被找到。
  void _replyToProbe(Datagram probe) {
    final socket = _socket;
    if (socket == null || localPort <= 0) return;
    try {
      final payload = utf8.encode(
        jsonEncode({
          'app': 'MisaTV',
          'kind': 'flow-announce',
          'id': deviceId,
          'name': deviceName(),
          'port': localPort,
          'platform': platform,
        }),
      );
      // 只回给问的人，不做广播，避免打扰同网段其它设备。
      socket.send(payload, probe.address, discoveryPort);
    } catch (_) {
      // 单次应答失败无所谓，下次 probe 还会有机会。
    }
  }

  /// 主动广播一次「谁在？」（推送方打开面板时调用）。
  void probeNow() {
    final socket = _socket;
    if (socket == null) return;
    try {
      final payload = utf8.encode(
        jsonEncode({'app': 'MisaTV', 'kind': 'flow-probe', 'id': deviceId}),
      );
      socket.send(payload, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (e) {
      AppLog.w('lan', '设备探测发送失败：$e');
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    _onDatagram(datagram);
  }

  void _onDatagram(Datagram datagram) {
    try {
      final text = utf8.decode(datagram.data);
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      if (decoded['app'] != 'MisaTV') return;
      final kind = (decoded['kind'] ?? '').toString();
      if (kind == 'flow-probe') {
        // 别人在找设备：回一条 announce 给对方（不广播）。
        // 自己发的 probe 也会收到，忽略即可。
        if ((decoded['id'] ?? '').toString() != deviceId) {
          _replyToProbe(datagram);
        }
        return;
      }
      if (kind != 'flow-announce') return;
      final id = (decoded['id'] ?? '').toString();
      // 忽略自己的广播（同一台机器也可能收到自己的包）。
      if (id.isEmpty || id == deviceId) return;
      final port = (decoded['port'] as num?)?.toInt() ?? 0;
      if (port <= 0) return;
      final device = LanDevice(
        id: id,
        name: (decoded['name'] ?? 'MisaTV').toString(),
        // 用数据报来源地址而不是包里的字段：更可信，也避免伪造。
        host: datagram.address.address,
        port: port,
        platform: (decoded['platform'] ?? 'unknown').toString(),
        lastSeenAt: DateTime.now(),
      );
      final known = _devices[id];
      _devices[id] = device;
      // 只在「新设备」或「地址/端口变了」时通知界面，避免每 5 秒刷一次。
      if (known == null ||
          known.host != device.host ||
          known.port != device.port ||
          known.name != device.name) {
        _emit();
      }
    } catch (_) {
      // 非本应用的广播包，忽略。
    }
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(devices);
  }
}
