import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../services/torrent/xunlei_cloud.dart';

/// 迅雷安全验证页（应用内 WebView）。
///
/// 账号密码登录触发 `review_panel` 后，短信收不到时可以用这里完成验证；
/// 验证成功后关闭弹窗，调用方重新走一次密码登录即可（设备已被信任）。
Future<bool> showXunleiVerifyDialog(
  BuildContext context, {
  required String reviewUrl,
  required String deviceId,
}) async {
  final sign = xunleiDeviceSign(deviceId.trim());
  final url = xunleiReviewUrlWithDevice(reviewUrl, deviceId);
  if (url.isEmpty) return false;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _XunleiVerifyDialog(url: url, deviceSign: sign),
  );
  return result == true;
}

class _XunleiVerifyDialog extends StatefulWidget {
  const _XunleiVerifyDialog({required this.url, required this.deviceSign});
  final String url;
  final String deviceSign;

  @override
  State<_XunleiVerifyDialog> createState() => _XunleiVerifyDialogState();
}

class _XunleiVerifyDialogState extends State<_XunleiVerifyDialog> {
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _done = false;
  String _error = '';

  bool _isCallback(WebUri? uri) {
    final scheme = (uri?.scheme ?? '').toLowerCase();
    final host = (uri?.host ?? '').toLowerCase();
    return scheme == 'xlaccsdk01' &&
        host == 'xunlei.com' &&
        (uri?.path ?? '') == '/callback';
  }

  bool _trustedPage(WebUri? uri) {
    final scheme = (uri?.scheme ?? '').toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    final host = (uri?.host ?? '').toLowerCase();
    return host == 'xunlei.com' || host.endsWith('.xunlei.com');
  }

  Future<void> _inject() async {
    final controller = _controller;
    if (controller == null) return;
    final pkg = jsonEncode(xunleiPackageName);
    // 验证页用的是 8.31 壳的身份（XlCaptcha.init 的 appName/clientVersion
    // 必须与 reviewurl 里的 App 一致），不是 v3/login 的新版 25.0.5.25。
    final version = jsonEncode(xunleiClientVersion);
    final device = jsonEncode(widget.deviceSign);
    final script =
        '''
(function(){
  try {
    window.env = 'android';
    window.appid = '40';
    window.appName = $pkg;
    window.clientVersion = $version;
    window.deviceid = $device;
    window.platformVersion = '10';
    window.event = 'login3';
  } catch(e) {}
  try {
    window.XLJSWebViewBridge = {
      onVerifyResult: function(res){
        try { window.flutter_inappwebview.callHandler('xunleiVerifyResult', JSON.stringify(res || {})); } catch(e) {}
      },
      close: function(){
        try { window.flutter_inappwebview.callHandler('xunleiVerifyResult', '__close__'); } catch(e) {}
      }
    };
  } catch(e) {}
  function fire(){
    if (window.__xunleiInited) return true;
    if (window.XlCaptcha && typeof window.XlCaptcha.init === 'function') {
      try {
        if (typeof window.XlCaptcha.isMobileSDK !== 'function') {
          window.XlCaptcha.isMobileSDK = function(){ return false; };
        }
        window.XlCaptcha.init({
          appid: '40',
          appName: $pkg,
          clientVersion: $version,
          deviceid: $device,
          event: 'login3',
          platformVersion: '10',
          IFRAME_BOX_ID: 'captch-wrap',
          VERTIFYSUCCFUNC: function(res){
            try { window.XLJSWebViewBridge.onVerifyResult(res); } catch(e) {}
          }
        });
        window.__xunleiInited = true;
        return true;
      } catch(e) {}
    }
    return false;
  }
  if (!fire()) {
    var timer = setInterval(function(){ if (fire()) { clearInterval(timer); } }, 120);
    setTimeout(function(){ clearInterval(timer); }, 10000);
  }
})();
''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (_) {}
  }

  void _finish(bool ok) {
    if (!mounted || _done) return;
    _done = true;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = '验证页加载失败，请改用短信验证码');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('迅雷安全验证')),
          if (_loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 620,
        child: Column(
          children: [
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    userAgent: xunleiUserAgent,
                    supportMultipleWindows: false,
                  ),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'xunleiVerifyResult',
                      callback: (args) {
                        final raw = args.isEmpty ? '' : '${args.first}';
                        if (raw == '__close__') {
                          _finish(false);
                          return;
                        }
                        _finish(true);
                      },
                    );
                  },
                  // Windows 插件 0.6.0 的权限回调不判空，Dart 返回 null 会闪退。
                  onPermissionRequest: (controller, request) async =>
                      PermissionResponse(action: PermissionResponseAction.DENY),
                  onLoadStart: (controller, url) {
                    if (_isCallback(url)) {
                      controller.stopLoading();
                      _finish(true);
                      return;
                    }
                    if (!_trustedPage(url)) {
                      controller.stopLoading();
                      _finish(false);
                    }
                  },
                  onLoadStop: (controller, url) async {
                    if (mounted) setState(() => _loading = false);
                    if (_trustedPage(url)) await _inject();
                  },
                  onReceivedError: (controller, request, error) {
                    if (request.isForMainFrame ?? true) {
                      if (mounted) setState(() => _loading = false);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在迅雷验证页完成短信/安全验证后，会自动回到登录流程。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
