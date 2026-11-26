import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../../services/quotes/movie_quotes.dart';
import '../../state/app_state.dart';
import '../pages/detail_page.dart';
import '../widgets/drive_config_sheet.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/import_sheet.dart';
import '../widgets/mouse_drag_scroll.dart';
import '../widgets/poster_card.dart';
import '../widgets/source_picker.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _loadedSiteKey;
  CmsResult? _data;
  final List<VodItem> _items = [];
  String? _tid;
  int _pg = 1;

  /// 当前分类是否还有下一页。
  bool _hasMore = false;
  Map<String, String> _filters = {};

  /// `vod_tag=1/folder` 的分类文件夹栈（例如直播源的「网游 → 英雄联盟」）。
  final List<_FolderEntry> _folders = [];

  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  /// 分类浏览方式：true = 瀑布（滑到底自动加载），false = 换页。
  bool _waterfall = false;

  /// 本次加载因内容过滤隐藏的条数（用于页头提示）。
  int _hidden = 0;

  /// 加载超过几秒后显示「首次转换 / 解包」提示，避免只看到骨架屏。
  Timer? _slowTimer;
  bool _slowLoading = false;

  /// 站点 / 分类切换后，旧请求的结果直接丢弃。
  int _loadSeq = 0;

  final _scrollController = ScrollController();
  final _pageInput = TextEditingController(text: '1');

  /// 分类条的位置：换页后不要滚回应用大标题，而是停在这里。
  final _categoryBarKey = GlobalKey();
  bool _showBackToTop = false;

  static const _backToTopOffset = 520.0;

  /// 瀑布模式下滑到距离底部这么近时开始加载下一页。
  static const _autoLoadThreshold = 320.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final waterfall = AppScope.of(context).homeBrowseMode == 1;
    if (_waterfall == waterfall) return;
    final wasWaterfall = _waterfall;
    _waterfall = waterfall;
    // 瀑布累积了多页后切回换页：重新只加载当前页，避免内容和页码对不上。
    if (wasWaterfall && !waterfall && _tid != null && _pg > 1) {
      final tid = _tid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && tid != null) _loadCategory(tid, page: _pg);
      });
    }
  }

  void _onScroll() {
    final show =
        _scrollController.hasClients &&
        _scrollController.offset > _backToTopOffset;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
    if (_waterfall) _maybeAutoLoadMore();
  }

  void _maybeAutoLoadMore() {
    if (!_waterfall || _tid == null || !_hasMore) return;
    if (_loading || _loadingMore) return;
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter > _autoLoadThreshold) return;
    _loadCategory(_tid, append: true);
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _pageInput.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// 内容过滤的签名：开关或关键词变化后首页要按新规则重新加载。
  String _filterSignature(AppState app) {
    final filter = app.contentFilter;
    if (!filter.active) return '0';
    return '1:${filter.keywords.join('\u0001')}';
  }

  void _scheduleSync(AppState app) {
    final key =
        '${app.activeProfileId ?? ''}|${app.activeSite?.key ?? ''}|${_filterSignature(app)}';
    if (key == _loadedSiteKey) return;
    // 站点 / 过滤规则变化时即使上一请求还在跑也重新发起；旧请求由 _loadSeq 丢弃。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadHome();
    });
  }

  /// JAR / 加固壳源首次使用要转换、解包，给足时间；CMS 按站点超时收口。
  Duration _loadTimeout(SourceBean site) {
    if (site.isJarSpider) return const Duration(minutes: 5);
    if (site.type == 3) return Duration(seconds: site.timeout + 45);
    return Duration(seconds: site.timeout + 12);
  }

  void _startSlowHint() {
    _slowTimer?.cancel();
    _slowLoading = false;
    _slowTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && _loading) setState(() => _slowLoading = true);
    });
  }

  void _stopSlowHint() {
    _slowTimer?.cancel();
    _slowTimer = null;
    _slowLoading = false;
  }

  String _timeoutMessage(SourceBean site) {
    if (site.isJarSpider) {
      return '「${site.displayName}」首次加载超时：正在后台转换 / 解包 JAR 蜘蛛，可能需要几分钟；稍后点重试即可';
    }
    return '「${site.displayName}」加载超时（${_loadTimeout(site).inSeconds} 秒），请检查网络或切换站点后重试';
  }

  /// 内容过滤开启时，把命中屏蔽词的条目从浏览列表里剔除。
  List<VodItem> _visibleItems(AppState app, List<VodItem> items) {
    final filter = app.contentFilter;
    if (!filter.active) return items;
    return items.where((item) => !filter.blocksVod(item)).toList();
  }

  /// 内容过滤开启时，把命中屏蔽词的分类（如「伦理片」）从分类栏剔除，
  /// 同时剔除分类筛选里的成人选项（很多源把「伦理片」放在「类型」筛选中）。
  List<SortClass> _visibleClasses(AppState app, List<SortClass> classes) {
    final filter = app.contentFilter;
    if (!filter.active) return classes;
    final out = <SortClass>[];
    for (final cls in classes) {
      final visible = filter.visibleClass(cls);
      if (visible != null) out.add(visible);
    }
    return out;
  }

  Future<void> _loadHome() async {
    final app = AppScope.of(context);
    final site = app.activeSite;
    _folders.clear();
    // 网盘配置源返回的是 Android 操作项，桌面端直接展示宿主自己的登录面板，
    // 不再拉起蜘蛛（部分壳类在桌面端会卡在解包/初始化，首页永远等不到结果）。
    if (site != null && isDriveConfigSource(site)) {
      _loadSeq++;
      _stopSlowHint();
      setState(() {
        _loadedSiteKey =
            '${app.activeProfileId ?? ''}|${site.key}|${_filterSignature(app)}';
        _data = null;
        _items.clear();
        _hidden = 0;
        _loading = false;
        _loadingMore = false;
        _slowLoading = false;
        _error = null;
        _tid = null;
        _pg = 1;
        _hasMore = false;
        _pageInput.text = '1';
      });
      return;
    }
    if (site == null) {
      _loadSeq++;
      _stopSlowHint();
      setState(() {
        _loadedSiteKey =
            '${app.activeProfileId ?? ''}||${_filterSignature(app)}';
        _data = null;
        _items.clear();
        _hidden = 0;
        _loading = false;
        _loadingMore = false;
        _slowLoading = false;
        _error = null;
        _tid = null;
        _pg = 1;
        _hasMore = false;
        _pageInput.text = '1';
      });
      return;
    }
    final seq = ++_loadSeq;
    _loadedSiteKey =
        '${app.activeProfileId ?? ''}|${site.key}|${_filterSignature(app)}';
    setState(() {
      _loading = true;
      _loadingMore = false;
      _slowLoading = false;
      _error = null;
      _tid = null;
      _filters = {};
      _pg = 1;
      _hasMore = false;
      _pageInput.text = '1';
      _items.clear();
      _hidden = 0;
    });
    _startSlowHint();
    try {
      final result = await app.sourceService
          .home(site)
          .timeout(_loadTimeout(site));
      if (!mounted || seq != _loadSeq) return;
      _stopSlowHint();
      final visible = _visibleItems(app, result.items);
      final classes = _visibleClasses(app, result.classes);
      setState(() {
        _data = CmsResult(
          classes: classes,
          items: visible,
          page: result.page,
          pagecount: result.pagecount,
          total: result.total,
          homeFallback: result.homeFallback,
        );
        _items
          ..clear()
          ..addAll(visible);
        _hidden = result.items.length - visible.length;
        _loading = false;
        _slowLoading = false;
      });
    } on TimeoutException {
      if (!mounted || seq != _loadSeq) return;
      _stopSlowHint();
      setState(() {
        _loading = false;
        _slowLoading = false;
        _error = _timeoutMessage(site);
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      _stopSlowHint();
      setState(() {
        _loading = false;
        _slowLoading = false;
        _error = e.toString();
      });
    }
  }

  /// 加载分类页。[append] 为 true 时按瀑布模式追加下一页，否则按指定页码整页替换。
  Future<void> _loadCategory(
    String? tid, {
    int page = 1,
    bool append = false,
    Map<String, String>? filters,
  }) async {
    final app = AppScope.of(context);
    final site = app.activeSite;
    if (site == null) return;
    if (tid == null) {
      await _loadHome();
      return;
    }
    if (append && (_loadingMore || _loading)) return;
    final seq = ++_loadSeq;
    // 切换分类时必须丢掉上一分类的筛选条件：采集聚合类 PY 源的每个子站
    // 支持的筛选值不同，把上一站的「类型=伦理片」带过去会让新站整页 0 条，
    // 看起来像整个站点被屏蔽。
    final switchedCategory = _tid != tid;
    final targetPage = append ? _pg + 1 : math.max(1, page);
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        _slowLoading = false;
        _error = null;
      }
      _tid = tid;
      if (filters != null) {
        _filters = filters;
      } else if (switchedCategory) {
        _filters = {};
      }
    });
    if (!append) _startSlowHint();
    try {
      final result = await app.sourceService
          .category(site, tid, '$targetPage', _filters)
          .timeout(_loadTimeout(site));
      if (!mounted || seq != _loadSeq) return;
      if (!append) _stopSlowHint();
      final visible = _visibleItems(app, result.items);
      final hidden = result.items.length - visible.length;
      setState(() {
        if (append) {
          _items.addAll(visible);
          _hidden += hidden;
          _loadingMore = false;
        } else {
          _items
            ..clear()
            ..addAll(visible);
          _hidden = hidden;
          _data = CmsResult(
            // 分类接口一般不带 class 列表，沿用首页已过滤的那份。
            classes: result.classes.isNotEmpty
                ? _visibleClasses(app, result.classes)
                : (_data?.classes ?? const []),
            items: visible,
            page: result.page,
            pagecount: result.pagecount,
            total: result.total,
          );
          _loading = false;
          _slowLoading = false;
        }
        _pg = targetPage;
        _pageInput.text = '$targetPage';
        _hasMore = result.pagecount > 0
            ? targetPage < result.pagecount
            : visible.isNotEmpty;
      });
      if (append) {
        // 追加后若仍在底部（首屏内容不足），继续按需加载。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeAutoLoadMore();
        });
      } else {
        // 换页 / 换分类后停在分类条位置（大标题滚出视野），不滚回最顶部；
        // 瀑布模式首屏内容不足一屏时继续补下一页。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollToBrowseTop();
          if (_waterfall) _maybeAutoLoadMore();
        });
      }
    } on TimeoutException {
      if (!mounted || seq != _loadSeq) return;
      if (append) {
        setState(() => _loadingMore = false);
        _toast('加载更多超时，请稍后重试');
        return;
      }
      _stopSlowHint();
      setState(() {
        _loading = false;
        _slowLoading = false;
        _error = _timeoutMessage(site);
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      if (append) {
        setState(() => _loadingMore = false);
        _toast('加载更多失败：$e');
        return;
      }
      _stopSlowHint();
      setState(() {
        _loading = false;
        _loadingMore = false;
        _slowLoading = false;
        _error = e.toString();
      });
    }
  }

  /// 失败状态下的重试：分类页重试当前页，推荐页重新加载首页。
  void _retry() {
    final tid = _tid;
    if (tid != null) {
      _loadCategory(tid, page: _pg);
    } else {
      _loadHome();
    }
  }

  /// 下拉刷新：重新拉取当前视图（推荐页重载首页，分类页重载当前分类页）。
  /// 源站偶尔首屏拉不到数据，给用户一个触手可及的重新加载入口。
  Future<void> _onRefresh() async {
    final tid = _tid;
    if (tid != null) {
      await _loadCategory(tid, page: _pg);
    } else {
      await _loadHome();
    }
  }

  /// 把分类条顶到视口顶部：换页后只看当前页、不回到应用大标题。
  void _scrollToBrowseTop() {
    final ctx = _categoryBarKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0);
      return;
    }
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// 输入页码跳转（换页模式）。
  void _jumpToPage(String value) {
    final tid = _tid;
    if (tid == null) return;
    final page = int.tryParse(value.trim());
    if (page == null || page < 1) {
      _toast('请输入正确的页码');
      return;
    }
    final pageCount = _data?.pagecount ?? 0;
    if (pageCount > 0 && page > pageCount) {
      _toast('页码超出范围，共 $pageCount 页');
      return;
    }
    if (page == _pg && _items.isNotEmpty) return;
    _loadCategory(tid, page: page);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFilters(SortClass? cls) async {
    if (cls == null || cls.filters.isEmpty) return;
    final selected = Map<String, String>.from(_filters);
    final applied = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _FilterSheet(groups: cls.filters, initial: selected),
    );
    if (applied != null) {
      await _loadCategory(cls.id, filters: applied);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    _scheduleSync(app);

    if (app.config == null) return const _OnboardingView();

    final site = app.activeSite;
    // 网盘配置源不依赖 JVM / 蜘蛛：即使加固壳解包失败也先给出宿主的登录面板。
    if (site != null && isDriveConfigSource(site)) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 720;
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        isNarrow ? 18 : 28,
                        8,
                        isNarrow ? 18 : 28,
                        12,
                      ),
                      child: _Header(
                        onImport: () => _showImport(context),
                        onPickSource: () => showSourcePicker(context),
                        hidden: 0,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
                          child: DriveConfigPanel(app: app, site: site),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    if (site == null || !app.isSiteUsable(site)) {
      return _UnsupportedSourceView(site: site);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final waterfall = app.homeBrowseMode == 1;
        final width = constraints.maxWidth;
        final isNarrow = width < 720;
        final maxContent = width;
        // 每行封面固定 3 个：不再提供 4-8 / 自动列数设置（其他列数不好看）。
        const columns = 3;
        final gridPadding = isNarrow ? 18.0 : 28.0;
        const gridSpacing = 14.0;
        var maxExtent = 188.0;
        var mainExtent = 292.0;
        final SliverGridDelegate gridDelegate;
        if (columns >= 2) {
          final gridWidth = maxContent - gridPadding * 2;
          final extent = gridWidth > 0
              ? (gridWidth - gridSpacing * (columns - 1)) / columns
              : 188.0;
          final cardWidth = extent > 0 ? extent : 188.0;
          gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: cardWidth * 292 / 188,
            crossAxisSpacing: gridSpacing,
            mainAxisSpacing: 18,
          );
        } else {
          if (!kIsWeb &&
              defaultTargetPlatform == TargetPlatform.android &&
              MediaQuery.orientationOf(context) == Orientation.portrait) {
            // 安卓手机竖屏：自动模式下至少排 3 个封面，避免一行只有两张、
            // 封面巨大且首屏只能看到两三部片。
            final gridWidth = maxContent - gridPadding * 2;
            if (gridWidth > 0) {
              final extent = (gridWidth - gridSpacing * 2) / 3;
              maxExtent = extent.clamp(96.0, 188.0);
              mainExtent = maxExtent * 1.5 + 44;
            }
          }
          gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            mainAxisExtent: mainExtent,
            crossAxisSpacing: gridSpacing,
            mainAxisSpacing: 18,
          );
        }
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContent),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RefreshIndicator(
                  onRefresh: _onRefresh,
                  // 加载失败 / 空列表时内容不足一屏，仍要能下拉触发重新加载。
                  notificationPredicate: (notification) =>
                      notification.depth == 0,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    controller: _scrollController,
                    slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          isNarrow ? 18 : 28,
                          8,
                          isNarrow ? 18 : 28,
                          12,
                        ),
                        child: _Header(
                          onImport: () => _showImport(context),
                          onPickSource: () => showSourcePicker(context),
                          hidden: _hidden,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        key: _categoryBarKey,
                        padding: EdgeInsets.fromLTRB(
                          isNarrow ? 18 : 28,
                          10,
                          isNarrow ? 18 : 28,
                          10,
                        ),
                        child: _CategoryBar(
                          classes: _data?.classes ?? const [],
                          selected: _folders.isEmpty
                              ? _tid
                              : _folders.first.parentTid,
                          hasFilters:
                              _currentClass?.filters.isNotEmpty ?? false,
                          onSelect: (id) {
                            _folders.clear();
                            _loadCategory(id);
                          },
                          onFilter: () {
                            final cls = _currentClass;
                            _pickFilters(cls);
                          },
                        ),
                      ),
                    ),
                    if (_folders.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            isNarrow ? 18 : 28,
                            0,
                            isNarrow ? 18 : 28,
                            8,
                          ),
                          child: Row(
                            children: [
                              TextButton.icon(
                                onPressed: _leaveFolder,
                                icon: const Icon(
                                  Icons.arrow_back_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  _folders.last.parentName.isEmpty
                                      ? '返回分类'
                                      : '返回「${_folders.last.parentName}」',
                                ),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _folders
                                      .map((folder) => folder.name)
                                      .join(' / '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.55),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_loading) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            isNarrow ? 18 : 28,
                            2,
                            isNarrow ? 18 : 28,
                            6,
                          ),
                          child: _LoadingBanner(
                            siteName: site.displayName,
                            jarSource: site.isJarSpider,
                            slow: _slowLoading,
                            onPickSource: () => showSourcePicker(context),
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isNarrow ? 18 : 28,
                        ),
                        sliver: _SkeletonGrid(gridDelegate: gridDelegate),
                      ),
                    ] else if (_error != null)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.cloud_off_rounded,
                          title: '加载失败',
                          message: _error,
                          action: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: _retry,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('重试'),
                              ),
                              TextButton.icon(
                                onPressed: () => showSourcePicker(context),
                                icon: const Icon(Icons.dns_rounded),
                                label: const Text('切换站点'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (_items.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.movie_filter_outlined,
                          title: _hidden > 0 ? '内容被过滤规则隐藏' : '这个站点暂时没有内容',
                          message: _hidden > 0
                              ? '本页 $_hidden 条内容命中了屏蔽词，可在 设置 → 内容过滤 里调整'
                              : '换一个站点或分类看看',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          isNarrow ? 18 : 28,
                          4,
                          isNarrow ? 18 : 28,
                          12,
                        ),
                        sliver: SliverGrid(
                          gridDelegate: gridDelegate,
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final item = _items[index];
                            return PosterCard(
                              item: item,
                              badge: item.isFolder ? '分类' : '',
                              onTap: () => _openDetail(context, item),
                              onSecondaryLongPress: () =>
                                  AppScope.of(context).requestSearch(item.name),
                            );
                          }, childCount: _items.length),
                        ),
                      ),
                    if (!_loading && _items.isNotEmpty && _tid != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
                          child: Center(
                            child: waterfall
                                ? (_loadingMore
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const SizedBox.shrink())
                                : _PageBar(
                                    page: _pg,
                                    pageCount: _data?.pagecount ?? 0,
                                    hasMore: _hasMore,
                                    loading: _loading,
                                    controller: _pageInput,
                                    onPrev: () =>
                                        _loadCategory(_tid, page: _pg - 1),
                                    onNext: () =>
                                        _loadCategory(_tid, page: _pg + 1),
                                    onJump: _jumpToPage,
                                  ),
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 56)),
                    ],
                  ),
                ),
                // 换页模式不展示「回到顶部」；瀑布模式保留。
                if (waterfall)
                  Positioned(
                    right: 18,
                    bottom: 16,
                    child: IgnorePointer(
                      ignoring: !_showBackToTop,
                      child: AnimatedOpacity(
                        opacity: _showBackToTop ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        child: Tooltip(
                          message: '回到顶部',
                          child: Material(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.9),
                            elevation: 3,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => _scrollController.animateTo(
                                0,
                                duration: const Duration(milliseconds: 320),
                                curve: Curves.easeOutCubic,
                              ),
                              child: SizedBox(
                                width: 42,
                                height: 42,
                                child: Icon(
                                  Icons.vertical_align_top_rounded,
                                  size: 20,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  SortClass? get _currentClass {
    if (_tid == null) return null;
    for (final c in _data?.classes ?? const <SortClass>[]) {
      if (c.id == _tid) return c;
    }
    return null;
  }

  /// 点击 `vod_tag=1/folder` 条目时进入它的分类页，而不是打开详情。
  ///
  /// 直播源（虎牙/斗鱼等）会先用一组游戏封面当二级分类，详情接口只接受
  /// 房间 id；拿分类 id 去调 detailContent 会得到 Python UnboundLocalError。
  void _enterFolder(VodItem item) {
    final parentTid = _tid ?? '';
    final parentName = _folders.isNotEmpty
        ? _folders.last.name
        : (_currentClass?.name ?? '');
    _folders.add(
      _FolderEntry(
        id: item.id,
        name: item.name,
        parentTid: parentTid,
        parentName: parentName,
        filters: Map<String, String>.from(_filters),
      ),
    );
    unawaited(_loadCategory(item.id));
  }

  void _leaveFolder() {
    if (_folders.isEmpty) return;
    final entry = _folders.removeLast();
    unawaited(
      _loadCategory(
        entry.parentTid.isEmpty ? null : entry.parentTid,
        filters: entry.filters,
      ),
    );
  }

  void _openDetail(BuildContext context, VodItem item) {
    if (item.isFolder) {
      _enterFolder(item);
      return;
    }
    final app = AppScope.of(context);
    // 云盘配置源返回的是「登入 / 清除 / 排序 / 授权」这类操作项，没有影片详情；
    // 直接换成宿主的网盘登录面板，否则点进去只有一段说明。
    final configSite = _driveConfigSite(app, item);
    if (configSite != null) {
      unawaited(showDriveConfigActionSheet(context, app, item, configSite));
      return;
    }
    // 豆瓣/豆豆片单这类推荐源只有推荐数据（详情为空、没有可播线路），
    // 点击直接全源搜索片名。部分推荐卡片还会把片名本身当作 id。
    final titleOnly =
        item.id.trim().isNotEmpty && item.id.trim() == item.name.trim();
    if (app.activeSiteIsDouban ||
        app.isDoubanSourceKey(item.sourceKey) ||
        titleOnly) {
      app.requestSearch(item.name);
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DetailPage(item: item)));
  }

  /// 条目所属的站点是网盘配置源时返回它（当前站点优先，其次按来源 key 找回）。
  SourceBean? _driveConfigSite(AppState app, VodItem item) {
    final active = app.activeSite;
    if (active != null && isDriveConfigSource(active)) return active;
    for (final site in app.config?.sites ?? const <SourceBean>[]) {
      if (site.key == item.sourceKey && isDriveConfigSource(site)) return site;
    }
    return null;
  }

  void _showImport(BuildContext context) async {
    final outcome = await showImportConfigSheet(context);
    if (outcome == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已导入 ${outcome.profile.name} · ${outcome.report.ok} 个可用站点'
          '${outcome.report.degraded > 0 ? '，${outcome.report.degraded} 个降级' : ''}',
        ),
      ),
    );
    await _loadHome();
  }
}

/// 首页里一次 `vod_tag=1/folder` 的下钻记录，用于返回上一级并还原筛选。
class _FolderEntry {
  const _FolderEntry({
    required this.id,
    required this.name,
    required this.parentTid,
    required this.parentName,
    required this.filters,
  });

  final String id;
  final String name;
  final String parentTid;
  final String parentName;
  final Map<String, String> filters;
}

class _Header extends StatefulWidget {
  const _Header({
    required this.onImport,
    required this.onPickSource,
    this.hidden = 0,
  });
  final VoidCallback onImport;
  final VoidCallback onPickSource;

  /// 本页被内容过滤隐藏的条数；0 时不显示提示。
  final int hidden;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  /// 影视台词自动轮换间隔。
  static const _quoteInterval = Duration(seconds: 30);

  final math.Random _random = math.Random();
  List<MovieQuote> _quotes = movieQuotes;
  late int _quoteIndex = _random.nextInt(_quotes.length);
  Timer? _quoteTimer;
  bool _quotesRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    // 关闭台词轮换时停掉定时器，不再产生不必要的定时刷新。
    _syncQuoteTimer(app.showMovieQuotes);
    if (!app.showMovieQuotes || _quotesRequested) return;
    _quotesRequested = true;
    // 先用上次缓存顶上，再异步刷新在线台词库。
    final cached = app.quoteService.cachedPool;
    if (cached.isNotEmpty) {
      _quotes = cached;
      _quoteIndex = _random.nextInt(_quotes.length);
    }
    unawaited(_loadOnlineQuotes(app));
  }

  void _syncQuoteTimer(bool enabled) {
    if (!enabled) {
      _quoteTimer?.cancel();
      _quoteTimer = null;
      return;
    }
    _quoteTimer ??= Timer.periodic(_quoteInterval, (_) => _nextQuote());
  }

  Future<void> _loadOnlineQuotes(AppState app) async {
    final quotes = await app.quoteService.load();
    if (!mounted || quotes.isEmpty) return;
    setState(() {
      _quotes = quotes;
      _quoteIndex = _random.nextInt(_quotes.length);
    });
  }

  void _nextQuote() {
    if (!mounted || _quotes.length < 2) return;
    var next = _random.nextInt(_quotes.length);
    if (next == _quoteIndex) next = (next + 1) % _quotes.length;
    setState(() => _quoteIndex = next);
  }

  @override
  void dispose() {
    _quoteTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final quote = _quotes[_quoteIndex];
    final site = app.activeSite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 关掉台词轮换后整条头部收起：LOGO 与档案名都不显示，
        // 导入按钮下移到「N 个可用站点」那一行，和站点数量齐平。
        if (app.showMovieQuotes) ...[
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/images/app_icon.png',
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: '点击搜索《${quote.title}》',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => app.requestSearch(quote.searchKeyword),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 350),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            layoutBuilder: (currentChild, previousChildren) =>
                                Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [
                                    ...previousChildren,
                                    ?currentChild,
                                  ],
                                ),
                            child: Text(
                              quote.display,
                              key: ValueKey(_quoteIndex),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontSize: 20,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      app.activeProfile?.name ?? '本地优先 · 无账号 · 无遥测',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '导入配置',
                onPressed: widget.onImport,
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            // 左侧整组（站点 / 过滤提示 / 站点数）吃掉剩余宽度，
            // 导入按钮才能真的贴到行尾、和下面那行的筛选按钮同列。
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: widget.onPickSource,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.14,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.dns_rounded,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                site?.displayName ?? '未选择站点',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.unfold_more_rounded,
                              size: 14,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (widget.hidden > 0) ...[
                    Icon(
                      Icons.shield_outlined,
                      size: 14,
                      color: theme.colorScheme.primary.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '已过滤 ${widget.hidden} 条',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Text(
                    '${app.usableSites.length} 个可用站点',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 台词轮换关掉后导入按钮留在这条站点行，靠右和下面的筛选按钮同列。
            if (!app.showMovieQuotes) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: '导入配置',
                onPressed: widget.onImport,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.classes,
    required this.selected,
    required this.onSelect,
    required this.onFilter,
    required this.hasFilters,
  });

  final List<SortClass> classes;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final VoidCallback onFilter;

  /// 当前分类是否有筛选条件；没有时筛选按钮常驻但禁用。
  final bool hasFilters;

  @override
  Widget build(BuildContext context) {
    if (classes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            // 分类条与筛选按钮是两个组件：分类可以横向滚动，筛选固定在右侧。
            // 桌面端默认只允许触摸/触控板拖动滚动；分类一多，鼠标就拖不到后面的。
            child: ScrollConfiguration(
              behavior: const MouseDragScrollBehavior(),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _Chip(
                    label: '推荐',
                    selected: selected == null,
                    onTap: () => onSelect(null),
                    color: theme.colorScheme.primary,
                  ),
                  for (final c in classes)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: _Chip(
                        label: c.name,
                        selected: selected == c.id,
                        onTap: () => onSelect(c.id),
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          _FilterButton(hasFilters: hasFilters, onPressed: onFilter),
        ],
      ),
    );
  }
}

/// 固定筛选按钮：不参与分类横向滚动，始终停在分类条右侧。
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.hasFilters, required this.onPressed});

  final bool hasFilters;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = hasFilters;
    return Tooltip(
      message: enabled ? '筛选当前分类' : '当前分类没有可用的筛选项',
      child: ActionChip(
        avatar: Icon(
          Icons.tune_rounded,
          size: 16,
          color: enabled
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.38),
        ),
        label: const Text('筛选'),
        onPressed: enabled ? onPressed : null,
        backgroundColor: enabled
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : null,
      ),
    );
  }
}

/// 换页模式的底部页码条：上一页 / 页码输入 / 下一页 / 跳转。
class _PageBar extends StatelessWidget {
  const _PageBar({
    required this.page,
    required this.pageCount,
    required this.hasMore,
    required this.loading,
    required this.controller,
    required this.onPrev,
    required this.onNext,
    required this.onJump,
  });

  final int page;

  /// 总页数；0 表示源没有返回页数。
  final int pageCount;
  final bool hasMore;
  final bool loading;
  final TextEditingController controller;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<String> onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonStyle = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
    final totalLabel = pageCount > 0 ? '$pageCount' : '?';
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          style: buttonStyle,
          onPressed: loading || page <= 1 ? null : onPrev,
          icon: const Icon(Icons.chevron_left_rounded, size: 18),
          label: const Text('上一页'),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 56,
              height: 38,
              child: TextField(
                controller: controller,
                enabled: !loading,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.go,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 10,
                  ),
                  hintText: '页码',
                  hintStyle: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.32),
                  enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 1.4,
                    ),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                  disabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                ),
                onSubmitted: onJump,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '/ $totalLabel',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
            ),
          ],
        ),
        OutlinedButton.icon(
          style: buttonStyle,
          onPressed: loading || !hasMore ? null : onNext,
          icon: const Icon(Icons.chevron_right_rounded, size: 18),
          iconAlignment: IconAlignment.end,
          label: const Text('下一页'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          onPressed: loading ? null : () => onJump(controller.text),
          child: const Text('跳转'),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.color,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? color.withValues(alpha: 0.2)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              color: selected
                  ? color
                  : theme.colorScheme.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.groups, required this.initial});
  final List<FilterGroup> groups;
  final Map<String, String> initial;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final Map<String, String> _selected = Map.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('筛选', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final group in widget.groups) ...[
                    Text(group.name, style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in group.values)
                          ChoiceChip(
                            label: Text(option.n.isEmpty ? option.v : option.n),
                            selected: _selected[group.key] == option.v,
                            onSelected: (_) {
                              setState(() {
                                if (option.v.isEmpty) {
                                  _selected.remove(group.key);
                                } else {
                                  _selected[group.key] = option.v;
                                }
                              });
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(_selected.clear),
                  child: const Text('清空'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: const Text('应用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 首页加载中提示：JAR / 加固壳源首次使用要转换、解包，长时间只有骨架屏会像卡死。
class _LoadingBanner extends StatelessWidget {
  const _LoadingBanner({
    required this.siteName,
    required this.jarSource,
    required this.slow,
    required this.onPickSource,
  });

  final String siteName;
  final bool jarSource;
  final bool slow;
  final VoidCallback onPickSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
      height: 1.5,
    );
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      borderRadius: 16,
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正在加载「$siteName」…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (slow)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      jarSource
                          ? '首次使用该 JAR / 加固壳源会自动转换和解包，可能需要几分钟；也可以先切换其他站点。'
                          : '网络较慢或站点无响应，请稍候或切换站点。',
                      style: hint,
                    ),
                  ),
              ],
            ),
          ),
          if (slow)
            TextButton(onPressed: onPickSource, child: const Text('切换站点')),
        ],
      ),
    );
  }
}

class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid({required this.gridDelegate});

  final SliverGridDelegate gridDelegate;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest
        .withValues(alpha: 0.45);
    return SliverGrid(
      gridDelegate: gridDelegate,
      delegate: SliverChildBuilderDelegate(
        (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(height: 12, width: 100, color: color),
          ],
        ),
        childCount: 12,
      ),
    );
  }
}

class _OnboardingView extends StatelessWidget {
  const _OnboardingView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: GlassPanel(
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.playlist_play_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
                const SizedBox(height: 22),
                Text('把你的源带进来', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text(
                  'MisaTV 不内置任何影视源。导入你自己的 TVBox 订阅后，\n即可浏览、搜索与播放。数据只保存在本机。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.74),
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () async {
                    final outcome = await showImportConfigSheet(context);
                    if (outcome == null || !context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '已导入 ${outcome.report.total} 个站点，'
                          '${outcome.report.ok} 个可用',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('导入订阅'),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Feature(icon: Icons.bolt_rounded, label: '轻量'),
                    const SizedBox(width: 20),
                    _Feature(icon: Icons.lock_outline_rounded, label: '本地'),
                    const SizedBox(width: 20),
                    _Feature(icon: Icons.devices_rounded, label: '跨平台'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _UnsupportedSourceView extends StatelessWidget {
  const _UnsupportedSourceView({this.site});
  final SourceBean? site;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState(
        icon: Icons.extension_off_rounded,
        title: '当前站点暂不支持',
        message: site == null
            ? '这份配置里没有轻量内核可用的 CMS 源'
            : '${site!.displayName}：${site!.unsupportedReason}',
        action: FilledButton.tonalIcon(
          onPressed: () => showSourcePicker(context),
          icon: const Icon(Icons.swap_horiz_rounded),
          label: const Text('切换站点'),
        ),
      ),
    );
  }
}
