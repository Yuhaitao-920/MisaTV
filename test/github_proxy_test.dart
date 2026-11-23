import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/github_proxy.dart';

void main() {
  group('gh-proxy 线路', () {
    test('GitHub 地址加 gh-proxy 前缀', () {
      expect(
        ghProxyUrl('https://github.com/a/b/releases/download/v1/x.zip'),
        'https://gh-proxy.com/https://github.com/a/b/releases/download/v1/x.zip',
      );
      expect(
        ghProxyUrl('https://api.github.com/repos/a/b/releases/latest'),
        'https://gh-proxy.com/https://api.github.com/repos/a/b/releases/latest',
      );
      expect(
        ghProxyUrl('https://raw.githubusercontent.com/a/b/main/x.js'),
        'https://gh-proxy.com/https://raw.githubusercontent.com/a/b/main/x.js',
      );
    });

    test('非 GitHub 地址保持不变', () {
      expect(
        ghProxyUrl('https://example.com/x.zip'),
        'https://example.com/x.zip',
      );
      expect(
        ghProxyUrl('https://mirrors.huaweicloud.com/openjdk/x.zip'),
        'https://mirrors.huaweicloud.com/openjdk/x.zip',
      );
    });

    test('已经带前缀时不会重复加', () {
      const proxied =
          'https://gh-proxy.com/https://github.com/a/b/releases/download/v1/x.zip';
      expect(ghProxyUrl(proxied), proxied);
    });

    test('候选列表 gh-proxy 在前、直连兜底', () {
      final list = ghProxyCandidates(
        'https://github.com/a/b/releases/download/v1/x.zip',
      );
      expect(list.length, 2);
      expect(list.first, startsWith(kGithubProxy));
      expect(list.last, startsWith('https://github.com/'));
    });
  });
}
