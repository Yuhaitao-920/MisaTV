import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/vod.dart';
import '../../state/app_state.dart';
import 'immersive_category_page.dart';
import 'immersive_metrics.dart';
import 'immersive_widgets.dart';

/// 沉浸观影搜索页：大搜索框 + 横图结果墙。
class ImmersiveSearchPage extends StatefulWidget {
  const ImmersiveSearchPage({super.key});

  @override
  State<ImmersiveSearchPage> createState() => _ImmersiveSearchPageState();
}

class _ImmersiveSearchPageState extends State<ImmersiveSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  final FocusNode _firstResultFocus = FocusNode(
    debugLabel: 'immersive-search-first-result',
  );
  StreamSubscription<SearchProgress>? _sub;
  String _keyword = '';
  bool _searching = false;
  bool _focusResults = false;
  bool _hasText = false;

  /// 输入即搜：停止输入 450ms 后自动搜索，避免每敲一个字就全源检索。
  Timer? _debounce;
  static const _debounceDuration = Duration(milliseconds: 450);

  /// [_submit] 回填输入框时抑制监听，防止自己触发一次多余搜索。
  bool _syncingText = false;
  List<VodItem> _items = const [];
  SearchProgress? _progress;
  int _handledSeq = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _sub?.cancel();
    _controller.dispose();
    _focus.dispose();
    _firstResultFocus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (_syncingText) return;
    final hasText = _controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    _debounce?.cancel();
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) {
      _resetResults();
      return;
    }
    if (keyword == _keyword) return;
    _debounce = Timer(_debounceDuration, () => _submit(keyword, auto: true));
  }

  /// 清空输入 / 退格到空：取消正在进行的搜索并回到最近搜索。
  void _resetResults() {
    if (_keyword.isEmpty && _items.isEmpty && !_searching) return;
    unawaited(_sub?.cancel());
    _sub = null;
    if (!mounted) return;
    setState(() {
      _keyword = '';
      _searching = false;
      _focusResults = false;
      _items = const [];
      _progress = null;
    });
  }

  /// [auto] 为输入即搜的自动检索：不记历史、不把焦点从输入框抢走。
  Future<void> _submit(String raw, {bool auto = false}) async {
    _debounce?.cancel();
    final keyword = raw.trim();
    if (keyword.isEmpty) return;
    // 同一个词正在搜：输入框回填 / 连按回车不再重复发起。
    if (keyword == _keyword && _searching) return;
    if (_controller.text != keyword) {
      _syncingText = true;
      _controller.text = keyword;
      _syncingText = false;
    }
    final app = AppScope.of(context);
    await _sub?.cancel();
    if (!mounted) return;
    setState(() {
      _keyword = keyword;
      _searching = true;
      _focusResults = !auto;
      _hasText = true;
      _items = const [];
      _progress = null;
    });
    if (!auto) unawaited(app.addSearchKeyword(keyword));
    _sub = app.searchService
        .search(keyword, app.usableSites)
        .listen(
          (progress) {
            if (!mounted) return;
            setState(() {
              _progress = progress;
              _items = progress.items;
              _searching = !progress.finished;
            });
            if (_focusResults && progress.items.isNotEmpty) {
              _focusResults = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _firstResultFocus.requestFocus();
              });
            } else if (progress.finished) {
              _focusResults = false;
            }
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _searching = false;
              _focusResults = false;
              _keyword = keyword;
            });
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('搜索失败：$error')));
          },
        );
  }

  /// `vod_tag=folder` 条目：进入它的分类页逐层展开，而不是打开详情。
  void _openFolder(VodItem item) {
    final app = AppScope.of(context);
    final site =
        app.siteByKey(item.sourceKey) ??
        (item.sourceKey.isEmpty ? app.activeSite : null);
    if (site == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('找不到该目录所属的站点，请重新选择或导入源')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImmersiveCategoryPage(
          site: site,
          sortClass: SortClass(id: item.id, name: item.name),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.pendingSearchSeq != _handledSeq) {
      _handledSeq = app.pendingSearchSeq;
      final keyword = app.pendingSearchKeyword ?? '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && keyword.isNotEmpty) _submit(keyword);
      });
    }
    final theme = Theme.of(context);
    final m = ImmersiveMetrics.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(m.gutter, m.contentTop, m.gutter, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '搜索',
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '输入片名，跨源检索后可进入沉浸式详情页',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.48),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _submit,
                    style: theme.textTheme.titleMedium,
                    decoration: InputDecoration(
                      hintText: '搜索电影 / 剧集 / 综艺',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: !_hasText
                          ? null
                          : IconButton(
                              tooltip: '清空',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              // 监听器会取消防抖、取消在途搜索并清空结果。
                              onPressed: _controller.clear,
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              FilledButton.icon(
                onPressed: () => _submit(_controller.text),
                icon: const Icon(Icons.search_rounded),
                label: const Text('搜索'),
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.compact ? 16 : 28,
                    vertical: m.compact ? 12 : 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_searching && _progress != null)
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '已搜索 ${_progress!.done}/${_progress!.total} 个源 · '
                  '${_items.length} 条结果',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.52),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 16),
          Expanded(child: _buildBody(app)),
        ],
      ),
    );
  }

  Widget _buildBody(AppState app) {
    final theme = Theme.of(context);
    final m = ImmersiveMetrics.of(context);
    if (_keyword.isEmpty) {
      return _historyOrHint(app, theme);
    }
    // 搜索刚发起时首个源还没返回，_progress 仍是 null；此时不能再返回空
    // GridView，否则整页看起来「点了没反应」。
    if (_items.isEmpty && _searching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              '正在搜索「$_keyword」…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.58),
              ),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty && !_searching) {
      return Center(
        child: ImmersiveEmpty(
          title: '没有找到「$_keyword」',
          message: '换一个片名，或确认当前源可用',
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: m.posterMaxExtent,
        mainAxisExtent: m.cardExtent,
        crossAxisSpacing: 18,
        mainAxisSpacing: 22,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return ImmersiveCard(
          focusNode: index == 0 ? _firstResultFocus : null,
          title: item.name,
          year: item.year,
          subtitle: item.remarks.isEmpty
              ? item.sourceName
              : '${item.sourceName} · ${item.remarks}',
          fallback: item.cleanPic,
          imageHeaders: item.picHeaders,
          badge: item.isFolder
              ? '分类'
              : (item.sameFromOtherSources > 0
                    ? '${item.sameFromOtherSources + 1} 源'
                    : ''),
          // 竖版海报 + 片名放在图下，和小窗口列表一致。
          showText: false,
          width: double.infinity,
          onTap: () => item.isFolder
              ? _openFolder(item)
              : openImmersiveItem(context, item),
        );
      },
    );
  }

  Widget _historyOrHint(AppState app, ThemeData theme) {
    if (app.searchHistory.isEmpty) {
      return Center(
        child: ImmersiveEmpty(
          title: '大屏观影，从搜索开始',
          message: '支持跨源搜索，结果直接进入沉浸式详情页',
          action: FilledButton.tonalIcon(
            onPressed: () => _focus.requestFocus(),
            icon: const Icon(Icons.keyboard_rounded),
            label: const Text('开始输入'),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '最近搜索',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final keyword in app.searchHistory.take(12))
                ActionChip(
                  label: Text(keyword),
                  onPressed: () => _submit(keyword),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
