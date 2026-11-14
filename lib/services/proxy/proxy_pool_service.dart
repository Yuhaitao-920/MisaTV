import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/net/proxy_config.dart';
import '../../models/proxy_node.dart';
import '../local_store.dart';

/// 免费代理池：每天自动拉一次列表，支持手动刷新、手动添加、测速与切换。
///
/// 选中节点**只记录选择**，由 [onSelectionChanged] 通知 AppState 统一决策；
/// 这里绝不直接改「网络代理」设置——两处都写 `ProxyConfig` 会互相覆盖：
/// 选过代理池节点后，下次启动 restore 会把用户自己设的代理（比如「跟随系统
/// 代理」的 Clash）悄悄换成一个来路不明的公共节点，表现就是「有时能用有时全超时」。
class ProxyPoolService extends ChangeNotifier {
  ProxyPoolService({required this.store, required this.onSelectionChanged});

  static const sourceUrl =
      'https://raw.githubusercontent.com/watchttvv/free-proxy-list/refs/heads/main/proxy.txt';

  /// 自动刷新间隔：一天一次。
  static const refreshInterval = Duration(hours: 24);

  /// 自动节点上限：再多也测不过来，还会拖慢设置页首屏。
  static const maxNodes = 120;

  final LocalStore store;

  /// 选择变化后让 AppState 重新算「到底走哪个代理」。
  final Future<void> Function() onSelectionChanged;

  List<ProxyNode> nodes = const [];
  String selectedId = '';
  int fetchedAt = 0;
  bool refreshing = false;
  bool testing = false;
  String error = '';

  bool get enabled => selectedId.isNotEmpty;

  ProxyNode? get selected => _find(selectedId);

  String get selectedLabel => selected?.address ?? '直连';

  /// 距离上次拉取是否已超过 24 小时（从没拉过也算到期）。
  bool get due {
    if (fetchedAt <= 0) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(fetchedAt);
    return DateTime.now().difference(last) >= refreshInterval;
  }

  void load() {
    final raw = store.proxyPoolJson;
    if (raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final list = decoded['nodes'];
      if (list is List) {
        nodes = [
          for (final item in list)
            if (item is Map)
              ProxyNode.fromJson(Map<String, Object?>.from(item)),
        ].where((node) => node.valid).toList();
      }
      selectedId = (decoded['selected'] ?? '').toString();
      fetchedAt = decoded['fetchedAt'] is num
          ? (decoded['fetchedAt'] as num).toInt()
          : 0;
    } catch (_) {
      // 存档损坏就当空池，下次刷新会重建。
    }
  }

  Future<void> autoRefreshIfDue() async {
    if (!due || refreshing) return;
    await refresh();
  }

  /// 拉取并解析列表。手动节点保留，自动节点整体替换；已测延时按地址复用。
  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    error = '';
    notifyListeners();
    // raw.githubusercontent.com 在国内经常连不上。代理池只是可选增强，
    // 失败就继续直连，别让每次启动都白等 15 秒。
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.getUrl(Uri.parse(sourceUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'MisaTV-proxy-pool');
      final response = await request
          .close()
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw 'HTTP ${response.statusCode}';
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 4 * 1024 * 1024) break;
      }
      final parsed = parseProxyList(utf8.decode(bytes, allowMalformed: true));
      if (parsed.isEmpty) throw '列表里没有可用代理';
      final old = {for (final node in nodes) node.id: node};
      final manual = nodes.where((node) => node.manual).toList();
      final auto = <ProxyNode>[
        for (final node in parsed.take(maxNodes))
          node.copyWith(
            latencyMs: old[node.id]?.latencyMs ?? -1,
            testedAt: old[node.id]?.testedAt ?? 0,
          ),
      ];
      nodes = _dedupe([...manual, ...auto]);
      fetchedAt = DateTime.now().millisecondsSinceEpoch;
      // 选中的自动节点在新列表里消失了：退回直连，避免代理指向死地址。
      if (selectedId.isNotEmpty && selected == null) {
        selectedId = '';
        await onSelectionChanged();
      }
      await _save();
      AppLog.i('proxy', '代理池已更新：${nodes.length} 个节点');
    } catch (e) {
      error = '$e';
      AppLog.w('proxy', '代理池拉取失败（可选功能，不影响直连/蜘蛛/播放）：$e');
    } finally {
      client.close(force: true);
      refreshing = false;
      notifyListeners();
    }
  }

  /// 单个节点测速：TCP 握手耗时，超时/失败记为 -1。
  Future<void> testNode(String id) async {
    final node = _find(id);
    if (node == null) return;
    final latency = await _probe(node.host, node.port);
    _replace(
      node.id,
      node.copyWith(
        latencyMs: latency,
        testedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _save();
    notifyListeners();
  }

  /// 全部测速：4 路并发，避免一次开上百个 socket 把系统打满。
  Future<void> testAll() async {
    if (testing || nodes.isEmpty) return;
    testing = true;
    notifyListeners();
    try {
      var index = 0;
      Future<void> worker() async {
        while (index < nodes.length) {
          final node = nodes[index++];
          if (!node.valid) continue;
          final latency = await _probe(node.host, node.port);
          _replace(
            node.id,
            node.copyWith(
              latencyMs: latency,
              testedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          notifyListeners();
        }
      }

      await Future.wait([for (var i = 0; i < 4; i++) worker()]);
      await _save();
    } finally {
      testing = false;
      notifyListeners();
    }
  }

  Future<void> select(String id) async {
    final node = _find(id);
    if (node == null) return;
    selectedId = node.id;
    await _save();
    await onSelectionChanged();
    notifyListeners();
  }

  /// 取消代理池节点：回到用户自己的「网络代理」设置（手填代理或跟随系统）。
  Future<void> selectDirect() async {
    selectedId = '';
    await _save();
    await onSelectionChanged();
    notifyListeners();
  }

  Future<bool> addManual({
    required String type,
    required String host,
    required int port,
    String username = '',
    String password = '',
    String label = '',
  }) async {
    final node = ProxyNode(
      type: type == 'socks5' ? 'socks5' : 'http',
      host: host.trim(),
      port: port,
      username: username.trim(),
      password: password.trim(),
      label: label.trim(),
      manual: true,
    );
    if (!node.valid) return false;
    if (_find(node.id) != null) {
      error = '这个代理已经在列表里';
      notifyListeners();
      return false;
    }
    nodes = [node, ...nodes];
    await _save();
    notifyListeners();
    return true;
  }

  Future<void> remove(String id) async {
    nodes = nodes.where((node) => node.id != id).toList();
    if (selectedId == id) {
      selectedId = '';
      await onSelectionChanged();
    }
    await _save();
    notifyListeners();
  }

  Future<int> _probe(String host, int port) async {
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 6),
      );
      watch.stop();
      return watch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      socket?.destroy();
    }
  }

  /// 代理池节点转成代理桥配置（只在 AppState 里用）。
  static ProxyConfig configOf(ProxyNode node) => ProxyConfig(
    enabled: true,
    type: node.type,
    host: node.host,
    port: node.port,
    username: node.username,
    password: node.password,
  );

  ProxyNode? _find(String id) {
    if (id.isEmpty) return null;
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  void _replace(String id, ProxyNode node) {
    nodes = [
      for (final item in nodes)
        if (item.id == id) node else item,
    ];
  }

  List<ProxyNode> _dedupe(List<ProxyNode> input) {
    final seen = <String>{};
    final out = <ProxyNode>[];
    for (final node in input) {
      if (!node.valid || !seen.add(node.id)) continue;
      out.add(node);
    }
    return out;
  }

  Future<void> _save() => store.setProxyPoolJson(
    jsonEncode({
      'nodes': [for (final node in nodes) node.toJson()],
      'selected': selectedId,
      'fetchedAt': fetchedAt,
    }),
  );
}
