import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dlna.dart';

/// DLNA 投屏的网络部分：SSDP 组播发现 + 设备描述拉取 + AVTransport 动作链。
///
/// 纯逻辑（报文/解析）在 `dlna.dart`；本文件只碰 socket 与 HTTP。
class DlnaService {
  DlnaService({this.logger});

  /// 诊断日志（应用里接到调试输出；单测可留空）。
  final void Function(String message)? logger;

  static final DlnaService instance = DlnaService();

  /// SSDP 发现窗口：发 3 次 M-SEARCH，收 3 秒（与上游一致）。
  static const Duration defaultTimeout = Duration(seconds: 3);

  /// SSDP 发现局域网 MediaRenderer（去重后返回；失败只记日志，返回空列表）。
  Future<List<DlnaDevice>> discover({Duration timeout = defaultTimeout}) async {
    final locations = <String>[];
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      try {
        socket.multicastHops = 4; // DLNA 惯例：不让发现包跑过本网段
      } catch (_) {
        // 部分环境不支持 → 忽略
      }
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        final parsed = parseSsdpResponse(
          utf8.decode(datagram.data, allowMalformed: true),
        );
        if (parsed == null) return;
        if (!locations.contains(parsed.location)) {
          locations.add(parsed.location);
        }
      });
      final payload = utf8.encode(buildSearchRequest());
      final group = InternetAddress(ssdpAddress);
      for (var i = 0; i < 3; i++) {
        try {
          socket.send(payload, group, ssdpPort);
        } catch (_) {
          // 发送失败（无网卡/权限）→ 继续等接收
        }
      }
      await Future<void>.delayed(timeout);
    } catch (e) {
      logger?.call('投屏: SSDP 发现失败 $e');
    } finally {
      await subscription?.cancel();
      socket?.close();
    }

    final devices = <DlnaDevice>[];
    for (final location in locations) {
      final device = await fetchDevice(location);
      if (device == null) continue;
      if (devices.any((d) => d.udn == device.udn)) continue;
      devices.add(device);
    }
    logger?.call('投屏: 发现 ${locations.length} 个应答 / ${devices.length} 台可投设备');
    return devices;
  }

  /// 拉取并解析设备描述（失败返回 null）。
  Future<DlnaDevice?> fetchDevice(String location) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(location));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await res.transform(utf8.decoder).join();
      final device = parseDeviceDescription(text, location);
      if (device == null) logger?.call('投屏: 设备描述无 AVTransport（跳过）：$location');
      return device;
    } catch (e) {
      logger?.call('投屏: 设备描述拉取失败 $location — $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 投屏动作链：`SetAVTransportURI` 成功才 `Play`；
  /// `Play` 成功且位置 > 0 才 `Seek REL_TIME`，Seek 失败只记日志、不影响「投屏成功」判定。
  Future<DlnaCastResult> cast(DlnaDevice device, DlnaCastTarget target) async {
    final control = combineUrl(device.location, device.controlUrl);
    final first = await _post(
      control,
      'SetAVTransportURI',
      buildSetUriBody(target.url, buildMetaData(target)),
    );
    if (!first.ok) {
      return DlnaCastResult(ok: false, error: '设备拒绝了播放地址：${first.error}');
    }
    final played = await _post(control, 'Play', buildPlayBody());
    if (!played.ok) {
      return DlnaCastResult(ok: false, error: '已送达但起播失败：${played.error}');
    }
    if (target.positionMs > 0) {
      final seek = await _post(
        control,
        'Seek',
        buildSeekBody(formatMs(target.positionMs)),
      );
      if (!seek.ok) logger?.call('投屏: Seek 被忽略（继续按当前进度播）: ${seek.error}');
    }
    logger?.call(
      '投屏: 已投到「${device.name}」（${target.url.length > 100 ? target.url.substring(0, 100) : target.url}）',
    );
    return DlnaCastResult(ok: true, device: device.name);
  }

  Future<({bool ok, String error})> _post(
    String controlUrl,
    String action,
    String body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse(controlUrl));
      req.headers.set(HttpHeaders.contentTypeHeader, 'text/xml; charset=utf-8');
      req.headers.set('SOAPACTION', soapActionHeader(action));
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return (ok: true, error: '');
      }
      return (ok: false, error: 'HTTP ${res.statusCode}');
    } catch (e) {
      return (ok: false, error: '$e');
    } finally {
      client.close(force: true);
    }
  }
}
