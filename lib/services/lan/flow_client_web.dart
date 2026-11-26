import 'flow_payload.dart';
import 'lan_discovery.dart';

/// Web 版桩：浏览器无法直接连接局域网设备，流转一律返回不可用。
class FlowClient {
  const FlowClient._();

  static Future<String?> push({
    required LanDevice device,
    required FlowPayload payload,
    Duration timeout = const Duration(seconds: 15),
  }) async => '浏览器版不支持设备流转，请使用桌面或移动端';
}
