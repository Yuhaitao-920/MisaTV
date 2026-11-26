import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/logging/log_redact.dart';
import 'package:kniephos/services/artwork/tmdb_auth.dart';

// 全部是格式示例，不是可用的真实凭据。
const fakeV3 = '0123456789abcdef0123456789abcdef';
const fakeV4 =
    'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJmYWtlLWF1ZCIsInN1YiI6ImZha2UifQ.c2lnbmF0dXJl';

void main() {
  test('v3 Key：走 query 的 api_key，不加 Authorization', () {
    final credential = TmdbCredential.parse(fakeV3);
    expect(credential.kind, TmdbCredentialKind.apiKey);
    expect(credential.label, 'v3 API Key');
    expect(credential.queryParams, {'api_key': fakeV3});
    expect(credential.headers, isEmpty);
  });

  test('v4 Token：走 Authorization 头，不加 api_key', () {
    final credential = TmdbCredential.parse(fakeV4);
    expect(credential.kind, TmdbCredentialKind.readToken);
    expect(credential.label, 'v4 Read Access Token');
    expect(credential.headers, {'Authorization': 'Bearer $fakeV4'});
    expect(credential.queryParams, isEmpty);
  });

  test('整段粘贴：Bearer 前缀 / Authorization 头 / 引号 / 空白都要归一', () {
    for (final raw in [
      '  $fakeV4  ',
      'Bearer $fakeV4',
      'bearer   $fakeV4',
      'Authorization: Bearer $fakeV4',
      '"$fakeV4"',
      "'$fakeV4'",
    ]) {
      final credential = TmdbCredential.parse(raw);
      expect(credential.kind, TmdbCredentialKind.readToken, reason: raw);
      expect(
        credential.headers['Authorization'],
        'Bearer $fakeV4',
        reason: 'Bearer 不能重复：$raw',
      );
    }
  });

  test('无法识别的填法：判为未配置并给出提示', () {
    for (final raw in ['abc', 'hello world', 'x', '12345']) {
      final credential = TmdbCredential.parse(raw);
      expect(credential.isConfigured, isFalse, reason: raw);
      expect(credential.problem, isNotEmpty, reason: raw);
    }
    expect(TmdbCredential.parse('').problem, isEmpty);
    expect(TmdbCredential.parse('   ').isConfigured, isFalse);
  });

  test('masked 不泄露完整凭据', () {
    final credential = TmdbCredential.parse(fakeV4);
    expect(credential.masked.contains(fakeV4), isFalse);
    expect(credential.masked.length, lessThan(fakeV4.length));
  });

  test('redactQueryValues：query 值打码，键名与路径保留', () {
    final text =
        'ClientException uri=https://api.themoviedb.org/3/search/multi?api_key=$fakeV3&language=zh-CN';
    final masked = redactQueryValues(text);
    expect(masked.contains(fakeV3), isFalse);
    expect(masked, contains('api_key=<hidden>'));
    expect(masked, contains('language=<hidden>'));
    expect(masked, contains('https://api.themoviedb.org/3/search/multi'));
    expect(redactQueryValues('plain error'), 'plain error');
  });
  test('两份都填时优先读访问令牌；旧配置把令牌粘在 key 框也能用', () {
    final both = TmdbCredential.resolve(apiKey: fakeV3, readToken: fakeV4);
    expect(both.kind, TmdbCredentialKind.readToken);
    expect(both.headers['Authorization'], 'Bearer $fakeV4');
    expect(both.queryParams, isEmpty);

    final keyOnly = TmdbCredential.resolve(apiKey: fakeV3);
    expect(keyOnly.kind, TmdbCredentialKind.apiKey);
    expect(keyOnly.queryParams, {'api_key': fakeV3});

    final tokenOnly = TmdbCredential.resolve(readToken: fakeV4);
    expect(tokenOnly.kind, TmdbCredentialKind.readToken);

    // 旧版本只有一个输入框：令牌被粘进 key 框时按令牌处理。
    final legacy = TmdbCredential.resolve(apiKey: fakeV4);
    expect(legacy.kind, TmdbCredentialKind.readToken);

    expect(TmdbCredential.resolve().isConfigured, isFalse);
    expect(
      TmdbCredential.resolve(apiKey: 'junk', readToken: 'junk').isConfigured,
      isFalse,
    );
  });
}
