import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/errors/app_error.dart';
import '../../services/webdav/dav_service.dart';
import '../../state/app_state.dart';

/// 多端同步：WebDAV 双向同步 + 局域网同步。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final TextEditingController _device = TextEditingController();
  final TextEditingController _path = TextEditingController();
  bool _seeded = false;
  bool _busy = false;
  String _error = '';
  String? _serverId;
  List<String> _addresses = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    if (!_seeded) {
      _seeded = true;
      _device.text = app.syncSettings.deviceName;
      _path.text = app.syncSettings.remotePath;
      if (app.lanServer.running) _loadAddresses(app);
    }
    // 服务器选择每次依赖变化都校正一次：设置页刚添加/删除 WebDAV 后，
    // 同步页要立刻能点「立即同步」，而不是卡在「请先选择一个服务器」。
    final saved = app.syncSettings.davServerId;
    final servers = app.davService.servers;
    final current = _serverId;
    final valid = current != null && servers.any((s) => s.id == current);
    if (!valid) {
      _serverId = servers.any((s) => s.id == saved)
          ? saved
          : (servers.isEmpty ? null : servers.first.id);
    }
  }

  @override
  void dispose() {
    _device.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _loadAddresses(AppState app) async {
    final list = await app.lanSyncAddresses();
    if (!mounted) return;
    setState(() => _addresses = list);
  }

  String _describe(Object error) {
    // WebDAV 的 DavException 已经写清了「401 / 403 / 409 / 超时」等具体原因，
    // 直接展示，别再被通用错误分类改写成「网盘 / 站点凭据」。
    if (error is AppException ||
        error is FormatException ||
        error is DavException) {
      return '$error';
    }
    return describeAppError(error).message;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveDevice(AppState app) async {
    await app.saveSyncSettings(
      app.syncSettings.copyWith(deviceName: _device.text.trim()),
    );
    _toast('设备名已保存');
  }

  Future<void> _syncWebDav(AppState app) async {
    // _serverId 一般已在 didChangeDependencies 里自动选好；这里再兜底取第一个，
    // 避免「明明只有一个服务器，却提示请先选择」。
    final serverId =
        _serverId ??
        (app.davService.servers.isEmpty
            ? null
            : app.davService.servers.first.id);
    if (serverId == null) {
      _toast('请先在「设置 → 网盘与数据 → WebDAV」添加服务器');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final report = await app.syncViaWebDav(
        serverId: serverId,
        remotePath: _path.text,
      );
      if (!mounted) return;
      // 远端路径会被归一（补前导 /、去尾 /），回填成真正落库的值。
      _path.text = app.syncSettings.remotePath;
      _toast('${report.summary}${report.pushed ? '，已写回远端' : ''}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleLan(AppState app, bool enabled) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (enabled) {
        await app.startLanSyncServer();
        await _loadAddresses(app);
      } else {
        await app.stopLanSyncServer();
        if (mounted) setState(() => _addresses = const []);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncFromLan(AppState app) async {
    final url = TextEditingController();
    final token = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从其他设备同步'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: url,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '对方设备地址',
                  hintText: '192.168.1.10:9979',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: token,
                decoration: const InputDecoration(
                  labelText: '对方配对码',
                  hintText: '在对方「多端同步」页查看',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('开始同步'),
          ),
        ],
      ),
    );
    final target = url.text.trim();
    final code = token.text.trim();
    url.dispose();
    token.dispose();
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final report = await app.syncViaLan(baseUrl: target, token: code);
      if (!mounted) return;
      _toast(report.summary);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppScope.of(context);
    final settings = app.syncSettings;
    final servers = app.davService.servers;
    final selectedServer = servers.any((s) => s.id == _serverId)
        ? _serverId
        : null;
    final running = app.lanServer.running;

    return Scaffold(
      appBar: AppBar(
        title: const Text('多端同步'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Text(
            '同步观看历史、收藏与片头片尾设置。历史使用版本号 + 墓碑合并，'
            '删除与清空不会被另一台设备的旧数据复活；收藏与片头片尾按更新时间取新。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
            ),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ErrorBanner(message: _error),
          ],
          const SizedBox(height: 16),
          _SectionCard(
            title: '本机',
            icon: Icons.devices_other_rounded,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _device,
                      decoration: const InputDecoration(
                        labelText: '设备名',
                        hintText: '留空则使用系统主机名',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: () => _saveDevice(app),
                    child: const Text('保存'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _CopyRow(
                label: '局域网配对码',
                value: settings.lanToken,
                onCopy: () => _copy(settings.lanToken),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'WebDAV 同步',
            icon: Icons.cloud_sync_outlined,
            children: [
              if (servers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '还没有 WebDAV 服务器。请到「设置 → 网盘与数据 → WebDAV」添加。',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  // FormField 只在创建时读取 initialValue；自动选中/切换服务器
                  // 时用 key 重建，保证下拉框显示的就是真正会同步的那台。
                  key: ValueKey('dav-${selectedServer ?? '-'}-${servers.length}'),
                  initialValue: selectedServer,
                  decoration: const InputDecoration(labelText: '服务器'),
                  items: [
                    for (final server in servers)
                      DropdownMenuItem(
                        value: server.id,
                        child: Text(
                          server.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _serverId = value),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _path,
                decoration: const InputDecoration(
                  labelText: '远端文件路径',
                  hintText: '/MisaTV/sync.json',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                settings.lastSyncAt > 0
                    ? '上次同步：${_formatTime(settings.lastSyncAt)}'
                    : '还没有同步过',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _busy || servers.isEmpty
                      ? null
                      : () => _syncWebDav(app),
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('立即同步'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '局域网同步',
            icon: Icons.lan_rounded,
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: running,
                onChanged: _busy ? null : (v) => _toggleLan(app, v),
                title: const Text('开启局域网同步服务'),
                subtitle: Text(
                  running
                      ? '端口 ${app.lanServer.port} · 其他设备可用配对码连接'
                      : '开启后其他设备可在同一 Wi-Fi 下同步（不做公网映射）',
                ),
              ),
              if (running) ...[
                const SizedBox(height: 4),
                Text(
                  _addresses.isEmpty
                      ? '正在获取本机地址…'
                      : '本机地址：${_addresses.map((e) => '$e:${app.lanServer.port}').join('、')}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _syncFromLan(app),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('从其他设备同步'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '提示：「一起看」复用这里的局域网服务，房间码在播放器里创建后显示。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  void _copy(String text) {
    if (text.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    _toast('已复制');
  }

  static String _formatTime(int ms) {
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        IconButton(
          tooltip: '复制',
          onPressed: value.isEmpty ? null : onCopy,
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
