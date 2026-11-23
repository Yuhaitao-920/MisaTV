import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../models/vod.dart';
import '../../services/artwork/artwork_service.dart';
import '../../services/discover/discover_models.dart';
import '../../state/app_state.dart';
import '../widgets/mouse_drag_scroll.dart';
import 'focus_memory.dart';
import 'hero_title_style.dart';
import 'immersive_category_page.dart';
import 'immersive_metrics.dart';
import 'immersive_widgets.dart';

/// 沉浸观影首页：大屏海报轮播 + 横图卡片横向货架。
class ImmersiveHomePage extends StatefulWidget {
  const ImmersiveHomePage({super.key});

  @override
  State<ImmersiveHomePage> createState() => _ImmersiveHomePageState();
}

class _ImmersiveHomePageState extends State<ImmersiveHomePage> {
  String _siteKey = '__init__';
  bool _loading = true;
  String? _error;
  List<ImmersiveHeroItem> _hero = const [];
  List<({String title, List<_HomeEntry> items})> _shelves = const [];
  List<SortClass> _classes = const [];
  SourceBean? _site;
  int _total = 0;

  /// 焦点记忆：从详情页返回时恢复到刚才那张卡片，而不是跳回第一张。
  ///
  /// 这里不需要 onChanged 刷新界面：高亮由每张卡自己 setState，
  /// 外层只要在数据变化时调用 [_syncFocusKeys] 维护 key 集合即可。
  final FocusMemory _focusMemory = FocusMemory();

  /// `货架下标:条目下标` → FocusNode。按内容 key 缓存，列表刷新后复用同一节点。
  final Map<String, FocusNode> _focusNodes = {};

  /// 首页整体的键盘 / 遥控器焦点入口：方向键在货架之间移动。
  final FocusNode _rootFocus = FocusNode(debugLabel: 'immersive-home');

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _focusNodes.clear();
    _rootFocus.dispose();
    super.dispose();
  }

  /// 取（或建）某个卡片的焦点节点。
  FocusNode _focusNodeFor(String key) => _focusNodes.putIfAbsent(
    key,
    () => FocusNode(debugLabel: 'immersive-card-$key'),
  );

  /// 卡片 key 用「货架标题 + 条目 + 序号」而不是纯下标：
  /// 「继续观看」插到最前面时，其它货架的下标会整体后移，
  /// 纯下标会让焦点记忆指向另一张卡。
  String _shelfKey(int shelfIndex, int itemIndex) {
    final shelf = _shelves[shelfIndex];
    final entry = shelf.items[itemIndex];
    final id = entry.item?.id ?? entry.fallback;
    return '${shelf.title}|${entry.title}|$id|$itemIndex';
  }

  /// 货架内容变化后：同步有效 key，释放已消失卡片的节点。
  void _syncFocusKeys() {
    final keys = <String>[
      for (var s = 0; s < _shelves.length; s++)
        for (var i = 0; i < _shelves[s].items.length; i++) _shelfKey(s, i),
      for (var i = 0; i < _classes.length; i++) 'cls:$i',
    ];
    final removed = _focusMemory.syncKeys(keys);
    for (final key in removed) {
      final node = _focusNodes.remove(key);
      // 等旧卡片先卸载再释放节点，避免 Focus 还在树上时节点已 dispose。
      if (node != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => node.dispose());
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final key = app.activeSiteKey ?? '';
    if (key == _siteKey) return;
    _siteKey = key;
    _load();
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    final site = app.activeSite;
    final key = app.activeSiteKey ?? '';
    setState(() {
      _loading = true;
      _error = null;
      _hero = const [];
      _shelves = const [];
      _classes = const [];
      _site = null;
      _total = 0;
    });
    _syncFocusKeys();
    if (site == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final data = await app.sourceService.home(site);
      if (!mounted || key != (app.activeSiteKey ?? '')) return;
      final items = data.items;
      _total = items.length;
      setState(() {
        _loading = false;
        _site = site;
        _classes = [
          for (final cls in data.classes)
            if (cls.id.trim().isNotEmpty && cls.name.trim().isNotEmpty) cls,
        ];
        _hero = [
          for (final item in items.take(6)) _heroItemOf(item, site, app),
        ];
        _shelves = [
          if (items.isNotEmpty)
            (
              title: '当前源 · 热门',
              items: [for (final item in items.take(24)) _entryOf(item, site)],
            ),
        ];
      });
      _syncFocusKeys();
      if (items.isNotEmpty) _restoreFocusSoon();
      if (items.isEmpty) {
        await _loadDoubanFallback(app);
        await _loadContinueWatching(app);
        return;
      }
      // Hero 标题字体要按类型 / 国家选择：豆瓣元数据异步补全，
      // 到了再替换对应条目，不阻塞首屏。
      unawaited(
        _loadHeroInfo([
          for (final item in items.take(6)) (title: item.name, year: item.year),
        ]),
      );
      unawaited(_loadCategoryShelves(app, site, data.classes, key));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
    if (mounted) await _loadContinueWatching(app);
  }

  Future<void> _loadContinueWatching(AppState app) async {
    final map = <String, HistoryItem>{};
    for (final item in app.history.take(12)) {
      map.putIfAbsent(item.key, () => item);
    }
    if (map.isEmpty || !mounted) return;
    final entries = <_HomeEntry>[
      for (final item in map.values)
        _HomeEntry(
          title: item.name,
          year: '',
          subtitle: item.episodeName.isEmpty
              ? item.sourceName
              : item.episodeName,
          fallback: item.pic,
          badge: item.episodeName.isEmpty ? '' : item.episodeName,
          progress: item.progress,
          resume: true,
          item: VodItem(
            id: item.vodId,
            name: item.name,
            pic: item.pic,
            sourceKey: item.sourceKey,
            sourceName: item.sourceName,
            remarks: item.remarks,
          ),
        ),
    ];
    setState(() {
      _shelves = [(title: '继续观看', items: entries), ..._shelves];
    });
    _syncFocusKeys();
  }

  Future<void> _loadCategoryShelves(
    AppState app,
    SourceBean site,
    List<SortClass> classes,
    String key,
  ) async {
    final picked = classes
        .where((cls) => cls.id.trim().isNotEmpty && cls.name.trim().isNotEmpty)
        .take(2)
        .toList();
    for (final cls in picked) {
      try {
        final result = await app.sourceService.category(
          site,
          cls.id,
          '1',
          const {},
        );
        if (!mounted || key != (app.activeSiteKey ?? '')) return;
        final items = result.items.take(20).toList();
        if (items.isEmpty) continue;
        setState(() {
          _shelves = [
            ..._shelves,
            (
              title: cls.name,
              items: [for (final item in items) _entryOf(item, site)],
            ),
          ];
        });
        _syncFocusKeys();
      } catch (_) {
        // 单个分类失败不影响其它货架
      }
    }
  }

  Future<void> _loadDoubanFallback(AppState app) async {
    try {
      final sections = await app.discoverService.loadSections();
      if (!mounted) return;
      _classes = const [];
      final filled = [
        for (final s in sections)
          if (s.items.isNotEmpty) s,
      ];
      if (filled.isEmpty) return;
      final heroSource = filled.first.items.take(6).toList();
      setState(() {
        _hero = [
          for (final item in heroSource)
            ImmersiveHeroItem(
              title: item.title,
              year: item.year?.toString() ?? '',
              subtitle: '豆瓣推荐 · 全源搜索',
              fallback: item.posterUrl,
              actionLabel: '搜索片源',
              onTap: () => app.requestSearch(item.title),
            ),
        ];
        _shelves = [
          for (final section in filled.take(4))
            (
              title: section.title,
              items: [
                for (final item in section.items.take(20))
                  _HomeEntry(
                    title: item.title,
                    year: item.year?.toString() ?? '',
                    subtitle: item.mediaType == 'tv' ? '剧集' : '电影',
                    fallback: item.posterUrl,
                  ),
              ],
            ),
        ];
        _loading = false;
      });
      unawaited(
        _loadHeroInfo([
          for (final item in heroSource)
            (title: item.title, year: item.year?.toString() ?? ''),
        ]),
      );
      // 列表内容变了：同步焦点 key（释放已消失卡片的节点），
      // 数据到位后再恢复上次位置，否则此时节点还不存在。
      if (mounted) {
        _syncFocusKeys();
        _restoreFocusSoon();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 等一帧再恢复焦点：卡片要先进树，FocusNode 才能被 requestFocus。
  ///
  /// 不用「第一张卡」兜底：首页首屏是整屏 Hero，强行聚焦屏幕外的卡片
  /// 会让用户按回车打开一个看不见的条目。没有记忆时把焦点留给顶部 Tab。
  void _restoreFocusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _focusMemory.restoreTarget();
      if (target == null) return;
      final node = _focusNodes[target];
      if (node == null || !node.canRequestFocus) return;
      final context = node.context;
      if (context != null) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      node.requestFocus();
    });
  }

  ImmersiveHeroItem _heroItemOf(
    VodItem item,
    SourceBean site,
    AppState app, {
    DoubanInfo? info,
  }) {
    final history = app.historyFor(item.sourceKey, item.id);
    final canResume = history != null && history.positionMs > 0;
    return ImmersiveHeroItem(
      title: item.name,
      year: _validYear(item.year) ? item.year : '',
      subtitle: _heroSubtitle(item, site),
      description: _heroDescription(item),
      fallback: item.cleanPic,
      originalTitle: info?.originalTitle ?? '',
      // 豆瓣没命中时用资源站的 type / area 兜底，避免所有中文标题都落到同一种字体。
      genres: (info?.genres.isNotEmpty ?? false)
          ? info!.genres
          : splitMetaHints(item.type),
      countries: (info?.countries.isNotEmpty ?? false)
          ? info!.countries
          : splitMetaHints(item.area),
      actionLabel: canResume ? '继续播放' : '查看详情',
      onTap: () => openImmersiveItem(context, item, autoPlay: canResume),
    );
  }

  /// 按片名补全 Hero 的豆瓣元数据（原名 / 类型 / 国家）。
  Future<void> _loadHeroInfo(
    List<({String title, String year})> entries,
  ) async {
    final app = AppScope.of(context);
    for (final entry in entries) {
      final name = entry.title.trim();
      if (name.isEmpty) continue;
      // 资源站片名常带「第二季」「中配版」「2024」等后缀，豆瓣搜不到时
      // 换清洗后的候选再试，尽量让 Hero 拿到类型 / 国家。
      DoubanInfo? info;
      for (final candidate in ArtworkService.titleCandidates(name).take(3)) {
        try {
          info = await app.discoverService.loadInfo(
            candidate,
            year: entry.year,
          );
        } catch (_) {
          info = null;
        }
        if (info != null) break;
      }
      if (!mounted || info == null) continue;
      final meta = info;
      if (meta.originalTitle.isEmpty &&
          meta.genres.isEmpty &&
          meta.countries.isEmpty) {
        continue;
      }
      setState(() {
        _hero = [
          for (final hero in _hero)
            if (hero.title == name)
              hero.copyWith(
                originalTitle: meta.originalTitle.isNotEmpty
                    ? meta.originalTitle
                    : hero.originalTitle,
                genres: meta.genres.isNotEmpty ? meta.genres : hero.genres,
                countries: meta.countries.isNotEmpty
                    ? meta.countries
                    : hero.countries,
              )
            else
              hero,
        ];
      });
    }
  }

  String _heroSubtitle(VodItem item, SourceBean site) {
    final parts = <String>[
      if (item.type.isNotEmpty && item.type != item.remarks) item.type,
      site.displayName,
    ];
    return parts.join(' · ');
  }

  String _heroDescription(VodItem item) {
    final remarks = item.remarks.trim();
    if (remarks.isEmpty) return '';
    // 「国剧」「电影」这类短标签已经在副标题里，不重复占一行。
    if (remarks.length <= 4 && !remarks.contains(RegExp(r'\d'))) return '';
    return remarks;
  }

  bool _validYear(String raw) {
    final value = int.tryParse(raw.trim());
    return value != null && value >= 1900 && value <= 2100;
  }

  _HomeEntry _entryOf(VodItem item, SourceBean site) => _HomeEntry(
    title: item.name,
    year: item.year,
    subtitle: item.remarks.isEmpty ? site.displayName : item.remarks,
    fallback: item.cleanPic,
    headers: item.picHeaders,
    item: item,
  );

  void _open(_HomeEntry entry, {bool? autoPlay, bool fromStart = false}) {
    final item = entry.item;
    if (item != null) {
      // 网盘型加固源先在首页返回云盘目录，需要逐层展开而不是进详情。
      if (item.isFolder) {
        final app = AppScope.of(context);
        final site =
            app.siteByKey(item.sourceKey) ??
            (item.sourceKey.isEmpty ? app.activeSite : null);
        if (site == null) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImmersiveCategoryPage(
              site: site,
              sortClass: SortClass(id: item.id, name: item.name),
            ),
          ),
        );
        return;
      }
      openImmersiveItem(
        context,
        item,
        autoPlay: autoPlay ?? entry.resume,
        fromStart: fromStart,
      );
      return;
    }
    AppScope.of(context).requestSearch(entry.title);
  }

  /// 继续观看卡的上下文菜单：继续 / 从头 / 详情。
  void _showEntryMenu(_HomeEntry entry) {
    if (entry.item == null) return;
    showImmersiveActionMenu(
      context,
      title: entry.title,
      actions: [
        (
          icon: Icons.play_arrow_rounded,
          label: '继续播放',
          onTap: () => _open(entry, autoPlay: true),
        ),
        (
          icon: Icons.replay_rounded,
          label: '从头播放',
          onTap: () => _open(entry, autoPlay: true, fromStart: true),
        ),
        (
          icon: Icons.info_outline_rounded,
          label: '查看详情',
          onTap: () => _open(entry, autoPlay: false),
        ),
      ],
    );
  }

  void _openCategory(SortClass cls) {
    final site = _site ?? AppScope.of(context).activeSite;
    if (site == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImmersiveCategoryPage(site: site, sortClass: cls),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    // Hero 直接铺满整屏：大屏模式下第一眼就是完整横图，向下滚动才是分类与货架。
    // 窄屏（手机）按响应式指标收窄，避免按钮被挤出屏幕。
    final m = ImmersiveMetrics.of(context);
    final heroHeight = m.heroHeight;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: ImmersiveEmpty(
          title: '首页加载失败',
          message: _error!,
          action: FilledButton.tonal(onPressed: _load, child: const Text('重试')),
        ),
      );
    }
    if (_hero.isEmpty) {
      return Center(
        child: ImmersiveEmpty(
          title: '当前源没有内容',
          message: app.activeSite == null ? '先在设置里导入订阅' : '在右上角切换其它源，或到搜索页检索',
        ),
      );
    }

    // 焦点容器把方向键交给 Flutter 的焦点树遍历（按几何顺序在货架间移动），
    // 并开启自动滚动：焦点走到视口外的卡片时，外层 Scrollable 会跟随滚动。
    // 这比自己算网格更稳（货架是横向滚动 + 多个分架的混合布局）。
    return Focus(
      focusNode: _rootFocus,
      // 只作为货架卡片的焦点容器，本身不参与遍历，避免方向键停在空白节点。
      canRequestFocus: false,
      skipTraversal: true,
      child: ScrollConfiguration(
        behavior: const MouseDragScrollBehavior(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ImmersiveHero(items: _hero, height: heroHeight),
              Padding(
                padding: EdgeInsets.fromLTRB(m.gutter, 4, m.gutter, 0),
                child: Row(
                  children: [
                    Text(
                      '当前源',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.44),
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(width: 10),
                    PopupMenuButton<String>(
                      tooltip: '切换源',
                      initialValue: app.activeSiteKey,
                      onSelected: (key) => app.setActiveSite(key),
                      itemBuilder: (_) => [
                        for (final site in app.usableSites)
                          PopupMenuItem(
                            value: site.key,
                            child: Row(
                              children: [
                                Expanded(child: Text(site.displayName)),
                                if (site.key == app.activeSiteKey)
                                  Icon(
                                    Icons.check_rounded,
                                    size: 16,
                                    color: theme.colorScheme.primary,
                                  ),
                              ],
                            ),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: m.compact ? 140 : 320,
                              ),
                              child: Text(
                                app.activeSite?.displayName ?? '选择源',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.expand_more_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.56),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (!m.compact && _total > 0)
                      Text(
                        '共 $_total 部',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.42),
                        ),
                      ),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: _load,
                      icon: Icon(
                        Icons.refresh_rounded,
                        color: Colors.white.withValues(alpha: 0.52),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (_classes.isNotEmpty) ...[
                Padding(
                  padding: EdgeInsets.fromLTRB(m.gutter, 0, m.gutter, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '分类浏览',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '点击进入分类选片',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.42),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: ScrollConfiguration(
                    behavior: const MouseDragScrollBehavior(),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: m.gutter),
                      itemCount: _classes.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        final key = 'cls:$index';
                        return _CategoryChip(
                          label: _classes[index].name,
                          focusNode: _focusNodeFor(key),
                          onFocus: () => _focusMemory.remember(key),
                          onTap: () => _openCategory(_classes[index]),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 26),
              ],
              for (
                var shelfIndex = 0;
                shelfIndex < _shelves.length;
                shelfIndex++
              ) ...[
                Padding(
                  padding: EdgeInsets.fromLTRB(m.gutter, 0, m.gutter, 0),
                  child: ImmersiveShelf(
                    title: _shelves[shelfIndex].title,
                    itemCount: _shelves[shelfIndex].items.length,
                    height: m.shelfHeight,
                    itemBuilder: (context, index) {
                      final entry = _shelves[shelfIndex].items[index];
                      final key = _shelfKey(shelfIndex, index);
                      return ImmersiveCard(
                        title: entry.title,
                        year: entry.year,
                        subtitle: entry.subtitle,
                        fallback: entry.fallback,
                        imageHeaders: entry.headers,
                        badge: entry.badge,
                        progress: entry.progress,
                        showText: false,
                        width: m.shelfCardWidth,
                        focusNode: _focusNodeFor(key),
                        onFocus: () => _focusMemory.remember(key),
                        onTap: () {
                          // 记住位置：从详情页返回时恢复到这里。
                          _focusMemory.remember(key);
                          _open(entry);
                        },
                        onLongPress: entry.resume
                            ? () => _showEntryMenu(entry)
                            : null,
                        onSecondaryTap: entry.resume
                            ? () => _showEntryMenu(entry)
                            : null,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 30),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.onTap,
    this.focusNode,
    this.onFocus,
  });

  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ImmersiveFocusable(
      focusNode: focusNode,
      onTap: onTap,
      onFocusChange: (focused) {
        if (focused) onFocus?.call();
      },
      builder: (context, active) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: active ? 0.13 : 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: active ? 0.96 : 0.78),
          ),
        ),
      ),
    );
  }
}

class _HomeEntry {
  const _HomeEntry({
    required this.title,
    this.year = '',
    this.subtitle = '',
    this.fallback = '',
    this.headers = const <String, String>{},
    this.badge = '',
    this.progress = 0,
    this.resume = false,
    this.item,
  });

  final String title;
  final String year;
  final String subtitle;
  final String fallback;
  final Map<String, String> headers;
  final String badge;
  final double progress;

  /// 继续观看 / 历史条目：点击直接续播，并带上下文菜单。
  final bool resume;
  final VodItem? item;
}
