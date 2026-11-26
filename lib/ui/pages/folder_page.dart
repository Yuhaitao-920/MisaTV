import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../widgets/empty_state.dart';
import '../widgets/poster_card.dart';
import 'detail_page.dart';

/// 打开 `vod_tag=1/folder` 条目的目录列表。
///
/// 网盘型加固源（如「观影 / AiNewGuanYing」）的搜索结果先给一组云盘目录，
/// 需要逐层点进去才到资源列表；这里统一处理站点解析与错误提示。
void openFolderBrowse(BuildContext context, VodItem folder) {
  final app = AppScope.of(context);
  final site =
      app.siteByKey(folder.sourceKey) ??
      (folder.sourceKey.isEmpty ? app.activeSite : null);
  if (site == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('找不到该目录所属的站点，请重新选择或导入源')));
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => FolderBrowsePage(site: site, folder: folder),
    ),
  );
}

/// 普通窗口下的文件夹浏览：网格展示某一层目录，folder 条目继续下钻，
/// 其它条目进入详情页。
class FolderBrowsePage extends StatefulWidget {
  const FolderBrowsePage({super.key, required this.site, required this.folder});

  final SourceBean site;
  final VodItem folder;

  @override
  State<FolderBrowsePage> createState() => _FolderBrowsePageState();
}

class _FolderBrowsePageState extends State<FolderBrowsePage> {
  /// 从入口目录开始的下钻栈，最后一项是当前展示的目录。
  late final List<VodItem> _stack = [widget.folder];

  List<VodItem> _items = const [];
  int _page = 1;
  int _pageCount = 0;
  bool _loading = true;
  String _error = '';
  int _seq = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seq == 0) _load(1);
  }

  Future<void> _load(int page) async {
    final app = AppScope.of(context);
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = '';
      _page = page;
      _items = const [];
    });
    try {
      final result = await app.sourceService.category(
        widget.site,
        _stack.last.id,
        '$page',
        const {},
      );
      if (!mounted || seq != _seq) return;
      final filter = app.contentFilter;
      setState(() {
        _items = filter.active
            ? result.items.where((item) => !filter.blocksVod(item)).toList()
            : result.items;
        _page = result.page > 0 ? result.page : page;
        _pageCount = result.pagecount;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _enterFolder(VodItem item) {
    setState(() {
      _stack.add(item);
      _items = const [];
      _page = 1;
      _pageCount = 0;
    });
    _load(1);
  }

  void _back() {
    if (_stack.length <= 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _stack.removeLast();
      _items = const [];
      _page = 1;
      _pageCount = 0;
    });
    _load(1);
  }

  void _openItem(VodItem item) {
    if (item.isFolder) {
      _enterFolder(item);
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DetailPage(item: item)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _stack.last;
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: _stack.length > 1 ? '返回上一级' : '返回',
            onPressed: _back,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                current.name.isEmpty ? widget.site.displayName : current.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                [
                  widget.site.displayName,
                  for (final folder in _stack)
                    if (folder.name.trim().isNotEmpty) folder.name,
                ].join(' / '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : () => _load(_page),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: EmptyState(
          icon: Icons.cloud_off_rounded,
          title: '目录加载失败',
          message: _error,
          action: FilledButton.tonalIcon(
            onPressed: () => _load(_page),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_open_rounded,
        title: '这个目录暂时没有内容',
        message: '换一个目录，或稍后再试',
      );
    }
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 720;
              final padding = narrow ? 18.0 : 28.0;
              return GridView.builder(
                padding: EdgeInsets.fromLTRB(padding, 4, padding, 18),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 188,
                  mainAxisExtent: 292,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 18,
                ),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return PosterCard(
                    item: item,
                    badge: item.isFolder ? '分类' : '',
                    onTap: () => _openItem(item),
                    onSecondaryLongPress: () =>
                        AppScope.of(context).requestSearch(item.name),
                  );
                },
              );
            },
          ),
        ),
        if (_pageCount > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一页',
                  onPressed: _page > 1 ? () => _load(_page - 1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '$_page / $_pageCount',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.66,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一页',
                  onPressed: _page < _pageCount ? () => _load(_page + 1) : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
