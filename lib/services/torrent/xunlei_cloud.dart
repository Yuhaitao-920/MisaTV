import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../models/xunlei_account.dart';
import '../local_store.dart';
import 'magnet.dart';

/// 迅雷云盘接口地址。
const String xunleiApiBase = 'https://api-pan.xunlei.com/drive/v1';
const String xunleiUserBase = 'https://xluser-ssl.xunlei.com/v1';
const String xunleiCoreLoginUrl =
    'https://xluser-ssl.xunlei.com/xluser.core.login/v3/login';

const String xunleiClientId = 'Xp6vsxz_7IYVw2BB';
const String xunleiClientSecret = 'Xp6vsy4tN9toTVdMSpomVdXpRmES';
const String xunleiClientVersion = '8.31.0.9726';
const String xunleiPackageName = 'com.xunlei.downloadprovider';
const String xunleiAppId = '40';
const String xunleiAppKey = '34a062aaa22f906fca4fefe9fb3a3021';
const String xunleiUserAgent =
    'ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G '
    'appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC '
    'OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 '
    'Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)';
const String xunleiDownloadUserAgent =
    'Dalvik/2.1.0 (Linux; U; Android 12; M2004J7AC Build/SP1A.210812.016)';
const String xunleiCoreUserAgent =
    'android-ok-http-client/xl-acc-sdk/version-5.0.12.512000';

/// 账号密码登录（v3/login）使用的新版 App 身份（对齐官方抓包）。
const String xunleiLoginClientVersion = '25.0.5.25';
const String xunleiLoginSdkVersion = '513006';
const String xunleiLoginUserAgent =
    'android-ok-http-client/xl-acc-sdk/version-5.1.3.513006';

/// 短信验证码接口使用的 App 身份（对齐官方抓包）。
const String xunleiSmsClientVersion = '8.31.0.9726';
const String xunleiSmsSdkVersion = '231500';
const String xunleiSmsUserAgent =
    'android-ok-http-client/xl-acc-sdk/version-5.0.12.512000';

const String xunleiSendSmsUrl =
    'https://xluser-ssl.xunlei.com/xluser.core.login/v3/sendsms';
const String xunleiSmsLoginUrl =
    'https://xluser-ssl.xunlei.com/xluser.core.login/v3/smslogin';

/// 验证码签名链（顺序固定，前一项的输出拼上下一段盐再哈希）。
const List<String> xunleiCaptchaAlgorithms = [
  '9uJNVj/wLmdwKrJaVj/omlQ',
  'Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf',
  'Eb+L7Ce+Ej48u',
  'jKY0',
  'ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd',
  'wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK',
  'gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O',
  '5IiCoM9B1/788ntB',
  'P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf',
  '+oK0AN',
];

String _md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

String _sha1Hex(String input) => sha1.convert(utf8.encode(input)).toString();

/// 32 位十六进制设备号；未登录过的账号首次登录时生成并持久化。
String xunleiRandomDeviceId([Random? random]) {
  final rnd = random ?? Random.secure();
  final out = StringBuffer();
  for (var i = 0; i < 32; i++) {
    out.write(rnd.nextInt(16).toRadixString(16));
  }
  return out.toString();
}

/// `div101.<deviceId><md5(sha1(deviceId+packageName+appid+appKey))>`。
String xunleiDeviceSign(String deviceId) {
  final base = '$deviceId$xunleiPackageName$xunleiAppId$xunleiAppKey';
  final hash = _md5Hex(_sha1Hex(base));
  return 'div101.$deviceId$hash';
}

/// 验证码 token 的签名（`timestamp` 毫秒 + `1.<多轮 md5>`）。
({String timestamp, String sign}) xunleiCaptchaSign({
  required String deviceId,
  int? nowMs,
}) {
  final timestamp = (nowMs ?? DateTime.now().millisecondsSinceEpoch).toString();
  var text =
      '$xunleiClientId$xunleiClientVersion$xunleiPackageName$deviceId$timestamp';
  for (final algorithm in xunleiCaptchaAlgorithms) {
    text = _md5Hex('$text$algorithm');
  }
  return (timestamp: timestamp, sign: '1.$text');
}

/// 登录验证码初始化时携带的账号信息（手机号 / 邮箱 / 用户名三选一）。
Map<String, String> xunleiLoginMeta(String username) {
  final value = username.trim();
  final meta = <String, String>{};
  if (RegExp(r'^\w+([-+.]\w+)*@\w+([-.]\w+)*\.\w+([-.]\w+)*$')
      .hasMatch(value)) {
    meta['email'] = value;
  } else if (value.length >= 11 && value.length <= 18) {
    meta['phone_number'] = value;
  } else {
    meta['username'] = value;
  }
  return meta;
}

/// 接口动作：`方法:路径`（不含域名与 query）。
String xunleiAction(String method, String url) {
  final path = Uri.tryParse(url)?.path ?? '';
  return '$method:$path';
}

/// 登录中间结果。
///
/// [needSms] 为 true 表示账号密码登录触发了迅雷安全验证（`review_panel` /
/// `errorCode=1007` / `verifyType`），需要走 `sendsms` → `smslogin` 短信流。
class XunleiLoginStep {
  const XunleiLoginStep({
    this.needSms = false,
    this.creditKey = '',
    this.smsToken = '',
    this.reviewUrl = '',
    this.sessionId = '',
    this.nickName = '',
    this.userId = '',
    this.message = '',
    this.account,
  });

  final bool needSms;

  /// `sendsms` 返回的信任密钥（也会从 reviewurl 的 query 里预填）。
  final String creditKey;

  /// `sendsms` 返回的短信 token。
  final String smsToken;

  /// 验证面板地址；短信收不到时可在浏览器里完成验证后重试登录。
  final String reviewUrl;
  final String sessionId;
  final String nickName;
  final String userId;
  final String message;

  /// 已完成令牌交换的账号；非空表示登录成功。
  final XunleiAccount? account;

  bool get success => account != null;

  XunleiLoginStep copyWith({
    bool? needSms,
    String? creditKey,
    String? smsToken,
    String? reviewUrl,
    String? sessionId,
    String? nickName,
    String? userId,
    String? message,
    XunleiAccount? account,
  }) => XunleiLoginStep(
    needSms: needSms ?? this.needSms,
    creditKey: creditKey ?? this.creditKey,
    smsToken: smsToken ?? this.smsToken,
    reviewUrl: reviewUrl ?? this.reviewUrl,
    sessionId: sessionId ?? this.sessionId,
    nickName: nickName ?? this.nickName,
    userId: userId ?? this.userId,
    message: message ?? this.message,
    account: account ?? this.account,
  );
}

/// 解析 `v3/login` / `v3/smslogin` 的响应。
XunleiLoginStep parseXunleiLoginResponse(Map<String, dynamic> json) {
  final error = _textOf(json['error']);
  final errorCode = _textOf(json['errorCode'] ?? json['error_code']);
  final verifyType = _textOf(json['verifyType']);
  if (error == 'success' || errorCode == '0') {
    return XunleiLoginStep(
      sessionId: _textOf(json['sessionID'] ?? json['sessionId']),
      nickName: _textOf(json['nickName']),
      userId: _textOf(json['userID'] ?? json['user_id']),
      message: '登录成功',
    );
  }
  final reviewUrl = _textOf(json['reviewurl'] ?? json['reviewUrl']);
  final reviewParams = parseXunleiReviewUrl(reviewUrl);
  final needSms =
      error == 'review_panel' || errorCode == '1007' || verifyType.isNotEmpty;
  return XunleiLoginStep(
    needSms: needSms,
    reviewUrl: reviewUrl,
    creditKey: reviewParams['creditkey'] ?? reviewParams['creditKey'] ?? '',
    smsToken: reviewParams['token'] ?? '',
    userId: _textOf(json['userID'] ?? json['user_id']),
    message: _textOf(json['errorDesc'] ?? json['error_description'])
        .ifEmpty(needSms ? '账号密码登录需要安全验证' : '登录失败'),
  );
}

/// 解析验证面板链接里的 `creditkey` / `token`（base64 里可能有 `+`，
/// 不能用 `Uri.queryParameters`，它会把 `+` 解成空格）。
Map<String, String> parseXunleiReviewUrl(String url) {
  final out = <String, String>{};
  final raw = url.trim();
  final start = raw.indexOf('?');
  if (start < 0) return out;
  var query = raw.substring(start + 1);
  final hash = query.indexOf('#');
  if (hash >= 0) query = query.substring(0, hash);
  for (final pair in query.split('&')) {
    if (pair.isEmpty) continue;
    final eq = pair.indexOf('=');
    final key = eq < 0 ? pair : pair.substring(0, eq);
    final value = eq < 0 ? '' : pair.substring(eq + 1);
    try {
      out[Uri.decodeComponent(key)] = Uri.decodeComponent(value);
    } catch (_) {
      out[key] = value;
    }
  }
  return out;
}

/// 登录请求公共体（对齐官方 App 抓包字段；peerID / devicesign 用固定设备指纹）。
Map<String, dynamic> xunleiLoginBody({
  required String deviceId,
  required String peerId,
  required String clientVersion,
  required String sdkVersion,
  String creditKey = '',
}) => {
  'protocolVersion': '301',
  'sequenceNo': '${10000000 + Random().nextInt(90000000)}',
  'platformVersion': '10',
  'isCompressed': '0',
  'appid': xunleiAppId,
  'clientVersion': clientVersion,
  'peerID': peerId,
  'appName': 'ANDROID-$xunleiPackageName',
  'sdkVersion': sdkVersion,
  'devicesign': xunleiDeviceSign(deviceId),
  'netWorkType': 'WIFI',
  'providerName': 'NONE',
  'deviceModel': 'M2004J7AC',
  'deviceName': 'Xiaomi_M2004j7ac',
  'OSVersion': '12',
  'creditkey': creditKey,
  'hl': 'zh-CN',
};

/// 验证面板要按 URL 里的 `deviceid` 识别设备；值必须是 `div101.xxx`
/// 设备签名，才能和 `v3/login` 的 `devicesign` 对上。
String xunleiReviewUrlWithDevice(String url, String deviceId) {
  final raw = url.trim();
  if (raw.isEmpty || deviceId.trim().isEmpty) return raw;
  if (parseXunleiReviewUrl(raw).containsKey('deviceid')) return raw;
  final sign = xunleiDeviceSign(deviceId.trim());
  final sep = raw.contains('?') ? '&' : '?';
  return '$raw${sep}deviceid=${Uri.encodeQueryComponent(sign)}';
}

/// 从 access_token（JWT）里解析用户 ID（`sub`）。
String xunleiJwtSub(String token) {
  try {
    final parts = token.split('.');
    if (parts.length < 2) return '';
    final decoded = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final json = jsonDecode(decoded);
    if (json is Map) return _textOf(json['sub']);
  } catch (_) {}
  return '';
}

String _textOf(Object? value) => value?.toString().trim() ?? '';

extension _EmptyStringExt on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class XunleiCloudException implements Exception {
  const XunleiCloudException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 迅雷云盘离线下载结果（交给播放器的是可直接取流的地址 + 请求头）。
class XunleiCloudPlay {
  const XunleiCloudPlay({
    required this.url,
    required this.title,
    required this.fileName,
    required this.infoHash,
    this.headers = const {},
  });

  final String url;
  final String title;
  final String fileName;

  /// 磁力 infoHash（40 hex）；播放器会话用它做区分键。
  final String infoHash;
  final Map<String, String> headers;
}

class _HttpReply {
  const _HttpReply(this.status, this.body);
  final int status;
  final String body;
}

class _CloudFile {
  const _CloudFile({
    required this.id,
    required this.name,
    required this.size,
    required this.kind,
    this.webContentLink = '',
    this.mediaUrls = const [],
  });

  final String id;
  final String name;
  final int size;
  final String kind;
  final String webContentLink;
  final List<String> mediaUrls;

  bool get isFolder => kind == 'drive#folder';

  factory _CloudFile.fromJson(Map<String, dynamic> json) {
    final medias = json['medias'];
    final mediaUrls = <String>[];
    if (medias is List) {
      for (final item in medias.whereType<Map>()) {
        final link = item['link'];
        if (link is Map) {
          final url = (link['url'] ?? '').toString().trim();
          if (url.isNotEmpty) mediaUrls.add(url);
        }
      }
    }
    return _CloudFile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      size: int.tryParse((json['size'] ?? '').toString()) ?? 0,
      kind: (json['kind'] ?? '').toString(),
      webContentLink: (json['web_content_link'] ?? '').toString(),
      mediaUrls: mediaUrls,
    );
  }
}

/// 迅雷云盘登录 / 离线下载 / 取播放地址。
///
/// 只保存 access/refresh token 与设备号，不保存账号密码；磁力先提交到迅雷云盘，
/// 云端任务完成后用 `web_content_link`（或转码流）交给本地中继播放。
class XunleiCloudService {
  XunleiCloudService({
    required this.store,
    void Function(String message)? logger,
    this.onChanged,
  }) : _log = logger ?? ((_) {});

  final LocalStore store;
  final void Function(String message) _log;
  final void Function()? onChanged;

  XunleiAccount account = const XunleiAccount();

  HttpClient? _client;
  String _captchaToken = '';
  Future<void>? _refreshing;
  bool get ready => account.loggedIn && account.enabled;

  void load() {
    account = store.loadXunleiAccount();
  }

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);

  Future<void> setEnabled(bool enabled) async {
    account = account.copyWith(enabled: enabled);
    await _persist();
  }

  Future<void> logout() async {
    final keep = account;
    // 设备指纹保留：再次登录时仍使用同一台设备，避免触发迅雷风控。
    account = XunleiAccount(
      deviceId: keep.deviceId,
      peerId: keep.peerId,
      enabled: keep.enabled,
    );
    _captchaToken = '';
    await store.saveXunleiAccount(account);
    onChanged?.call();
  }

  /// 当前登录设备指纹；首次登录时生成并落盘，之后固定复用。
  Future<({String deviceId, String peerId})> _ensureDevice() async {
    final oldId = account.deviceId.trim();
    final oldPeer = account.peerId.trim();
    if (oldId.isNotEmpty && oldPeer.isNotEmpty) {
      return (deviceId: oldId, peerId: oldPeer);
    }
    final deviceId = oldId.isNotEmpty ? oldId : xunleiRandomDeviceId();
    final peerId = oldPeer.isNotEmpty ? oldPeer : xunleiRandomDeviceId();
    account = account.copyWith(deviceId: deviceId, peerId: peerId);
    await _persist();
    return (deviceId: deviceId, peerId: peerId);
  }

  /// 账号密码登录；触发安全验证时返回 needSms=true，由 UI 走短信流。
  Future<XunleiLoginStep> loginWithPassword({
    required String username,
    required String password,
  }) async {
    final name = username.trim();
    if (name.isEmpty || password.isEmpty) {
      throw const XunleiCloudException('请填写迅雷账号和密码');
    }
    final device = await _ensureDevice();
    final body =
        xunleiLoginBody(
          deviceId: device.deviceId,
          peerId: device.peerId,
          clientVersion: xunleiLoginClientVersion,
          sdkVersion: xunleiLoginSdkVersion,
        )..addAll({
          'userName': name,
          'passWord': password,
          'verifyKey': '',
          'verifyCode': '',
          'isMd5Pwd': '0',
        });
    final reply = await _send(
      'POST',
      Uri.parse(xunleiCoreLoginUrl),
      headers: {
        'User-Agent': xunleiLoginUserAgent,
        'Content-Type': 'application/json',
      },
      body: body,
    );
    final json = _jsonObject(reply.body);
    if (json == null) {
      throw XunleiCloudException('迅雷登录失败：接口返回异常（HTTP ${reply.status}）');
    }
    final step = parseXunleiLoginResponse(json);
    if (step.needSms) {
      _log('迅雷登录需要短信验证：${step.message}');
      return step;
    }
    if (step.sessionId.isEmpty) {
      throw XunleiCloudException(
        step.message == '登录成功' || step.message.isEmpty
            ? '登录响应缺少 sessionID，请重试一次'
            : _loginError(json),
      );
    }
    final account = await _finishLogin(step, username: name, device: device);
    _log('迅雷云盘登录成功：${account.displayName}');
    return step.copyWith(account: account);
  }

  /// 发送短信验证码；返回 creditkey/token，供 [loginWithSms] 使用。
  Future<XunleiLoginStep> sendSms({required String mobile}) async {
    final phone = mobile.trim();
    if (phone.isEmpty) throw const XunleiCloudException('请填写手机号');
    final device = await _ensureDevice();
    final body = xunleiLoginBody(
      deviceId: device.deviceId,
      peerId: device.peerId,
      clientVersion: xunleiSmsClientVersion,
      sdkVersion: xunleiSmsSdkVersion,
    )..addAll({'mobile': phone, 'register': '0'});
    final reply = await _send(
      'POST',
      Uri.parse(xunleiSendSmsUrl),
      headers: {
        'User-Agent': xunleiSmsUserAgent,
        'Content-Type': 'application/json',
      },
      body: body,
    );
    final json = _jsonObject(reply.body);
    if (json == null) {
      throw XunleiCloudException('短信发送失败：接口返回异常（HTTP ${reply.status}）');
    }
    final creditKey = _textOf(json['creditkey'] ?? json['creditKey']);
    final token = _textOf(json['token']);
    final message = _textOf(json['errorDesc'] ?? json['error_description'])
        .ifEmpty(creditKey.isEmpty ? '短信发送失败，请重试' : '验证码已发送');
    if (creditKey.isEmpty) throw XunleiCloudException(message);
    _log('迅雷短信验证码已发送：$phone');
    return XunleiLoginStep(
      needSms: true,
      creditKey: creditKey,
      smsToken: token,
      message: message,
    );
  }

  /// 短信验证码登录并换取令牌。
  Future<XunleiAccount> loginWithSms({
    required String mobile,
    required String code,
    required String creditKey,
    required String smsToken,
  }) async {
    final phone = mobile.trim();
    final smsCode = code.trim();
    if (phone.isEmpty || smsCode.isEmpty) {
      throw const XunleiCloudException('请填写手机号和短信验证码');
    }
    final device = await _ensureDevice();
    final body =
        xunleiLoginBody(
          deviceId: device.deviceId,
          peerId: device.peerId,
          clientVersion: xunleiSmsClientVersion,
          sdkVersion: xunleiSmsSdkVersion,
          creditKey: creditKey,
        )..addAll({
          'mobile': phone,
          'smsCode': smsCode,
          'token': smsToken,
          'register': '0',
        });
    final reply = await _send(
      'POST',
      Uri.parse(xunleiSmsLoginUrl),
      headers: {
        'User-Agent': xunleiSmsUserAgent,
        'Content-Type': 'application/json',
      },
      body: body,
    );
    final json = _jsonObject(reply.body);
    if (json == null) {
      throw XunleiCloudException('短信登录失败：接口返回异常（HTTP ${reply.status}）');
    }
    final step = parseXunleiLoginResponse(json);
    if (step.sessionId.isEmpty) {
      throw XunleiCloudException(
        step.message == '登录成功' || step.message.isEmpty
            ? '短信验证码校验失败，请重试'
            : step.message,
      );
    }
    final account = await _finishLogin(step, username: phone, device: device);
    _log('迅雷云盘短信登录成功：${account.displayName}');
    return account;
  }

  /// 用已有 refresh_token 登录（不需要密码与短信验证）。
  Future<XunleiAccount> loginWithRefreshToken(String refreshToken) async {
    final token = refreshToken.trim();
    if (token.isEmpty) throw const XunleiCloudException('请填写 refresh_token');
    final device = await _ensureDevice();
    Map<String, dynamic> reply;
    try {
      reply = await _sendJson(
        'POST',
        '$xunleiUserBase/auth/token',
        headers: _baseHeaders(deviceId: device.deviceId),
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': token,
          'client_id': xunleiClientId,
          'client_secret': xunleiClientSecret,
        },
      );
    } on XunleiCloudException catch (e) {
      throw XunleiCloudException('刷新令牌无效：${e.message}');
    }
    final accessToken = _textOf(reply['access_token'] ?? reply['accessToken']);
    final newRefresh = _textOf(reply['refresh_token'] ?? reply['refreshToken']);
    if (accessToken.isEmpty || newRefresh.isEmpty) {
      throw XunleiCloudException('刷新令牌无效：${_errorMessage(reply)}');
    }
    final expiresIn = _int(reply['expires_in']);
    final userId = _textOf(reply['sub']);
    account = XunleiAccount(
      accessToken: accessToken,
      refreshToken: newRefresh,
      tokenType: _textOf(reply['token_type']).ifEmpty('Bearer'),
      expiresAt: expiresIn > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
          : 0,
      userId: userId.isNotEmpty ? userId : xunleiJwtSub(accessToken),
      nickName: '',
      deviceId: device.deviceId,
      peerId: device.peerId,
      enabled: account.enabled,
    );
    _captchaToken = '';
    await _persist();
    await _fillNickname();
    _log('迅雷云盘刷新令牌登录成功：${account.displayName}');
    return account;
  }

  /// 用 v3 登录返回的 sessionID 换取 access/refresh token。
  Future<XunleiAccount> _finishLogin(
    XunleiLoginStep step, {
    required String username,
    required ({String deviceId, String peerId}) device,
  }) async {
    // 换 token 前补一次验证码盾；失败也继续，别因为拿不到 token 就中断登录。
    var captcha = '';
    try {
      captcha = await _initCaptcha(
        username: username,
        deviceId: device.deviceId,
        userId: step.userId,
      );
    } catch (e) {
      _log('迅雷验证码初始化失败：$e');
    }
    final reply = await _sendJson(
      'POST',
      '$xunleiUserBase/auth/signin/token?client_id=$xunleiClientId',
      headers: {
        ..._baseHeaders(deviceId: device.deviceId),
        if (captcha.isNotEmpty) 'X-Captcha-Token': captcha,
      },
      body: {
        'client_id': xunleiClientId,
        'client_secret': xunleiClientSecret,
        'provider': 'access_end_point_token',
        'signin_token': step.sessionId,
      },
    );
    final accessToken = _textOf(reply['access_token'] ?? reply['accessToken']);
    final refreshToken = _textOf(
      reply['refresh_token'] ?? reply['refreshToken'],
    );
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw XunleiCloudException(_loginError(reply));
    }
    final expiresIn = _int(reply['expires_in']);
    final userId = _textOf(reply['sub'] ?? step.userId);
    account = XunleiAccount(
      accessToken: accessToken,
      refreshToken: refreshToken,
      tokenType: _textOf(reply['token_type']).ifEmpty('Bearer'),
      expiresAt: expiresIn > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
          : 0,
      userId: userId.isNotEmpty ? userId : xunleiJwtSub(accessToken),
      nickName: step.nickName,
      deviceId: device.deviceId,
      peerId: device.peerId,
      enabled: account.enabled,
    );
    _captchaToken = captcha;
    await _persist();
    await _fillNickname();
    return account;
  }

  Future<void> _fillNickname() async {
    try {
      final me = await _api('GET', '/user/me', base: xunleiUserBase);
      final name = _textOf(me['nickname'] ?? me['nickName']);
      if (name.isNotEmpty && name != account.nickName) {
        account = account.copyWith(nickName: name);
        await _persist();
      }
    } catch (_) {
      // 昵称只是展示；失败不影响登录结果。
    }
  }

  /// 磁力提交到迅雷云盘并等待云端完成，返回可直接播放的地址。
  Future<XunleiCloudPlay> openMagnet(
    String magnet, {
    String title = '',
    void Function(String message)? onProgress,
    Duration wait = const Duration(minutes: 3),
  }) async {
    if (!ready) throw const XunleiCloudException('迅雷云盘未登录或已关闭');
    if (!RegExp(r'^magnet:', caseSensitive: false).hasMatch(magnet.trim())) {
      throw const XunleiCloudException('不是有效的磁力链接');
    }
    onProgress?.call('正在提交磁力到迅雷云盘…');
    final add = await _api(
      'POST',
      '/files',
      body: {
        'kind': 'drive#file',
        'name': '',
        'parent_id': '',
        'upload_type': 'UPLOAD_TYPE_URL',
        'url': {'url': magnet},
      },
    );
    final added = add['task'];
    final taskId = added is Map ? (added['id'] ?? '').toString() : '';
    if (taskId.isEmpty) {
      throw XunleiCloudException('迅雷云盘未返回任务：${_errorMessage(add)}');
    }
    _log('迅雷云盘任务已提交：$taskId');

    final deadline = DateTime.now().add(wait);
    Map<String, dynamic> task = added is Map
        ? Map<String, dynamic>.from(added)
        : const <String, dynamic>{};
    var lastProgress = -1;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final listed = await _api(
        'GET',
        '/tasks',
        query: {'type': 'offline', 'limit': '10000'},
      );
      final tasks = listed['tasks'];
      if (tasks is List) {
        for (final item in tasks.whereType<Map>()) {
          if ((item['id'] ?? '').toString() == taskId) {
            task = Map<String, dynamic>.from(item);
            break;
          }
        }
      }
      final phase = (task['phase'] ?? '').toString();
      final progress = _int(task['progress']).clamp(0, 100);
      if (phase == 'PHASE_TYPE_ERROR') {
        throw XunleiCloudException(
          '迅雷云盘任务失败：${(task['message'] ?? '').toString().trim()}',
        );
      }
      if (phase == 'PHASE_TYPE_COMPLETE') break;
      if (progress != lastProgress) {
        lastProgress = progress;
        onProgress?.call('迅雷云盘下载中 $progress%');
      }
    }
    if ((task['phase'] ?? '').toString() != 'PHASE_TYPE_COMPLETE') {
      throw const XunleiCloudException('迅雷云盘离线下载超时（任务仍在云端继续）');
    }

    onProgress?.call('云端已完成，正在获取文件…');
    final fileId = (task['file_id'] ?? '').toString().trim();
    if (fileId.isEmpty) {
      throw const XunleiCloudException('迅雷云盘任务完成但没有文件信息');
    }
    final file = await _fileById(fileId);
    final videos = <_CloudFile>[];
    if (file.isFolder) {
      await _collectVideos(file.id, 0, videos);
    } else {
      videos.add(file);
    }
    final picked = _pickCloudVideo(videos, preferName: title);
    if (picked == null) {
      throw const XunleiCloudException('迅雷云盘里没有找到视频文件');
    }
    final detail = picked.webContentLink.isEmpty
        ? await _fileById(picked.id)
        : picked;
    var url = detail.webContentLink.trim();
    if (url.isEmpty && detail.mediaUrls.isNotEmpty) {
      url = detail.mediaUrls.first;
    }
    if (url.isEmpty) {
      throw const XunleiCloudException('迅雷云盘没有返回可播放地址（可能需要会员）');
    }
    final info = parseMagnet(magnet);
    return XunleiCloudPlay(
      url: url,
      title: title.trim().isNotEmpty ? title.trim() : picked.name,
      fileName: picked.name,
      infoHash: info?.infoHash ?? _sha1Hex(magnet),
      headers: const {'User-Agent': xunleiDownloadUserAgent},
    );
  }

  /// 从云端文件列表挑正片（优先片名线索，其次最大视频）。
  static _CloudFile? _pickCloudVideo(
    List<_CloudFile> files, {
    String preferName = '',
  }) {
    if (files.isEmpty) return null;
    final videos = files
        .where((f) => isVideoFile(f.name) && f.size > 0)
        .toList();
    if (videos.isEmpty) return null;
    final hint = stemKey(preferName);
    if (hint.isNotEmpty) {
      for (final file in videos) {
        final key = stemKey(file.name);
        if (key.isNotEmpty && (key.contains(hint) || hint.contains(key))) {
          return file;
        }
      }
    }
    videos.sort((a, b) => b.size.compareTo(a.size));
    return videos.first;
  }

  Future<_CloudFile> _fileById(String id) async {
    final json = await _api('GET', '/files/${Uri.encodeComponent(id)}');
    final file = json['file'];
    return _CloudFile.fromJson(
      file is Map ? Map<String, dynamic>.from(file) : json,
    );
  }

  Future<void> _collectVideos(
    String folderId,
    int depth,
    List<_CloudFile> out,
  ) async {
    if (depth > 3 || out.length >= 200) return;
    final listed = await _api(
      'GET',
      '/files',
      query: {
        'space': '',
        '__type': 'drive',
        'refresh': 'true',
        '__sync': 'true',
        'parent_id': folderId,
        'with_audit': 'true',
        'limit': '100',
        'filters':
            '{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}',
      },
    );
    final files = listed['files'];
    if (files is! List) return;
    for (final item in files.whereType<Map>()) {
      final file = _CloudFile.fromJson(Map<String, dynamic>.from(item));
      if (file.id.isEmpty) continue;
      if (file.isFolder) {
        await _collectVideos(file.id, depth + 1, out);
      } else if (isVideoFile(file.name) && file.size > 0) {
        out.add(file);
      }
    }
  }

  /// 初始化验证码盾，返回 `captcha_token`（可能为空）。
  ///
  /// `meta` 必须带 `captcha_sign`（10 段盐的签名链）；换 token 时用登录账号名，
  /// 后续 API 用已登录的 `user_id`。拿不到 token 时不中断流程，换 token 请求
  /// 仍可尝试（部分环境会下发降级 token）。
  Future<String> _initCaptcha({
    required String username,
    required String deviceId,
    String userId = '',
    String action = 'POST:/v1/auth/signin/token',
  }) async {
    final sign = xunleiCaptchaSign(deviceId: deviceId);
    final name = username.trim();
    final meta = <String, String>{
      'client_version': xunleiClientVersion,
      'package_name': xunleiPackageName,
      'timestamp': sign.timestamp,
      'captcha_sign': sign.sign,
      if (name.isNotEmpty) 'username': name,
      if (userId.trim().isNotEmpty) 'user_id': userId.trim(),
    };
    final reply = await _sendJson(
      'POST',
      '$xunleiUserBase/shield/captcha/init',
      headers: _baseHeaders(deviceId: deviceId),
      body: {
        'action': action,
        'captcha_token': _captchaToken,
        'client_id': xunleiClientId,
        'device_id': deviceId,
        'meta': meta,
        'redirect_uri': 'xlaccsdk01://xunlei.com/callback?state=harbor',
      },
    );
    final token = _textOf(reply['captcha_token']);
    final url = _textOf(reply['url']);
    if (token.isEmpty) {
      if (url.isNotEmpty) {
        _log('迅雷验证码初始化要求验证：$url');
      }
      return '';
    }
    _captchaToken = token;
    return token;
  }

  Future<Map<String, dynamic>> _api(
    String method,
    String path, {
    String base = xunleiApiBase,
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool retry = true,
  }) async {
    await _ensureToken();
    final uri = Uri.parse('$base$path').replace(
      queryParameters: query == null
          ? null
          : {...Uri.parse('$base$path').queryParameters, ...query},
    );
    final headers = _baseHeaders();
    if (account.accessToken.isNotEmpty) {
      headers['Authorization'] = '${account.tokenType} ${account.accessToken}';
    }
    if (_captchaToken.isNotEmpty) {
      headers['X-Captcha-Token'] = _captchaToken;
    }
    final reply = await _send(method, uri, headers: headers, body: body);
    final json = _jsonObject(reply.body);
    if (json == null) {
      throw XunleiCloudException('迅雷接口返回异常（HTTP ${reply.status}）');
    }
    final code = _errorCode(json);
    if (retry && code == 9) {
      await _refreshCaptcha(xunleiAction(method, uri.toString()));
      return _api(
        method,
        path,
        base: base,
        query: query,
        body: body,
        retry: false,
      );
    }
    if (retry && (code == 4122 || code == 4121 || code == 10 || code == 16)) {
      await _refreshToken();
      return _api(
        method,
        path,
        base: base,
        query: query,
        body: body,
        retry: false,
      );
    }
    if (_isError(json)) {
      throw XunleiCloudException(_errorMessage(json));
    }
    if (reply.status >= 400) {
      throw XunleiCloudException('迅雷接口 HTTP ${reply.status}');
    }
    return json;
  }

  Future<void> _refreshCaptcha(String action) async {
    final token = await _initCaptcha(
      username: '',
      deviceId: account.deviceId,
      userId: account.userId,
      action: action,
    );
    if (token.isEmpty) {
      throw const XunleiCloudException('迅雷验证码初始化失败');
    }
  }

  Future<void> _ensureToken() async {
    if (!account.loggedIn) {
      throw const XunleiCloudException('迅雷云盘未登录');
    }
    if (account.accessToken.isNotEmpty && !account.tokenExpired) return;
    await _refreshToken();
  }

  Future<void> _refreshToken() {
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _doRefreshToken();
    _refreshing = future;
    return future.whenComplete(() => _refreshing = null);
  }

  Future<void> _doRefreshToken() async {
    if (account.refreshToken.isEmpty) {
      throw const XunleiCloudException('迅雷登录已失效，请重新登录');
    }
    final reply = await _sendJson(
      'POST',
      '$xunleiUserBase/auth/token',
      headers: _baseHeaders(),
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': account.refreshToken,
        'client_id': xunleiClientId,
        'client_secret': xunleiClientSecret,
      },
    );
    final accessToken = (reply['access_token'] ?? '').toString();
    final refreshToken = (reply['refresh_token'] ?? '').toString();
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw XunleiCloudException('迅雷登录已失效，请重新登录（${_errorMessage(reply)}）');
    }
    final expiresIn = _int(reply['expires_in']);
    account = account.copyWith(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresIn > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
          : 0,
    );
    await _persist();
    _log('迅雷云盘令牌已刷新');
  }

  Map<String, String> _baseHeaders({String? deviceId}) => {
    'User-Agent': xunleiUserAgent,
    'Accept': 'application/json;charset=UTF-8',
    'X-Device-Id': deviceId ?? account.deviceId,
    'X-Client-Id': xunleiClientId,
    'X-Client-Version': xunleiClientVersion,
  };

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
  }) async {
    final reply = await _send(
      method,
      Uri.parse(url),
      headers: headers,
      body: body,
    );
    final json = _jsonObject(reply.body);
    if (json == null) {
      throw XunleiCloudException('迅雷接口返回异常（HTTP ${reply.status}）');
    }
    if (_isError(json)) {
      throw XunleiCloudException(_errorMessage(json));
    }
    return json;
  }

  Future<_HttpReply> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, dynamic>? body,
  }) async {
    final request = await _http.openUrl(method, uri);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 25));
    final text = await response.transform(utf8.decoder).join();
    return _HttpReply(response.statusCode, text);
  }

  Future<void> _persist() async {
    await store.saveXunleiAccount(account);
    onChanged?.call();
  }

  static Map<String, dynamic>? _jsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int _errorCode(Map<String, dynamic> json) =>
      _int(json['error_code'] ?? json['errorCode']);

  static bool _isError(Map<String, dynamic> json) {
    final message = (json['error'] ?? json['error_description'] ?? '')
        .toString();
    if (message == 'success') return false;
    final code = _errorCode(json);
    if (code != 0) return true;
    if ((json['error'] ?? '').toString().trim().isNotEmpty) return true;
    if ((json['error_description'] ?? '').toString().trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  static String _errorMessage(Map<String, dynamic> json) {
    for (final key in ['error_description', 'error', 'message']) {
      final value = (json[key] ?? '').toString().trim();
      if (value.isNotEmpty && value != 'success') return value;
    }
    final code = _errorCode(json);
    return code == 0 ? '迅雷接口返回未知错误' : '迅雷接口错误码 $code';
  }

  static String _loginError(Map<String, dynamic> json) {
    for (final key in ['errorDesc', 'errorDescription', 'error_description']) {
      final value = (json[key] ?? '').toString().trim();
      if (value.isNotEmpty) return '迅雷登录失败：$value';
    }
    return '迅雷登录失败：${_errorMessage(json)}';
  }
}
