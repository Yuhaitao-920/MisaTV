import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../services/uc_tv_token_service.dart';

/// UC TV 授权：扫码后把 token 对写入本机（非会员 UC 原画所需）。
Future<bool?> showUcTvLoginDialog(BuildContext context) => showDialog<bool>(
  context: context,
  barrierDismissible: true,
  builder: (_) => const _UcTvLoginDialog(),
);

class _UcTvLoginDialog extends StatefulWidget {
  const _UcTvLoginDialog();

  @override
  State<_UcTvLoginDialog> createState() => _UcTvLoginDialogState();
}

class _UcTvLoginDialogState extends State<_UcTvLoginDialog> {
  final UcTvTokenService _service = UcTvTokenService();
  UcTvQrSession? _session;
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  bool _expired = false;
  String _status = '正在获取二维码…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _service.close();
    super.dispose();
  }

  Future<void> _start() async {
    _timer?.cancel();
    setState(() {
      _busy = true;
      _expired = false;
      _error = null;
      _session = null;
      _status = '正在获取二维码…';
    });
    try {
      final app = AppScope.of(context);
      final saved = app.driveAccounts['uc']?.extra['uctvDeviceId'] ?? '';
      final deviceId = saved.isNotEmpty
          ? saved
          : UcTvTokenService.newDeviceId();
      final session = await _service.create(deviceId: deviceId);
      if (!mounted) return;
      setState(() {
        _session = session;
        _busy = false;
        _status = '请用 UC 浏览器或 UC 网盘 App 扫码授权';
      });
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _poll() async {
    final session = _session;
    if (session == null || _polling || _expired) return;
    _polling = true;
    try {
      final result = await _service.poll(session);
      if (!mounted) return;
      switch (result.state) {
        case UcTvPollState.ok:
          _timer?.cancel();
          final exchanged = await _service.exchange(session, result.code ?? '');
          if (!mounted) return;
          if (!exchanged.ok) {
            setState(() {
              _error = exchanged.hint;
              _expired = true;
            });
            return;
          }
          final app = AppScope.of(context);
          final existing = app.driveAccounts['uc'];
          await app.saveDriveAccount(
            'uc',
            existing?.cookie ?? '',
            username: existing?.username,
            extra: {
              'uctvToken': exchanged.token ?? '',
              'uctvDeviceId': session.deviceId,
            },
          );
          if (!mounted) return;
          Navigator.of(context).pop(true);
          return;
        case UcTvPollState.expired:
          _timer?.cancel();
          setState(() {
            _expired = true;
            _status = result.hint ?? '二维码已过期，请刷新';
          });
        case UcTvPollState.error:
          setState(() => _error = result.hint);
        case UcTvPollState.wait:
          break;
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = _session;
    return AlertDialog(
      title: const Text('UC TV 授权'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: CircularProgressIndicator(),
              )
            else if (session != null)
              Container(
                width: 230,
                height: 230,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.memory(
                  base64Decode(session.imageDataUrl.split(',').last),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.qr_code_2_rounded, size: 160),
                ),
              ),
            if (session != null) ...[
              const SizedBox(height: 12),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _expired ? theme.colorScheme.error : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '授权后写回本机，供需要 UC 电视端令牌的源使用',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
        FilledButton.tonal(
          onPressed: _busy ? null : _start,
          child: Text(_expired ? '刷新二维码' : '重新获取'),
        ),
      ],
    );
  }
}
