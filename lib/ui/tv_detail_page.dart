import 'package:flutter/material.dart';

import '../app.dart';
import '../models/vod.dart';
import 'open_player.dart';
import 'pages/player_page.dart';

/// TV 版专用的精简详情页。
///
/// 常规版的 `DetailPage` 有两千多行（剧照墙、演职员、豆瓣影评、相关推荐、
/// 沉浸过渡动画…），在电视上既用不上、又把 `lib/ui/pages/` 整个目录拖进
/// 编译单元。TV 版换成这个：**海报 + 简介 + 选集 + 播放**，遥控器可操作。
///
/// 与常规版的关键差异：
///   · 不做「豆瓣元数据补全」的二次请求，只展示源站返回的简介；
///   · 不显示剧照 / 演职员 / 影评（需要额外网络请求，电视上价值低）；
///   · 选集用横向网格，焦点可用方向键移动（常规版是鼠标优先）。
class TvDetailPage extends StatefulWidget {
  const TvDetailPage({
    super.key,
    required this.item,
    this.autoPlay = false,
    this.fromStart = false,
  });

  final VodItem item;

  /// 从「继续观看 / 历史」进入：详情加载完成后直接起播。
  final bool autoPlay;

  /// 配合 [autoPlay]：忽略历史进度，从第一集 / 开头播放。
  final bool fromStart;

  @override
  State<TvDetailPage> createState() => _TvDetailPageState();
}

class _TvDetailPageState extends State<TvDetailPage> {
  VodDetail? _detail;
  String _flag = '';
  String? _error;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    final site = app.siteByKey(widget.item.sourceKey);
    if (site == null) {
      setState(() => _error = '找不到该条目所属的站点');
      return;
    }
    try {
      final detail = await app.sourceService.detail(site, widget.item.id);
      if (!mounted) return;
      if (detail == null) {
        setState(() => _error = '拿不到详情（源站可能已失效）');
        return;
      }
      final flags = detail.flags;
      setState(() {
        _detail = detail;
        _flag = flags.isNotEmpty ? flags.first : '';
      });
      if (widget.autoPlay) await _play(0);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<Episode> get _episodes =>
      _detail?.episodeList(_flag) ?? const <Episode>[];

  Future<void> _play(int index) async {
    final app = AppScope.of(context);
    final detail = _detail;
    if (detail == null || _playing) return;
    final site = app.siteByKey(widget.item.sourceKey);
    if (site == null) return;
    setState(() => _playing = true);
    try {
      final config = app.config;
      if (config == null) {
        _toast('还没有导入订阅');
        return;
      }
      final episodes = _episodes;
      final play = await app.sourceService.resolvePlay(
        site: site,
        config: config,
        flag: _flag,
        rawUrl: episodes[index].url,
        jarReady: app.jarReady,
      );
      if (!mounted) return;
      final startMs = widget.fromStart
          ? 0
          : (app.historyFor(detail.sourceKey, detail.id)?.positionMs ?? 0);
      await openVodPlayer(
        context,
        app,
        PlayerSession(
          detail: detail,
          site: site,
          flag: _flag,
          episodeIndex: index,
          episodes: _episodes,
          initialPlay: play,
          startPositionMs: startMs,
        ),
        rootNavigator: true,
      );
    } catch (e) {
      if (mounted) _toast('播放失败：$e');
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: _error != null
            ? _buildError(theme)
            : detail == null
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(theme, detail),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(_error!, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme, VodDetail detail) {
    final episodes = _episodes;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(36, 24, 36, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.pic.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    detail.pic,
                    width: 170,
                    height: 240,
                    fit: BoxFit.cover,
                    cacheWidth: 340,
                    errorBuilder: (_, _, _) =>
                        const SizedBox(width: 170, height: 240),
                  ),
                ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.name,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (detail.year.isNotEmpty) _chip(theme, detail.year),
                        if (detail.area.isNotEmpty) _chip(theme, detail.area),
                        if (detail.type.isNotEmpty) _chip(theme, detail.type),
                        if (detail.remarks.isNotEmpty)
                          _chip(theme, detail.remarks),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (detail.des.isNotEmpty)
                      Text(
                        detail.des,
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // 线路切换：多线路时用 ChoiceChip，遥控器左右可切换。
          if (detail.flags.length > 1) ...[
            Text('线路', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final flag in detail.flags)
                  ChoiceChip(
                    label: Text(flag),
                    selected: flag == _flag,
                    onSelected: (_) {
                      setState(() => _flag = flag);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          Row(
            children: [
              Text('选集', style: theme.textTheme.titleSmall),
              const Spacer(),
              Text('${episodes.length} 集', style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 10),
          _buildEpisodes(theme, episodes),
        ],
      ),
    );
  }

  Widget _chip(ThemeData theme, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: theme.textTheme.labelSmall),
  );

  Widget _buildEpisodes(ThemeData theme, List<Episode> episodes) {
    if (episodes.isEmpty) {
      return Text('没有可播放的集数', style: theme.textTheme.bodySmall);
    }
    // 电视上用固定列数的网格：方向键移动可预测，CJK 集名也不会挤成一行。
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        mainAxisExtent: 52,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: episodes.length,
      itemBuilder: (_, index) {
        final episode = episodes[index];
        return _TvEpisodeTile(
          label: episode.name.trim().isEmpty
              ? '第${index + 1}集'
              : episode.name.trim(),
          onTap: () => _play(index),
        );
      },
    );
  }
}

/// 选集按钮：聚焦时高亮（遥控器方向键）。
class _TvEpisodeTile extends StatefulWidget {
  const _TvEpisodeTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_TvEpisodeTile> createState() => _TvEpisodeTileState();
}

class _TvEpisodeTileState extends State<_TvEpisodeTile> {
  bool _focused = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _focused || _hover;
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? theme.colorScheme.primary.withValues(alpha: 0.2)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.45,
                    ),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active ? theme.colorScheme.primary : Colors.transparent,
                width: active ? 1.6 : 1,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? theme.colorScheme.primary : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
