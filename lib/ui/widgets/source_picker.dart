import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/site_config.dart';
import 'empty_state.dart';
import 'glass.dart';

Future<void> showSourcePicker(BuildContext context) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => const _SourcePickerSheet(),
  );
}

class _SourcePickerSheet extends StatefulWidget {
  const _SourcePickerSheet();

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  final TextEditingController _search = TextEditingController();
  final GlobalKey _activeKey = GlobalKey();
  String _query = '';
  bool _scrolledToActive = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final sites = app.config?.sites ?? const <SourceBean>[];
    final activeSite = app.activeSite;
    // 列表用一次性构建（不是懒加载），当前站点一定已被挂载，打开后可以直接滚到它。
    if (!_scrolledToActive && activeSite != null) {
      _scrolledToActive = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _activeKey.currentContext;
        if (target == null) return;
        Scrollable.ensureVisible(
          target,
          alignment: 0.35,
          duration: Duration.zero,
        );
      });
    }
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? sites
        : [
            for (final site in sites)
              if (site.displayName.toLowerCase().contains(query) ||
                  site.key.toLowerCase().contains(query))
                site,
          ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('选择站点', style: theme.textTheme.titleLarge),
                const Spacer(),
                Text(
                  '${app.usableSites.length} 个可用 / ${sites.length} 个已导入',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 快捷切换**点播订阅**：不用再绕去设置页。
            if (app.vodProfiles.isNotEmpty) ...[
              _PickerChips(
                label: '点播订阅',
                activeId: app.activeProfileId ?? '',
                options: [
                  for (final p in app.vodProfiles) (p.id, p.name),
                ],
                onTap: app.activateProfile,
              ),
              const SizedBox(height: 10),
            ],
            // 站点一多就翻半天：按名称边输边筛，可同时匹配 key。
            if (sites.isNotEmpty) ...[
              TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索站点名称',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (sites.isEmpty)
              const EmptyState(
                icon: Icons.source_outlined,
                title: '还没有站点',
                message: '先导入一份 TVBox 订阅配置',
                compact: true,
              )
            else if (filtered.isEmpty)
              const EmptyState(
                icon: Icons.search_off_rounded,
                title: '没有匹配的站点',
                message: '换个关键词试试',
                compact: true,
              )
            else
              Flexible(
                // 用 SingleChildScrollView + Column 一次性挂载所有站点：ListView
                // 的 itemBuilder / children 首屏只建可见项，当前站点太靠下时
                // GlobalKey 没有 context，无法在打开后定位到它。
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < filtered.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _SiteTile(
                          key: filtered[i].key == activeSite?.key
                              ? _activeKey
                              : null,
                          site: filtered[i],
                          active: filtered[i].key == activeSite?.key,
                          usable: app.isSiteUsable(filtered[i]),
                          onTap: app.isSiteUsable(filtered[i])
                              ? () async {
                                  await app.setActiveSite(filtered[i].key);
                                  if (context.mounted) {
                                    Navigator.of(context).pop();
                                  }
                                }
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 选源弹层顶部的订阅快捷切换。
class _PickerChips extends StatelessWidget {
  const _PickerChips({
    required this.label,
    required this.options,
    required this.activeId,
    required this.onTap,
  });

  final String label;

  /// `(订阅 id, 显示名)`
  final List<(String, String)> options;
  final String activeId;
  final Future<void> Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in options)
              ChoiceChip(
                label: Text(option.$2),
                selected: activeId == option.$1,
                onSelected: (_) => onTap(option.$1),
              ),
          ],
        ),
      ],
    );
  }
}

class _SiteTile extends StatelessWidget {
  const _SiteTile({super.key, required this.site, required this.active, required this.usable, this.onTap});
  final SourceBean site;
  final bool active;
  final bool usable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 18,
      color: active ? theme.colorScheme.primary.withValues(alpha: 0.14) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: usable ? 0.16 : 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                site.displayName.characters.first,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: usable ? theme.colorScheme.primary : theme.disabledColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(site.displayName, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${site.kindLabel} · ${site.key}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                    ),
                  ),
                  if (!usable)
                    Text(
                      site.unsupportedReason,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 22)
            else if (!usable)
              Icon(Icons.block_rounded, color: theme.disabledColor, size: 20),
          ],
        ),
      ),
    );
  }
}
