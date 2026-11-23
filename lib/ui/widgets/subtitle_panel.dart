import 'package:flutter/material.dart';

import '../../services/subtitle/subtitle_models.dart';
import '../../services/subtitle/subtitle_service.dart';

/// 面板返回的结果：字幕正文 + 「这条来自哪个候选的哪个包内文件」。
///
/// 后者用于记忆（下次同一集自动载入），所以必须带出来。
class SubtitlePick {
  const SubtitlePick({
    required this.file,
    required this.candidate,
  });

  final SubtitleFile file;

  /// 来源候选（providerId / id），用于记住「上次选的是哪一条」。
  final SubtitleCandidate candidate;
}

/// 在线字幕检索面板：返回选中的字幕文件；取消返回 null。
Future<SubtitlePick?> showSubtitlePanel(
  BuildContext context, {
  required SubtitleService service,
  required SubtitleQuery query,
  String currentName = '',
  VoidCallback? onClear,
}) {
  return showModalBottomSheet<SubtitlePick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SubtitleSheet(
      service: service,
      query: query,
      currentName: currentName,
      onClear: onClear,
    ),
  );
}

class _SubtitleSheet extends StatefulWidget {
  const _SubtitleSheet({
    required this.service,
    required this.query,
    required this.currentName,
    this.onClear,
  });
  final SubtitleService service;
  final SubtitleQuery query;
  final String currentName;
  final VoidCallback? onClear;

  @override
  State<_SubtitleSheet> createState() => _SubtitleSheetState();
}

class _SubtitleSheetState extends State<_SubtitleSheet> {
  bool _loading = true;
  String _error = '';
  String _busyId = '';
  List<SubtitleCandidate> _items = const [];

  /// 用户可编辑的检索词。默认是自动推断的剧名（去掉了站点标签），
  /// 用户可以改成真正能搜到的名字（比如「奥德赛2026」→「奥德赛」）。
  late final TextEditingController _kw = TextEditingController(
    text: widget.query.effectiveTitle,
  );

  /// 当前生效的查询（带用户改过的词）。
  SubtitleQuery get _query => widget.query.withCustomKeyword(_kw.text.trim());

  @override
  void initState() {
    super.initState();
    // ★ 先看检索缓存：命中就立即出列表，不发任何请求。
    //
    //   用户重开面板往往只是想「换一条已下载的字幕」。旧行为是每次打开
    //   都重新检索（assrt ~1s + subtitlecat 15s 超时），白等十几秒。
    //   只有点右上角刷新才真正重新检索。
    final cached = widget.service.cachedSearch(_query);
    if (cached != null) {
      _items = cached;
      _loading = false;
      return;
    }
    _search();
  }

  @override
  void dispose() {
    _kw.dispose();
    super.dispose();
  }

  Future<void> _search({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final items = await widget.service.search(_query, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 压缩包内多条字幕时，让用户在弹窗里挑一条。
  Future<SubtitleFile?> _chooseFromPackage(
    List<SubtitleChoice> choices,
  ) async {
    final theme = Theme.of(context);
    return showDialog<SubtitleFile>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这个压缩包里有多个字幕'),
        contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        content: SizedBox(
          width: 460,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: choices.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final c = choices[i];
              final h = c.health;
              // 体检信息帮用户判断：条数太少 / 间隔太大（AI 摘要）要提示。
              final flags = <String>[
                '${(c.byteLength / 1024).toStringAsFixed(0)}KB',
                if (h.entries > 0) '${h.entries}条',
                if (h.isLikelySummary) '疑似摘要',
              ].join(' · ');
              return ListTile(
                dense: true,
                title: Text(
                  c.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${c.format.toUpperCase()} · $flags',
                  style: theme.textTheme.labelSmall,
                ),
                onTap: () => Navigator.of(ctx).pop(c.toFile()),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _apply(SubtitleCandidate candidate) async {
    if (_busyId.isNotEmpty) return;

    // ★ 已经下载并解过的包：直接弹选择，不再重复下载。
    //
    //   用户点同一个候选第二次通常只是想「换包里另一条字幕试试」
    //   （简中 → 繁中 → 双语）。再下一次包、再解一次压纯属浪费，
    //   慢的时候还要等好几秒。`SubtitleService` 里按 `providerId|id`
    //   缓存了上次解出的全部条目。
    final cached = widget.service.cachedChoices(candidate);
    if (cached != null && cached.isNotEmpty) {
      // 只有一条时也弹列表 —— 用户明确要求「点已下载的字幕就直接弹出
      // 已下载的内容」，弹出来他才看得到文件名、知道挂的是哪一个。
      final picked = await _chooseFromPackage(cached);
      if (!mounted) return;
      if (picked != null) {
        Navigator.of(context).pop(
          SubtitlePick(file: picked, candidate: candidate),
        );
      }
      return;
    }

    setState(() => _busyId = candidate.id);
    try {
      final file = await widget.service.download(
        candidate,
        videoName: widget.query.rawName,
        ep: widget.query.episode?.toString() ?? '',
      );
      if (!mounted) return;
      Navigator.of(context).pop(SubtitlePick(file: file, candidate: candidate));
    } on SubtitleChoicesException catch (e) {
      // 包里有多条：弹选择列表，选完再挂。
      if (!mounted) return;
      setState(() => _busyId = '');
      final picked = await _chooseFromPackage(e.choices);
      if (!mounted) return;
      if (picked != null) {
        Navigator.of(context).pop(
          SubtitlePick(file: picked, candidate: candidate),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyId = '';
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.sizeOf(context).height;
    return Container(
      constraints: BoxConstraints(maxHeight: height * 0.78),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('在线字幕', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 3),
                        Text(
                          widget.query.title.isEmpty
                            ? '当前资源'
                            : widget.query.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '重新检索',
                    onPressed: _loading ? null : () => _search(refresh: true),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  if (widget.currentName.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        widget.onClear?.call();
                        Navigator.of(context).pop();
                      },
                      child: const Text('关闭字幕'),
                    ),
                ],
              ),
            ),
            // ★ 可编辑的检索词。
            //
            //   自动推断会带上年份/副标题，精确匹配的站点反而搜不到 ——
            //   实测「奥德赛2026」在 assrt 上 0 条，去掉年份能搜到。
            //   默认填自动推断的结果（保持原行为），用户改完点回车或刷新
            //   就按新词搜。
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: TextField(
                controller: _kw,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(refresh: true),
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_kw.text.trim() !=
                          widget.query.effectiveTitle.trim())
                        IconButton(
                          tooltip: '还原自动推断的名字',
                          icon: const Icon(Icons.undo_rounded, size: 18),
                          onPressed: () {
                            _kw.text = widget.query.effectiveTitle;
                            _search(refresh: true);
                          },
                        ),
                      IconButton(
                        tooltip: '按这个词检索',
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        onPressed: _loading
                            ? null
                            : () => _search(refresh: true),
                      ),
                    ],
                  ),
                  hintText: '检索词（可改，回车搜索）',
                  helperText: '自动推断：${widget.query.effectiveTitle}',
                  helperStyle: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              )
            else if (_items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('没有搜到字幕；assrt 未配置 token 时会自动跳过该源。'),
              )
            else
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    final busy = _busyId == item.id;
                    // 已经下载过（内存或落盘缓存命中）：不再显示下载图标，
                    // 换成「已缓存」+ 列表图标 —— 用户一眼看出点它不用再等。
                    final cached = widget.service.cachedChoices(item);
                    final isCached = cached != null && cached.isNotEmpty;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${item.providerName} · ${item.language.isEmpty ? '未知语言' : item.language}'
                        '${item.format.isEmpty ? '' : ' · ${item.format.toUpperCase()}'}'
                        // 集号：有则显示「第N集」，无则明示「整片/不分集」——
                        // 用户常把「整片字幕」误当成「字幕没匹配上集数」。
                        '${item.episodeHint.isEmpty ? ' · 整片' : ' · 第${item.episodeHint}集'}'
                        '${isCached ? ' · 已缓存 ${cached.length} 条' : ''}'
                        '${item.detail.isEmpty ? '' : ' · ${item.detail}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: isCached
                              ? theme.colorScheme.primary
                              : null,
                        ),
                      ),
                      trailing: busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(
                              isCached
                                  ? Icons.checklist_rounded
                                  : Icons.download_rounded,
                              size: 20,
                              color: isCached ? theme.colorScheme.primary : null,
                            ),
                      onTap: busy ? null : () => _apply(item),
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'SubtitleCat 免 token；assrt 需在「设置 → 播放」填写 token。字幕文件下载后会挂到当前播放器。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
