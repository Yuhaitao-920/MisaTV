import 'dart:async';
import 'dart:io';

import '../../core/logging/app_log.dart';
import 'flow_payload.dart';
import 'lan_discovery.dart';
import 'lan_server.dart';

/// 设备流转的客户端：把当前播放推给局域网另一台设备。
class FlowClient {
  const FlowClient._();

  /// 把 [payload] 推给 [device]。
  ///
  /// 返回 null 表示成功；否则返回失败原因（可直接展示给用户）。
  /// 超时给 15 秒：对端可能要弹确认框，用户点一下需要时间。
  static Future<String?> push({
    required LanDevice device,
    required FlowPayload payload,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final url = '${device.baseUrl}/flow';
    AppLog.i(
      'lan',
      '推送流转到 ${device.name} (${device.baseUrl})：'
          '《${payload.vodName}》第 ${payload.episodeIndex + 1} 集',
    );
    try {
      final res = await LanClient.postJson(
        url,
        payload.toJson(),
        timeout: timeout,
      );
      final accepted = res['accepted'] == true;
      final message = (res['message'] ?? '').toString();
      if (!accepted) {
        AppLog.w('lan', '对端拒绝接受流转：$message');
        return message.isEmpty ? '对方拒绝了这次流转' : message;
      }
      AppLog.i('lan', '流转已送达 ${device.name}');
      return null;
    } on TimeoutException {
      AppLog.w('lan', '推送到 ${device.name} 超时');
      return '对方没有及时响应，可能不在播放器界面或已休眠';
    } on SocketException catch (e) {
      AppLog.w('lan', '推送到 ${device.name} 网络失败：${e.message}');
      return '连不上对方设备（${e.message}）';
    } catch (e) {
      AppLog.w('lan', '推送到 ${device.name} 失败', e);
      return '推送失败：$e';
    }
  }
}
