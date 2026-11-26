/// Web 版占位：UC TV OAuth 需要使用 dart:io 的 HttpClient。
class UcTvTokenService {
  UcTvTokenService();

  void close() {}

  static String newDeviceId([DateTime? now]) => '';

  Future<UcTvQrSession> create({required String deviceId}) async {
    throw UnsupportedError('UC TV 授权仅支持桌面端与移动端');
  }

  Future<UcTvPollResult> poll(UcTvQrSession session) async {
    throw UnsupportedError('UC TV 授权仅支持桌面端与移动端');
  }

  Future<UcTvExchangeResult> exchange(
    UcTvQrSession session,
    String code,
  ) async {
    throw UnsupportedError('UC TV 授权仅支持桌面端与移动端');
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
