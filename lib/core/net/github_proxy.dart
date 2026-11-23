/// GitHub 加速线路（纯 Dart，不依赖 dart:io，Web 版也能编译）。
const String kGithubProxy = 'https://gh-proxy.com/';

/// 给 GitHub 域名加 gh-proxy 前缀；非 GitHub 地址原样返回。
String ghProxyUrl(String url) {
  final text = url.trim();
  if (text.isEmpty) return text;
  final host = Uri.tryParse(text)?.host.toLowerCase() ?? '';
  const githubHosts = {
    'github.com',
    'www.github.com',
    'api.github.com',
    'raw.githubusercontent.com',
    'objects.githubusercontent.com',
  };
  if (!githubHosts.contains(host)) return text;
  if (text.startsWith(kGithubProxy)) return text;
  return '$kGithubProxy$text';
}

/// gh-proxy 优先、直连兜底的候选列表。
///
/// 下载默认先走加速；代理临时不可用时仍有机会直连成功。
List<String> ghProxyCandidates(String url) {
  final text = url.trim();
  if (text.isEmpty) return const [];
  final proxied = ghProxyUrl(text);
  if (proxied == text) return [text];
  return [proxied, text];
}
