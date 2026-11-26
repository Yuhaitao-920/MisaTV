part of '../player_page.dart';

/// 设备流转：把当前正在播的这一集交给局域网里另一台 MisaTV。
///
/// 由 [player_page.dart] 的 part 拆出，仍可访问 State 私有成员。
extension _PlayerFlowExt on _PlayerPageState {
  /// 打开「流转到其他设备」面板。
  Future<void> _flowToDevice() async {
    final current = _currentPlay;
    if (current == null || current.url.trim().isEmpty) {
      _toast('还没有可流转的播放地址');
      return;
    }
    final app = _app;
    // 没开启时先启动：设备发现需要一个 UDP 监听 + HTTP 服务。
    if (!app.flowReady) {
      try {
        await app.startFlow();
      } catch (e) {
        _toast('设备流转启动失败：$e');
        return;
      }
    }
    if (!mounted) return;
    final device = await showFlowDeviceSheet(
      context,
      devices: app.lanDiscovery,
      selfName: app.syncDeviceName,
    );
    if (device == null) {
      // 取消了：流转是一次性的，收起发现，不留后台广播。
      await app.stopFlow();
      return;
    }
    if (!mounted) {
      await app.stopFlow();
      return;
    }

    final source = app.preparePlay(current, forceRelay: true);
    final payload = FlowPayload(
      vodName: _detail.name,
      episodeName: _episodeName,
      episodeIndex: _index,
      url: source.url,
      fromDevice: app.syncDeviceName,
      flag: _flag,
      positionMs: _position.inMilliseconds,
      headers: source.headers,
      pic: _detail.pic,
      sourceName: _site.displayName,
      sourceKey: _detail.sourceKey,
      vodId: _detail.id,
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _toast('正在推送到 ${device.name}…');
    final error = await FlowClient.push(device: device, payload: payload);
    // 无论成败都收起：一次流转用一次，不常驻广播。
    await app.stopFlow();
    if (!mounted) return;
    if (error != null) {
      _toast('流转失败：$error');
      return;
    }
    // 推送成功后结束本机播放：用户意图是「换到那台设备上继续看」，
    // 两台同时播会互相干扰（尤其是同一网盘账号的并发限制）。
    AppLog.i('lan', '流转已送达 ${device.name}，退出本机播放器');
    _toast('已在 ${device.name} 上开始播放');
    await _exitPage();
  }
}

/// 设备选择面板：列出局域网里在线的 MisaTV，点击即流转。
Future<LanDevice?> showFlowDeviceSheet(
  BuildContext context, {
  required LanDiscovery devices,
  required String selfName,
}) {
  return showModalBottomSheet<LanDevice>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _FlowDeviceSheet(devices: devices, selfName: selfName),
  );
}

class _FlowDeviceSheet extends StatefulWidget {
  const _FlowDeviceSheet({required this.devices, required this.selfName});

  final LanDiscovery devices;
  final String selfName;

  @override
  State<_FlowDeviceSheet> createState() => _FlowDeviceSheetState();
}

class _FlowDeviceSheetState extends State<_FlowDeviceSheet> {
  late List<LanDevice> _list = widget.devices.devices;
  StreamSubscription<List<LanDevice>>? _sub;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // 边等边刷：设备可能在面板打开之后才公告上来。
    _sub = widget.devices.changes.listen((list) {
      if (mounted) setState(() => _list = list);
    });
    // 过期剔除是靠时间判断的，没有事件也要定期刷新一次，否则离线的设备会一直挂着。
    _tick = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      final next = widget.devices.devices;
      if (next.length != _list.length) setState(() => _list = next);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  IconData _iconOf(String platform) => switch (platform) {
    'android' => Icons.phone_android_rounded,
    'macos' => Icons.laptop_mac_rounded,
    'linux' => Icons.computer_rounded,
    'web' => Icons.language_rounded,
    _ => Icons.desktop_windows_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('流转到其他设备', style: theme.textTheme.titleLarge),
                const Spacer(),
                Text(
                  _list.isEmpty ? '搜索中…' : '${_list.length} 台设备',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '把当前这一集推到同一局域网的 MisaTV 上继续播。'
              '推送成功后本机会退出播放。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            if (_list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Column(
                  children: [
                    const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    const SizedBox(height: 14),
                    Text('正在查找局域网里的 MisaTV…', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 6),
                    Text(
                      '目标设备也需要打开播放器并进入本面板一次，'
                      '或者已开启过设备流转。\n'
                      '若一直找不到，检查两台设备是否在同一网段、'
                      '防火墙是否拦截了 UDP $LanDiscovery.discoveryPort。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final device = _list[i];
                    final online =
                        DateTime.now().difference(device.lastSeenAt).inSeconds <
                        6;
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      tileColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      leading: Icon(_iconOf(device.platform)),
                      title: Text(device.name),
                      subtitle: Text(
                        '${device.baseUrl} · '
                        '${online ? '在线' : '刚离线'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.north_east_rounded, size: 18),
                      onTap: () => Navigator.of(context).pop(device),
                    );
                  },
                ),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
