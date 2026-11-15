import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/vod.dart';
import '../../state/app_state.dart';
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
  StreamSubscription<SearchProgress>? _sub;
  String _keyword = '';
  bool _searching = false;
  List<VodItem> _items = const [];
  SearchProgress? _progress;
  int _handledSeq = 0;

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit(String raw) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) return;
    _controller.text = keyword;
    final app = AppScope.of(context);
    await app.addSearchKeyword(keyword);
    await _sub?.cancel();
    setState(() {
      _keyword = keyword;
      _searching = true;
      _items = const [];
      _progress = null;
    });
    _sub = app.searchService.search(keyword, app.usableSites).listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _progress = progress;
          _items = progress.items;
          _searching = !progress.finished;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _searching = false;
          _keyword = keyword;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('搜索失败：$error')));
      },
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
                      suffixIcon: _keyword.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清空',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                _controller.clear();
                                setState(() {
                                  _keyword = '';
                                  _items = const [];
                                  _progress = null;
                                });
                              },
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
        maxCrossAxisExtent: 336,
        mainAxisExtent: m.cardExtent,
        crossAxisSpacing: 18,
        mainAxisSpacing: 22,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return ImmersiveCard(
          title: item.name,
          year: item.year,
          // 搜索结果很多是长标题的视频/切片；封面按用户搜索的剧名匹配，
          // 而不是拿整条资源名去撞元数据。
          artworkTitle:
              _keyword.isNotEmpty &&
                  item.name.toLowerCase().contains(_keyword.toLowerCase())
              ? _keyword
              : '',
          subtitle: item.remarks.isEmpty
              ? item.sourceName
              : '${item.sourceName} · ${item.remarks}',
          fallback: item.cleanPic,
          badge: item.sameFromOtherSources > 0
              ? '${item.sameFromOtherSources + 1} 源'
              : '',
          showText: false,
          width: double.infinity,
          onTap: () => openImmersiveItem(context, item),
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
