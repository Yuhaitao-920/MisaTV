import 'package:flutter/material.dart';

import '../../services/subtitle/subtitle_models.dart';
import '../../services/subtitle/subtitle_service.dart';

/// 在线字幕检索面板：返回选中的字幕文件；取消返回 null。
Future<SubtitleFile?> showSubtitlePanel(
  BuildContext context, {
  required SubtitleService service,
  required SubtitleQuery query,
  String currentName = '',
  VoidCallback? onClear,
}) {
  return showModalBottomSheet<SubtitleFile>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SubtitleSheet(
      service: service,
      query: query,
      currentName: currentName,
      onClear: onClear,
    ),
  );
}

class _SubtitleSheet extends StatefulWidget {
  const _SubtitleSheet({
    required this.service,
    required this.query,
    required this.currentName,
    this.onClear,
  });
  final SubtitleService service;
  final SubtitleQuery query;
  final String currentName;
  final VoidCallback? onClear;

  @override
  State<_SubtitleSheet> createState() => _SubtitleSheetState();
}

class _SubtitleSheetState extends State<_SubtitleSheet> {
  bool _loading = true;
  String _error = '';
  String _busyId = '';
  List<SubtitleCandidate> _items = const [];

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final items = await widget.service.search(widget.query);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _apply(SubtitleCandidate candidate) async {
    if (_busyId.isNotEmpty) return;
    setState(() => _busyId = candidate.id);
    try {
      final file = await widget.service.download(
        candidate,
        videoName: widget.query.rawName,
        ep: widget.query.episode?.toString() ?? '',
      );
      if (!mounted) return;
      Navigator.of(context).pop(file);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyId = '';
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.sizeOf(context).height;
    return Container(
      constraints: BoxConstraints(maxHeight: height * 0.78),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('在线字幕', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 3),
                        Text(
                          widget.query.title.isEmpty ? '当前资源' : widget.query.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _loading ? null : _search,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  if (widget.currentName.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        widget.onClear?.call();
                        Navigator.of(context).pop();
                      },
                      child: const Text('关闭字幕'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              )
            else if (_items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('没有搜到字幕；assrt 未配置 token 时会自动跳过该源。'),
              )
            else
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    final busy = _busyId == item.id;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${item.providerName} · ${item.language.isEmpty ? '未知语言' : item.language}'
                        '${item.format.isEmpty ? '' : ' · ${item.format.toUpperCase()}'}'
                        // 集号：有则显示「第N集」，无则明示「整片/不分集」——
                        // 用户常把「整片字幕」误当成「字幕没匹配上集数」。
                        '${item.episodeHint.isEmpty ? ' · 整片' : ' · 第${item.episodeHint}集'}'
                        '${item.detail.isEmpty ? '' : ' · ${item.detail}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                      trailing: busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download_rounded, size: 20),
                      onTap: busy ? null : () => _apply(item),
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'SubtitleCat 免 token；assrt 需在「设置 → 播放」填写 token。字幕文件下载后会挂到当前播放器。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
