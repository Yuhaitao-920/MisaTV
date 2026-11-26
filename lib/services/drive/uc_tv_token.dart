import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

/// UC 电视端开放平台 OAuth 扫码：产出 `Wex_ucpan_token`（非会员 UC 原画所需）。
///
/// 协议来自 TVBox wex 系 jar 的扫码流：
///   1. GET  /oauth/authorize → { status:0, req_id, query_token, qr_data(base64 PNG) }
///   2. GET  /oauth/code      → status=0 & code 即授权成功（11003 = 未确认）
///   3. POST api.extscreen.com/ucdrive/token → 原样保存响应体
class UcTvTokenService {
  UcTvTokenService();

  static const _secret = '&l3srvtd7p42l0d0x1u8d7yc8ye9kki4d';
  static const _clientId = '5acf882d27b74502b7040b0c65519aa7';
  static const _ua =
      'Mozilla/5.0 (Linux; U; Android 12; zh-cn; V2238A Build/V417IR) '
      'AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1';
  static const _authorizeUrl = 'https://open-api-drive.uc.cn/oauth/authorize';
  static const _codeUrl = 'https://open-api-drive.uc.cn/oauth/code';
  static const _exchangeUrl = 'http://api.extscreen.com/ucdrive/token';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  void close() => _client.close(force: true);

  static String newDeviceId([DateTime? now]) {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return crypto.md5.convert(utf8.encode('$ts')).toString();
  }

  static String _reqId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String _sign(String method, String path, int ts) {
    return crypto.sha256
        .convert(utf8.encode('$method&$path&$ts$_secret'))
        .toString();
  }

  Map<String, String> _headers(String method, String path) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return {
      'User-Agent': _ua,
      'x-pan-tm': '$ts',
      'x-pan-token': _sign(method, path, ts),
      'content-type': 'text/plain;charset=UTF-8',
      'x-pan-client-id': _clientId,
    };
  }

  Future<UcTvQrSession> create({required String deviceId}) async {
    final reqId = _reqId();
    final query = _query({
      'req_id': reqId,
      'access_token': '',
      'app_ver': '1.6.8',
      'device_id': deviceId,
      'device_brand': 'Xiaomi',
      'platform': 'tv',
      'device_name': '22081212C',
      'device_model': '22081212C',
      'build_device': 'star2qltechn',
      'build_product': '22081212C',
      'device_gpu': 'Adreno (TM) 640',
      'activity_rect': '{}',
      'channel': 'UCTVOFFICIALWEB',
      'auth_type': 'code',
      'client_id': _clientId,
      'scope': 'netdisk',
      'qrcode': '1',
      'qr_width': '460',
      'qr_height': '460',
    });
    final json = await _getJson(
      '$_authorizeUrl?$query',
      headers: _headers('GET', '/oauth/authorize'),
    );
    final status = _int(json?['status'], -1);
    final qr = (json?['qr_data'] ?? '').toString().replaceAll(
      RegExp(r'[\r\n]'),
      '',
    );
    final queryToken = (json?['query_token'] ?? '').toString();
    if (status != 0 || qr.isEmpty || queryToken.isEmpty) {
      throw UcTvException('UC TV 取码失败：${json?['error_info'] ?? '响应异常'}');
    }
    return UcTvQrSession(
      reqId: reqId,
      queryToken: queryToken,
      deviceId: deviceId,
      imageDataUrl: 'data:image/png;base64,$qr',
    );
  }

  Future<UcTvPollResult> poll(UcTvQrSession session) async {
    final query = _query({
      'req_id': session.reqId,
      'access_token': '',
      'app_ver': '1.6.8',
      'device_id': session.deviceId,
      'device_brand': 'Xiaomi',
      'platform': 'tv',
      'device_name': '22081212C',
      'device_model': '22081212C',
      'build_device': 'star2qltechn',
      'build_product': '22081212C',
      'device_gpu': 'Adreno (TM) 640',
      'activity_rect': '{}',
      'channel': 'UCTVOFFICIALWEB',
      'client_id': _clientId,
      'scope': 'netdisk',
      'query_token': session.queryToken,
    });
    final json = await _getJson(
      '$_codeUrl?$query',
      headers: _headers('GET', '/oauth/code'),
    );
    if (json == null) return const UcTvPollResult.error('UC TV 轮询失败');
    final status = _int(json['status'], -1);
    final code = (json['code'] ?? '').toString();
    if (status == 0 && code.isNotEmpty) return UcTvPollResult.ok(code);
    final errno = _int(json['errno'], 0);
    final info = (json['error_info'] ?? '').toString();
    if (errno == 11003 || info.contains('未确认')) {
      return const UcTvPollResult.wait();
    }
    if (info.contains('过期') || info.contains('失效')) {
      return UcTvPollResult.expired(info.isEmpty ? '二维码已过期，请刷新' : info);
    }
    return UcTvPollResult.error(info.isEmpty ? '轮询异常（status=$status）' : info);
  }

  Future<UcTvExchangeResult> exchange(
    UcTvQrSession session,
    String code,
  ) async {
    final body = jsonEncode({
      'req_id': session.reqId,
      'app_ver': '1.6.8',
      'device_id': session.deviceId,
      'device_brand': 'Xiaomi',
      'platform': 'tv',
      'device_name': '22081212C',
      'device_model': '22081212C',
      'build_device': 'star2qltechn',
      'build_product': '22081212C',
      'device_gpu': 'Adreno (TM) 640',
      'activity_rect': '%7B%7D',
      'channel': 'UCTVOFFICIALWEB',
      'code': code,
    });
    try {
      final req = await _client
          .postUrl(Uri.parse(_exchangeUrl))
          .timeout(const Duration(seconds: 20));
      req.headers.set('User-Agent', _ua);
      req.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(utf8.decoder).join();
      final json = _tryJson(text);
      final data = json?['data'];
      final access = data is Map ? (data['access_token'] ?? '').toString() : '';
      final refresh = data is Map
          ? (data['refresh_token'] ?? '').toString()
          : '';
      if (access.isNotEmpty && refresh.isNotEmpty) {
        return UcTvExchangeResult.ok(text);
      }
      final info =
          data is Map && (data['error_info'] ?? '').toString().isNotEmpty
          ? data['error_info'].toString()
          : (json?['message'] ?? 'HTTP ${res.statusCode}').toString();
      return UcTvExchangeResult.error('UC TV 兑换失败：$info');
    } catch (e) {
      return UcTvExchangeResult.error('UC TV 兑换请求失败：$e');
    }
  }

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final req = await _client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    headers.forEach((k, v) => req.headers.set(k, v));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    return _tryJson(text);
  }

  static String _query(Map<String, String> params) {
    return params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
  }

  static Map<String, dynamic>? _tryJson(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static int _int(dynamic value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

class UcTvQrSession {
  const UcTvQrSession({
    required this.reqId,
    required this.queryToken,
    required this.deviceId,
    required this.imageDataUrl,
  });

  final String reqId;
  final String queryToken;
  final String deviceId;
  final String imageDataUrl;
}

class UcTvPollResult {
  const UcTvPollResult._(this.state, {this.code, this.hint});

  const UcTvPollResult.wait() : this._(UcTvPollState.wait);
  const UcTvPollResult.ok(String code) : this._(UcTvPollState.ok, code: code);
  const UcTvPollResult.expired(String hint)
    : this._(UcTvPollState.expired, hint: hint);
  const UcTvPollResult.error(String hint)
    : this._(UcTvPollState.error, hint: hint);

  final UcTvPollState state;
  final String? code;
  final String? hint;
}

enum UcTvPollState { wait, ok, expired, error }

class UcTvExchangeResult {
  const UcTvExchangeResult._(this.ok, {this.token, this.hint});

  const UcTvExchangeResult.ok(String token) : this._(true, token: token);
  const UcTvExchangeResult.error(String hint) : this._(false, hint: hint);

  final bool ok;
  final String? token;
  final String? hint;
}

class UcTvException implements Exception {
  const UcTvException(this.message);
  final String message;

  @override
  String toString() => message;
}
