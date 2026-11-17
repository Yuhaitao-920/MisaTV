import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import 'immersive_metrics.dart';
import 'immersive_widgets.dart';

/// 沉浸观影分类浏览：大屏网格 + 换页。
class ImmersiveCategoryPage extends StatefulWidget {
  const ImmersiveCategoryPage({
    super.key,
    required this.site,
    required this.sortClass,
  });

  final SourceBean site;
  final SortClass sortClass;

  @override
  State<ImmersiveCategoryPage> createState() => _ImmersiveCategoryPageState();
}

class _ImmersiveCategoryPageState extends State<ImmersiveCategoryPage> {
  List<VodItem> _items = const [];
  int _page = 1;
  int _pageCount = 0;
  bool _loading = true;
  String _error = '';
  int _seq = 0;

  /// `vod_tag=1/folder` 的下钻栈；空栈时展示 sortClass 本身。
  final List<({String id, String name})> _folders = [];

  String get _tid => _folders.isEmpty ? widget.sortClass.id : _folders.last.id;

  String get _title =>
      _folders.isEmpty ? widget.sortClass.name : _folders.last.name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seq == 0) _load(1);
  }

  Future<void> _load(int page) async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = '';
      _page = page;
    });
    try {
      final result = await AppScope.of(context).sourceService
          .category(widget.site, _tid, '$page', const {});
      if (!mounted || seq != _seq) return;
      setState(() {
        _items = result.items;
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
      _folders.add((id: item.id, name: item.name));
      _page = 1;
      _pageCount = 0;
      _items = const [];
    });
    _load(1);
  }

  void _leaveFolderOrClose() {
    if (_folders.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _folders.removeLast();
      _page = 1;
      _pageCount = 0;
      _items = const [];
    });
    _load(1);
  }

  bool get _canPrev => _page > 1 && !_loading;
  bool get _canNext => !_loading && (_pageCount <= 0 || _page < _pageCount);

  @override
  Widget build(BuildContext context) {
    final theme = immersiveTheme(context);
    final m = ImmersiveMetrics.of(context);
    final horizontal = m.wideGutter;

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Container(
                height: m.compact ? m.topPadding + 56 : 72,
                padding: EdgeInsets.only(
                  left: horizontal,
                  right: horizontal,
                  top: m.compact ? m.topPadding : 0,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xF2050705), Color(0x00050705)],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: _folders.isEmpty ? '返回首页' : '返回上一级',
                      onPressed: _leaveFolderOrClose,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        minimumSize: const Size(42, 42),
                      ),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      _title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (!m.compact) ...[
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          _folders.isEmpty
                              ? '${widget.site.displayName} · 共 ${_items.isEmpty ? '--' : _items.length} 部'
                              : '${widget.sortClass.name} / ${_folders.map((folder) => folder.name).join(' / ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.46),
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    IconButton(
                      tooltip: '上一页',
                      onPressed: _canPrev ? () => _load(_page - 1) : null,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Text(
                      _pageCount > 0 ? '$_page / $_pageCount' : '第 $_page 页',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.66),
                      ),
                    ),
                    IconButton(
                      tooltip: '下一页',
                      onPressed: _canNext ? () => _load(_page + 1) : null,
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: _loading ? null : () => _load(_page),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error.isNotEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ImmersiveEmpty(
                  title: '分类加载失败',
                  message: _error,
                  action: FilledButton.tonal(
                    onPressed: () => _load(_page),
                    child: const Text('重试'),
                  ),
                ),
              )
            else if (_items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: ImmersiveEmpty(title: '这个分类暂时没有内容'),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(horizontal, 18, horizontal, 48),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 360,
                    mainAxisExtent: m.categoryCardExtent,
                    crossAxisSpacing: 20,
                    mainAxisSpacing: 22,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final item = _items[index];
                    return ImmersiveCard(
                      key: ValueKey(
                        '${_folders.map((folder) => folder.name).join('/')}:$index',
                      ),
                      title: item.name,
                      year: item.year,
                      subtitle: item.remarks.isEmpty
                          ? widget.site.displayName
                          : item.remarks,
                      fallback: item.cleanPic,
                      badge: item.isFolder ? '分类' : '',
                      showText: false,
                      width: double.infinity,
                      autofocus: index == 0,
                      onTap: () => item.isFolder
                          ? _enterFolder(item)
                          : openImmersiveItem(context, item),
                    );
                  }, childCount: _items.length),
                ),
              ),
            if (!_loading && _items.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 40),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _canPrev ? () => _load(_page - 1) : null,
                        icon: const Icon(Icons.chevron_left_rounded),
                        label: const Text('上一页'),
                      ),
                      const SizedBox(width: 18),
                      Text(
                        _pageCount > 0 ? '$_page / $_pageCount' : '第 $_page 页',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.60),
                        ),
                      ),
                      const SizedBox(width: 18),
                      OutlinedButton.icon(
                        onPressed: _canNext ? () => _load(_page + 1) : null,
                        icon: const Icon(Icons.chevron_right_rounded),
                        label: const Text('下一页'),
                      ),
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
