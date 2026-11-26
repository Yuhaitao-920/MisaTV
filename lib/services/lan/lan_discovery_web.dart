import 'dart:async';

/// 局域网里一台可被流转的设备（Web 版不会产生任何设备）。
class LanDevice {
  const LanDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.platform,
    required this.lastSeenAt,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String platform;
  final DateTime lastSeenAt;

  String get baseUrl => 'http://$host:$port';
}

/// Web 版桩：浏览器不能开 UDP socket，因此永远发现不到设备。
///
/// 接口与 [LanDiscovery] 保持一致，调用方不需要写平台分支。
class LanDiscovery {
  LanDiscovery({required this.deviceId, required this.deviceName});

  static const int discoveryPort = 9981;
  static const Duration announceInterval = Duration(seconds: 5);
  static const Duration deviceTtl = Duration(seconds: 18);

  final String deviceId;
  final String Function() deviceName;

  int localPort = 0;
  String platform = 'web';

  bool get running => false;
  List<LanDevice> get devices => const [];
  Stream<List<LanDevice>> get changes => const Stream.empty();

  Future<void> start() async {}
  Future<void> stop() async {}
  void dispose() {}
  void forget(String id) {}
}
