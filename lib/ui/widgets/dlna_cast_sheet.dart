import 'package:flutter/material.dart';

import '../../services/dlna/dlna.dart';
import '../../services/dlna/dlna_service.dart';

/// 投屏设备选择面板：SSDP 搜一遍局域网，点一台即投。
Future<void> showDlnaCastSheet(
  BuildContext context, {
  required DlnaCastTarget target,
  String Function(String davId)? davAuth,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
        child: DlnaCastPanel(target: target, davAuth: davAuth),
      ),
    ),
  );
}

class DlnaCastPanel extends StatefulWidget {
  const DlnaCastPanel({super.key, required this.target, this.davAuth});

  final DlnaCastTarget target;
  final String Function(String davId)? davAuth;

  @override
  State<DlnaCastPanel> createState() => _DlnaCastPanelState();
}

class _DlnaCastPanelState extends State<DlnaCastPanel> {
  bool _loading = true;
  List<DlnaDevice> _devices = const [];
  String _busyUdn = '';

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _devices = const [];
    });
    final devices = await DlnaService.instance.discover();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _devices = devices;
    });
  }

  Future<void> _cast(DlnaDevice device) async {
    if (_busyUdn.isNotEmpty) return;
    setState(() => _busyUdn = device.udn);
    var target = widget.target;
    final davId = target.davId;
    if (davId.isNotEmpty) {
      final auth = widget.davAuth?.call(davId) ?? '';
      if (auth.isNotEmpty && !target.headers.containsKey('Authorization')) {
        target = DlnaCastTarget(
          url: target.url,
          name: target.name,
          positionMs: target.positionMs,
          headers: {...target.headers, 'Authorization': auth},
          davId: target.davId,
          localRelay: target.localRelay,
        );
      }
    }
    final result = await DlnaService.instance.cast(device, target);
    if (!mounted) return;
    setState(() => _busyUdn = '');
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (result.ok) {
      messenger?.showSnackBar(SnackBar(content: Text('已投到「${result.device}」')));
      Navigator.of(context).pop();
    } else {
      messenger?.showSnackBar(
        SnackBar(content: Text(result.error.isEmpty ? '投屏失败' : result.error)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('投屏到电视', style: theme.textTheme.titleLarge)),
            IconButton(
              tooltip: '重新搜索',
              onPressed: _loading ? null : _search,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        Text(
          widget.target.localRelay
              ? '当前地址由本机中继提供（磁力/代理），电视端可能拉不到流。'
              : '同一局域网内的 DLNA / UPnP 电视与盒子会出现在下面。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('正在搜索局域网设备…'),
              ],
            ),
          )
        else if (_devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('没有找到可投屏的设备', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text(
                  '确认电视已开机并连到同一 Wi-Fi / 局域网；部分电视需要先打开「多屏互动 / DLNA」。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          )
        else
          ..._devices.map(
            (device) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _busyUdn == device.udn
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.tv_rounded),
              title: Text(device.name),
              subtitle: Text(
                device.location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _busyUdn.isEmpty ? () => _cast(device) : null,
            ),
          ),
      ],
    );
  }
}
