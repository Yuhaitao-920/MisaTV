import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/live.dart';
import '../../models/site_config.dart';
import '../../services/live/epg.dart';
import '../open_player.dart';
import '../widgets/live_catchup_sheet.dart';
import '../widgets/mouse_drag_scroll.dart';
import 'immersive_widgets.dart';

/// 沉浸观影直播页：分组频道墙，直接进现有直播播放器。
class ImmersiveLivePage extends StatefulWidget {
  const ImmersiveLivePage({super.key});

  @override
  State<ImmersiveLivePage> createState() => _ImmersiveLivePageState();
}

class _ImmersiveLivePageState extends State<ImmersiveLivePage> {
  String _loadedKey = '__init__';
  bool _loading = false;
  String? _error;
  List<LiveGroup> _groups = const [];
  Map<String, EpgEntry> _epg = const {};
  Map<String, List<EpgProgram>> _programs = const {};
  int _groupIndex = 0;
  bool _favoritesOnly = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final life = app.activeLive;
    final key = app.lives.isEmpty
        ? ''
        : '${app.activeLiveIndex}|${life?.name}|${life?.url}';
    if (key == _loadedKey) return;
    _loadedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    final bean = app.activeLive;
    if (bean == null) {
      setState(() {
        _groups = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _groups = const [];
      _epg = const {};
      _programs = const {};
      _groupIndex = 0;
    });
    try {
      final groups = await app.liveService.load(
        bean,
        sites: app.config?.sites ?? const [],
        headerRules: app.liveHeaderRules,
      );
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
      });
      if (groups.isNotEmpty) {
        unawaited(_loadEpg(bean, groups));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadEpg(LiveBean bean, List<LiveGroup> groups) async {
    try {
      final programs = await AppScope.of(context).epgService.loadProgramsFor(
        bean: bean,
        channels: groups.expand((g) => g.channels).toList(),
      );
      if (!mounted) return;
      setState(() {
        _programs = programs;
        _epg = programs.isEmpty
            ? const {}
            : buildEpgEntries(programs, DateTime.now().millisecondsSinceEpoch);
      });
    } catch (_) {
      // EPG 是增强项
    }
  }

  Future<void> _play(LiveBean bean, LiveChannel channel, LiveLine line) async {
    final app = AppScope.of(context);
    await openLivePlayer(
      context,
      app,
      bean: bean,
      channel: channel,
      initialLine: line,
      epg: entryOf(_epg, epgRefOf(channel)),
      groups: _groups,
      epgEntries: _epg,
      initialGroup: _groups.isEmpty
          ? ''
          : _groups[_groupIndex.clamp(0, _groups.length - 1)].group,
    );
  }

  Widget _channelTile(
    LiveBean bean,
    LiveChannel channel, {
    bool wide = false,
    String groupLabel = '',
    String subtitleGroup = '',
    int number = 0,
  }) {
    final app = AppScope.of(context);
    final favoriteKey = app.liveChannelKey(bean, groupLabel, channel);
    return _LiveChannelTile(
      channel: channel,
      wide: wide,
      number: number,
      subtitleGroup: subtitleGroup,
      favorite: app.isLiveFavorite(favoriteKey),
      onFavorite: () => app.toggleLiveFavorite(favoriteKey),
      epg: entryOf(_epg, epgRefOf(channel)),
      onSchedule: () {
        final programs =
            lookupEpg(_programs, epgRefOf(channel)) ?? const <EpgProgram>[];
        if (programs.isEmpty) return;
        showLiveCatchupSheet(context, channel: channel, programs: programs);
      },
      onTap: () {
        final lines = channelLines(channel);
        if (lines.isEmpty) return;
        _play(bean, channel, lines.first);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final lives = app.lives;
    final bean = app.activeLive;
    final group = _groups.isEmpty
        ? null
        : _groups[_groupIndex.clamp(0, _groups.length - 1)];
    final favoriteEntries = <({String group, LiveChannel channel})>[
      if (bean != null)
        for (final g in _groups)
          for (final channel in g.channels)
            if (app.isLiveFavorite(app.liveChannelKey(bean, g.group, channel)))
              (group: g.group, channel: channel),
    ];
    final entries = _favoritesOnly
        ? favoriteEntries
        : <({String group, LiveChannel channel})>[
            for (final channel in group?.channels ?? const <LiveChannel>[])
              (group: group?.group ?? '', channel: channel),
          ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 92, 56, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '电视直播',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(width: 14),
              if (_favoritesOnly || group != null)
                Text(
                  _favoritesOnly
                      ? '${entries.length} 个收藏'
                      : '${group!.channels.length} 个频道',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.42),
                  ),
                ),
              const Spacer(),
              if (lives.isNotEmpty)
                PopupMenuButton<int>(
                  tooltip: '切换直播源',
                  initialValue: app.activeLiveIndex,
                  onSelected: (index) => app.setActiveLive(lives[index]),
                  itemBuilder: (_) => [
                    for (var i = 0; i < lives.length; i++)
                      PopupMenuItem(value: i, child: Text(lives[i].name)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          bean?.name ?? '无直播源',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
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
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(30),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: ImmersiveEmpty(
                title: '直播源加载失败',
                message: _error!,
                action: FilledButton.tonal(
                  onPressed: _load,
                  child: const Text('重试'),
                ),
              ),
            )
          else if (_groups.isEmpty)
            const Expanded(
              child: Center(
                child: ImmersiveEmpty(
                  title: '没有直播线路',
                  message: '先在设置里导入直播订阅，或切换到其它直播源',
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 42,
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text(
                      favoriteEntries.isEmpty
                          ? '我的收藏'
                          : '我的收藏 ${favoriteEntries.length}',
                    ),
                    selected: _favoritesOnly,
                    onSelected: (value) =>
                        setState(() => _favoritesOnly = value),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // 分组多时会超出宽度：桌面端默认不让鼠标拖动横向列表，
                    // 必须显式换成可拖拽的 ScrollBehavior，否则后面的分组永远够不着。
                    child: ScrollConfiguration(
                      behavior: const MouseDragScrollBehavior(),
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _groups.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final selected =
                              !_favoritesOnly && index == _groupIndex;
                          return ChoiceChip(
                            label: Text(_groups[index].group),
                            selected: selected,
                            onSelected: (_) => setState(() {
                              _favoritesOnly = false;
                              _groupIndex = index;
                            }),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: ImmersiveEmpty(
                        title: _favoritesOnly ? '还没有收藏频道' : '这个分组没有频道',
                        message: _favoritesOnly
                            ? '在频道卡片上点星标收藏常看的台，之后会出现在这里'
                            : '换一个分组或直播源试试',
                      ),
                    )
                  : ScrollConfiguration(
                      behavior: const MouseDragScrollBehavior(),
                      // 频道可能上千条：始终用懒构建，不再一次性 Wrap 出全部卡片。
                      child: app.liveLayoutMode == 1
                          ? ListView.builder(
                              padding: const EdgeInsets.only(bottom: 20),
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _channelTile(
                                    bean!,
                                    entry.channel,
                                    wide: true,
                                    groupLabel: entry.group,
                                    subtitleGroup: _favoritesOnly
                                        ? entry.group
                                        : '',
                                    number: _favoritesOnly ? 0 : index + 1,
                                  ),
                                );
                              },
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.only(bottom: 20),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 300,
                                    mainAxisExtent: 112,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12,
                                  ),
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return _channelTile(
                                  bean!,
                                  entry.channel,
                                  groupLabel: entry.group,
                                  subtitleGroup: _favoritesOnly
                                      ? entry.group
                                      : '',
                                  number: _favoritesOnly ? 0 : index + 1,
                                );
                              },
                            ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LiveChannelTile extends StatelessWidget {
  const _LiveChannelTile({
    required this.channel,
    required this.epg,
    required this.onTap,
    this.onSchedule,
    this.onFavorite,
    this.favorite = false,
    this.number = 0,
    this.subtitleGroup = '',
    this.wide = false,
  });

  final LiveChannel channel;
  final EpgEntry? epg;
  final VoidCallback onTap;
  final VoidCallback? onSchedule;
  final VoidCallback? onFavorite;
  final bool favorite;

  /// 频道号（按当前分组顺序，从 1 开始）；0 = 不显示。
  final int number;

  /// 「我的收藏」视图里补充显示频道所属分组。
  final String subtitleGroup;

  /// 平铺模式：整行宽度、标题两行；网格模式固定高度、标题一行。
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = epg?.current;
    return ImmersiveFocusable(
      onTap: onTap,
      onLongPress: onSchedule,
      builder: (context, active) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: wide ? null : 112,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.white.withValues(alpha: active ? 0.10 : 0.045),
          border: Border.all(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Column(
          mainAxisSize: wide ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (number > 0) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '$number',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary.withValues(alpha: 0.9),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    channel.name,
                    maxLines: wide ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: active
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.86),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              current == null
                  ? (subtitleGroup.isEmpty ? '点击播放' : subtitleGroup)
                  : '${subtitleGroup.isEmpty ? '' : '$subtitleGroup · '}'
                        '${current.range} ${current.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.52),
                height: 1.4,
              ),
            ),
            if (wide) const SizedBox(height: 8) else const Spacer(),
            Row(
              children: [
                Icon(
                  Icons.play_circle_outline_rounded,
                  size: 15,
                  color: theme.colorScheme.primary.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 5),
                Text(
                  '${channelLines(channel).length} 条线路',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.38),
                  ),
                ),
                const Spacer(),
                if (onFavorite != null)
                  IconButton(
                    tooltip: favorite ? '取消收藏' : '收藏频道',
                    onPressed: onFavorite,
                    icon: Icon(
                      favorite ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 16,
                    ),
                    color: favorite
                        ? theme.colorScheme.primary
                        : Colors.white.withValues(alpha: 0.42),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 22,
                    ),
                  ),
                if (onSchedule != null)
                  IconButton(
                    tooltip: '节目单 / 回看',
                    onPressed: onSchedule,
                    icon: const Icon(Icons.schedule_rounded, size: 15),
                    color: theme.colorScheme.primary.withValues(alpha: 0.75),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 22,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
