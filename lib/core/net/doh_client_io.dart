import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 国内可用的 DoH JSON 接口，按序尝试。
///
/// 部分源站被 DNS 污染时，系统 DNS 会解到劫持 IP（返 Web 拦截页），
/// 表现为“订阅不像 JSON”；DoH 能拿到真实 A 记录。
const _dohServers = <String>[
  'https://doh.pub/dns-query',
  'https://dns.alidns.com/resolve',
  'https://1.12.12.12/dns-query',
];

typedef DohConnectionFactory = Future<ConnectionTask<Socket>> Function(
  Uri url,
  String? proxyHost,
  int? proxyPort,
);

/// 连接前用 DoH 查真实 IP，再连该 IP；HTTPS 会手动包 TLS，
/// SNI 与证书校验仍用原 URL 主机名。
///
/// 给裸 `HttpClient`（如 JAR 下载）复用。
DohConnectionFactory createDohConnectionFactory() {
  final resolver = _DohResolver();
  return (uri, proxyHost, proxyPort) async {
    if (proxyHost != null && proxyHost.isNotEmpty) {
      final socket = await Socket.connect(
        proxyHost,
        proxyPort ?? 80,
        timeout: const Duration(seconds: 12),
      );
      return ConnectionTask.fromSocket<Socket>(
        Future.value(socket),
        socket.destroy,
      );
    }
    final host = uri.host;
    String address = host;
    if (InternetAddress.tryParse(host) == null && host != 'localhost') {
      final ip = await resolver.resolve(host);
      if (ip != null && ip.isNotEmpty) address = ip;
    }
    final socket = await _connect(address, host, uri.port);
    // connectionFactory 返回裸 Socket 时 HttpClient 不会再套 TLS，必须自己包。
    if (uri.scheme == 'https') {
      final secure = await SecureSocket.secure(socket, host: host);
      return ConnectionTask.fromSocket<Socket>(
        Future.value(secure),
        secure.destroy,
      );
    }
    return ConnectionTask.fromSocket<Socket>(
      Future.value(socket),
      socket.destroy,
    );
  };
}

/// 带 DoH 解析的 HTTP 客户端。
http.Client createDohClient() {
  final raw = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  raw.connectionFactory = createDohConnectionFactory();
  return IOClient(raw);
}

Future<Socket> _connect(String address, String host, int port) async {
  final parsed = InternetAddress.tryParse(address);
  if (parsed != null) {
    return Socket.connect(parsed, port, timeout: const Duration(seconds: 12));
  }
  final addresses = await InternetAddress.lookup(host);
  if (addresses.isEmpty) throw const SocketException('DNS 无结果');
  return Socket.connect(
    addresses.first,
    port,
    timeout: const Duration(seconds: 12),
  );
}

class _DohResolver {
  HttpClient? _client;
  final Map<String, String?> _cache = {};

  HttpClient get _http =>
      _client ??= HttpClient()..connectionTimeout = const Duration(seconds: 6);

  Future<String?> resolve(String host) async {
    if (_cache.containsKey(host)) return _cache[host];
    for (final server in _dohServers) {
      final ip = await _query(server, host);
      if (ip != null) return _cache[host] = ip;
    }
    return _cache[host] = null;
  }

  Future<String?> _query(String server, String host) async {
    try {
      final uri = Uri.parse(
        '$server?name=${Uri.encodeQueryComponent(host)}&type=A',
      );
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final res = await req.close().timeout(const Duration(seconds: 6));
      final text = await utf8.decoder
          .bind(res)
          .join()
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(text);
      final answers = decoded is Map ? decoded['Answer'] : null;
      if (answers is List) {
        for (final answer in answers) {
          if (answer is Map && answer['type'] == 1) {
            final data = '${answer['data'] ?? ''}';
            if (data.isNotEmpty && !data.startsWith('127.')) return data;
          }
        }
      }
    } catch (_) {
      // 换下一个 DoH
    }
    return null;
  }
}
