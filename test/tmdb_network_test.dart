import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/artwork/tmdb_network.dart';

void main() {
  test('识别污染的地址（Facebook 网段 / 保留地址）', () {
    expect(looksLikePoisonedAddress('157.240.12.35'), isTrue);
    expect(looksLikePoisonedAddress('69.63.184.142'), isTrue);
    expect(looksLikePoisonedAddress('2a03:2880:f126:83:face:b00c:0:25de'), isTrue);
    expect(looksLikePoisonedAddress('0.0.0.0'), isTrue);
    expect(looksLikePoisonedAddress('192.168.3.1'), isTrue);
    expect(looksLikePoisonedAddress('127.0.0.1'), isTrue);
    // Cloudflare 段是 TMDB 的合法解析结果，不能误判
    expect(looksLikePoisonedAddress('104.31.142.88'), isFalse);
    expect(looksLikePoisonedAddress('18.164.4.1'), isFalse);
  });

  test('TMDB 图床：官方 → 公共镜像 → 备用地址', () {
    expect(
      tmdbImageUrl('/abc123.jpg'),
      'https://image.tmdb.org/t/p/original/abc123.jpg',
    );
    expect(
      tmdbImageUrl('abc123.jpg', size: 'w780'),
      'https://image.tmdb.org/t/p/w780/abc123.jpg',
    );
    expect(
      tmdbImageUrl('https://cdn.example.com/a.jpg'),
      'https://cdn.example.com/a.jpg',
    );
    expect(tmdbImageMirrors('https://image.tmdb.org/t/p/original/abc123.jpg'), [
      'https://image.tmdb.org/t/p/original/abc123.jpg',
      'https://tmdb-image.nocorp.space/t/p/original/abc123.jpg',
      'https://tmdb.org/t/p/original/abc123.jpg',
    ]);
    expect(tmdbImageMirrors('https://tmdb.org/t/p/w780/abc123.jpg'), [
      'https://image.tmdb.org/t/p/w780/abc123.jpg',
      'https://tmdb-image.nocorp.space/t/p/w780/abc123.jpg',
      'https://tmdb.org/t/p/w780/abc123.jpg',
    ]);
    expect(tmdbImageMirrors('https://example.com/abc.jpg'), isEmpty);
  });

  test('诊断文案：污染 / 正常 / 已走代理', () {
    final poisoned = describeTmdbDns(
      addresses: ['157.240.12.35', '2a03:2880:f126:83:face:b00c:0:25de'],
      proxyActive: false,
    );
    expect(poisoned, contains('DNS 污染'));
    expect(poisoned, contains('系统代理'));

    expect(
      describeTmdbDns(addresses: ['104.31.142.88'], proxyActive: false),
      contains('没被污染'),
    );
    expect(
      describeTmdbDns(addresses: ['157.240.12.35'], proxyActive: true),
      contains('已走代理'),
    );
    expect(
      describeTmdbDns(addresses: const [], proxyActive: false),
      contains('解析不到'),
    );
  });
}