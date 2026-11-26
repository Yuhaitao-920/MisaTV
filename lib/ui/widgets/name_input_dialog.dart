import 'package:flutter/material.dart';

import '../../models/site_config.dart';

/// PY 源导入目标：已有订阅 id 为空表示创建新订阅。
class PyImportTarget {
  const PyImportTarget({this.profileId, required this.name});

  final String? profileId;
  final String name;
}

/// 导入本地 PY 源：单选 / 多选都弹窗，可选择并入已有订阅或新建订阅。
Future<PyImportTarget?> showPyImportTargetDialog(
  BuildContext context, {
  required List<ConfigProfile> profiles,
  String? initialProfileId,
  required String suggestedName,
  required int fileCount,
}) {
  return showDialog<PyImportTarget>(
    context: context,
    builder: (_) => _PyImportTargetDialog(
      profiles: profiles,
      initialProfileId: initialProfileId,
      suggestedName: suggestedName,
      fileCount: fileCount,
    ),
  );
}

class _PyImportTargetDialog extends StatefulWidget {
  const _PyImportTargetDialog({
    required this.profiles,
    required this.initialProfileId,
    required this.suggestedName,
    required this.fileCount,
  });

  final List<ConfigProfile> profiles;
  final String? initialProfileId;
  final String suggestedName;
  final int fileCount;

  @override
  State<_PyImportTargetDialog> createState() => _PyImportTargetDialogState();
}

class _PyImportTargetDialogState extends State<_PyImportTargetDialog> {
  static const String _newProfile = '__new__';

  late String _selected =
      widget.profiles.any((p) => p.id == widget.initialProfileId)
      ? widget.initialProfileId!
      : _newProfile;
  late final TextEditingController _name = TextEditingController(
    text: widget.suggestedName,
  );
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_selected == _newProfile) {
      final name = _name.text.trim();
      if (name.isEmpty) {
        setState(() => _error = '请输入新订阅名称');
        return;
      }
      Navigator.of(context).pop(PyImportTarget(name: name));
      return;
    }
    ConfigProfile? target;
    for (final profile in widget.profiles) {
      if (profile.id == _selected) {
        target = profile;
        break;
      }
    }
    if (target == null) {
      setState(() => _error = '请选择要导入的订阅');
      return;
    }
    Navigator.of(context)
        .pop(PyImportTarget(profileId: target.id, name: target.name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导入 PY 源'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '已选择 ${widget.fileCount} 个 PY 源。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '导入到'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selected,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: _newProfile,
                      child: Text('创建新订阅'),
                    ),
                    for (final profile in widget.profiles)
                      DropdownMenuItem(
                        value: profile.id,
                        child: Text(
                          '${profile.name}（${profile.siteCount} 个站点）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _selected = value ?? _newProfile;
                    _error = '';
                  }),
                ),
              ),
            ),
            if (_selected == _newProfile) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '新订阅名称'),
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _error,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_selected == _newProfile ? '创建并导入' : '导入'),
        ),
      ],
    );
  }
}

/// 导入本地直播源（TXT / M3U）的目标：已有直播订阅 id 为空表示创建新订阅。
class LiveImportTarget {
  const LiveImportTarget({this.profileId, required this.name});

  final String? profileId;
  final String name;
}

/// 导入本地 TXT / M3U 直播源：可选择并入已有直播订阅，或新建一个直播订阅。
///
/// 与 [showPyImportTargetDialog] 同一套语义：以前本地 TXT 只能变成一条独立
/// 线路（`localLives`），多份文件就散成一堆线路；现在可以像点播 PY 源那样
/// 归到某个订阅下，重复导入同名同地址的线路就地合并。
Future<LiveImportTarget?> showLiveImportTargetDialog(
  BuildContext context, {
  required List<ConfigProfile> profiles,
  String? initialProfileId,
  required String suggestedName,
  required int fileCount,
}) {
  return showDialog<LiveImportTarget>(
    context: context,
    builder: (_) => _LiveImportTargetDialog(
      profiles: profiles,
      initialProfileId: initialProfileId,
      suggestedName: suggestedName,
      fileCount: fileCount,
    ),
  );
}

class _LiveImportTargetDialog extends StatefulWidget {
  const _LiveImportTargetDialog({
    required this.profiles,
    required this.initialProfileId,
    required this.suggestedName,
    required this.fileCount,
  });

  final List<ConfigProfile> profiles;
  final String? initialProfileId;
  final String suggestedName;
  final int fileCount;

  @override
  State<_LiveImportTargetDialog> createState() =>
      _LiveImportTargetDialogState();
}

class _LiveImportTargetDialogState extends State<_LiveImportTargetDialog> {
  static const String _newProfile = '__new__';

  late String _selected =
      widget.profiles.any((p) => p.id == widget.initialProfileId)
      ? widget.initialProfileId!
      : _newProfile;
  late final TextEditingController _name = TextEditingController(
    text: widget.suggestedName,
  );
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_selected == _newProfile) {
      final name = _name.text.trim();
      if (name.isEmpty) {
        setState(() => _error = '请输入新订阅名称');
        return;
      }
      Navigator.of(context).pop(LiveImportTarget(name: name));
      return;
    }
    ConfigProfile? target;
    for (final profile in widget.profiles) {
      if (profile.id == _selected) {
        target = profile;
        break;
      }
    }
    if (target == null) {
      setState(() => _error = '请选择要导入的订阅');
      return;
    }
    Navigator.of(context)
        .pop(LiveImportTarget(profileId: target.id, name: target.name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导入本地直播源'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.fileCount == 1
                  ? '已选择 1 个直播源文件。'
                  : '已选择 ${widget.fileCount} 个直播源文件。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '导入到'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selected,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: _newProfile,
                      child: Text('创建新订阅'),
                    ),
                    for (final profile in widget.profiles)
                      DropdownMenuItem(
                        value: profile.id,
                        child: Text(
                          '${profile.name}（${profile.liveCount} 条线路）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _selected = value ?? _newProfile;
                    _error = '';
                  }),
                ),
              ),
            ),
            if (_selected == _newProfile) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '新订阅名称'),
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _error,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_selected == _newProfile ? '创建并导入' : '导入'),
        ),
      ],
    );
  }
}

/// 站点多选后移动到另一个点播订阅。
Future<String?> showMoveSitesTargetDialog(
  BuildContext context, {
  required List<ConfigProfile> profiles,
  required int count,
}) {
  if (profiles.isEmpty) return Future.value(null);
  return showDialog<String>(
    context: context,
    builder: (_) => _MoveSitesTargetDialog(profiles: profiles, count: count),
  );
}

class _MoveSitesTargetDialog extends StatefulWidget {
  const _MoveSitesTargetDialog({required this.profiles, required this.count});

  final List<ConfigProfile> profiles;
  final int count;

  @override
  State<_MoveSitesTargetDialog> createState() => _MoveSitesTargetDialogState();
}

class _MoveSitesTargetDialogState extends State<_MoveSitesTargetDialog> {
  late String _selected = widget.profiles.first.id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('移动站点'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将选中的 ${widget.count} 个站点移动到：',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '目标订阅'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selected,
                  isExpanded: true,
                  items: [
                    for (final profile in widget.profiles)
                      DropdownMenuItem(
                        value: profile.id,
                        child: Text(
                          '${profile.name}（${profile.siteCount} 个站点）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    if (value != null) _selected = value;
                  }),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '源会从当前订阅移除，并记录删除墓碑，订阅刷新后不会复活。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('移动'),
        ),
      ],
    );
  }
}
