part of '../player_page.dart';

/// 以下逻辑由 [player_page.dart] 的 part 拆分而来，仍可访问 State 私有成员。
extension _PlayerDanmakuExt on _PlayerPageState {
  Future<void> _toggleDanmaku() async {
    if (_danmakuEnabled) {
      _danmakuSeq++;
      _setState(() => _danmakuEnabled = false);
      await _app.setDanmakuSettings(
        _app.danmakuSettings.copyWith(enabled: false),
      );
      return;
    }
    _setState(() => _danmakuEnabled = true);
    final settings = _app.danmakuSettings.copyWith(enabled: true);
    await _app.setDanmakuSettings(settings);
    if (_allDanmaku.isEmpty) await _loadDanmaku();
  }

  /// 按弹幕屏蔽词过滤（关键词包含或 `/正则/`）。
  List<DanmakuLine> _filterDanmaku(List<DanmakuLine> items) {
    final words = _app.danmakuSettings.blockWords;
    if (words.isEmpty) return items;
    return [
      for (final item in items)
        if (!isDanmakuBlocked(item.text, words)) item,
    ];
  }

  String _danmakuSummary() {
    final settings = _app.danmakuSettings;
    if (!settings.enabled) return '弹幕已关闭';
    return [
      '${(settings.regionRatio * 100).round()}% 屏',
      '${settings.speed.round()}px/s',
      if (settings.density < 0.995) '密度 ${(settings.density * 100).round()}%',
      '字号 ${settings.fontSize.toStringAsFixed(0)}',
      if (settings.blockWords.isNotEmpty) '屏蔽 ${settings.blockWords.length} 词',
    ].join(' · ');
  }

  /// 播放器内的弹幕独立调节面板：速度、密度、屏占、字号、透明度、偏移、屏蔽词。
  Future<void> _showDanmakuPanel() async {
    var settings = _app.danmakuSettings;
    final wordsCtrl = TextEditingController(
      text: settings.blockWords.join('\n'),
    );
    final result = await showModalBottomSheet<DanmakuSettings>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final theme = Theme.of(ctx);
            Widget slider(
              String label,
              String display,
              double value,
              double min,
              double max,
              int divisions,
              ValueChanged<double> onChanged,
            ) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(label, style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Text(display, style: theme.textTheme.labelSmall),
                    ],
                  ),
                  Slider(
                    value: value.clamp(min, max).toDouble(),
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: (v) => setSheet(() => onChanged(v)),
                  ),
                ],
              );
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(ctx).bottom,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('弹幕设置', style: theme.textTheme.titleLarge),
                          const Spacer(),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 4),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(
                              settings.copyWith(
                                blockWords: normalizeDanmakuBlockWords(
                                  wordsCtrl.text,
                                ),
                              ),
                            ),
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: settings.enabled,
                        onChanged: (v) => setSheet(
                          () => settings = settings.copyWith(enabled: v),
                        ),
                        title: const Text('显示弹幕'),
                        subtitle: Text(
                          '当前可用 ${_danmaku.length} 条'
                          '${settings.blockWords.isEmpty ? '' : ' · 已屏蔽 ${_allDanmaku.length - _danmaku.length} 条'}',
                        ),
                      ),
                      slider(
                        '显示区域',
                        '${(settings.regionRatio * 100).round()}% 屏',
                        settings.regionRatio,
                        danmakuRegionMinRatio,
                        danmakuRegionMaxRatio,
                        18,
                        (v) => settings = settings.copyWith(regionRatio: v),
                      ),
                      const SizedBox(height: 8),
                      slider(
                        '滚动速度',
                        '${settings.speed.round()}px/s',
                        settings.speed,
                        40,
                        300,
                        26,
                        (v) => settings = settings.copyWith(speed: v),
                      ),
                      slider(
                        '弹幕密度',
                        '${(settings.density * 100).round()}%',
                        settings.density,
                        0.1,
                        1,
                        9,
                        (v) => settings = settings.copyWith(density: v),
                      ),
                      slider(
                        '字号',
                        '${settings.fontSize.toStringAsFixed(0)}px',
                        settings.fontSize,
                        12,
                        40,
                        28,
                        (v) => settings = settings.copyWith(fontSize: v),
                      ),
                      slider(
                        '透明度',
                        '${(settings.opacity * 100).round()}%',
                        settings.opacity,
                        0.2,
                        1,
                        8,
                        (v) => settings = settings.copyWith(opacity: v),
                      ),
                      slider(
                        '时间偏移',
                        '${settings.offset.toStringAsFixed(1)}s',
                        settings.offset,
                        -10,
                        10,
                        40,
                        (v) => settings = settings.copyWith(offset: v),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: wordsCtrl,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '弹幕屏蔽词',
                          hintText: '每行一个关键词；/正则/ 写法也可',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '关键词不区分大小写；屏蔽只影响当前弹幕层，不会改动拉取到的原始数据。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.55,
                          ),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    wordsCtrl.dispose();
    if (result == null) return;
    await _app.setDanmakuSettings(result);
    if (!mounted) return;
    _setState(() {
      _danmakuEnabled = result.enabled;
      _danmaku = _filterDanmaku(_allDanmaku);
    });
    if (result.enabled && _allDanmaku.isEmpty) await _loadDanmaku();
  }

  Future<void> _loadDanmaku() async {
    final seq = ++_danmakuSeq;
    final detail = _detail;
    final keyword = detail.name.trim();
    if (keyword.isEmpty) return;
    final episodeName = _episodeName.trim();
    final parsedEp = parseEpisodeInput(episodeName);
    final targetEp = parsedEp.ep?.trim().isNotEmpty == true
        ? parsedEp.ep!.trim()
        : '${_index + 1}';
    final season =
        parsedEp.season ?? seasonOf(detail.name) ?? seasonOf(episodeName);
    final settings = _app.danmakuSettings;
    final enabled = settings.endpoints
        .where((e) => e.enabled && e.url.trim().isNotEmpty)
        .toList();
    final broad = <DanmakuEndpoint>[...enabled];
    const broadLimit = 12;
    if (broad.length < broadLimit) {
      for (final e in settings.endpoints) {
        if (broad.length >= broadLimit) break;
        if (!e.enabled && e.url.trim().isNotEmpty) {
          broad.add(e.copyWith(enabled: true));
        }
      }
    }

    try {
      var broadTried = false;
      var candidates = await _app.danmakuService.search(
        keyword,
        season: season,
      );
      if (!mounted || seq != _danmakuSeq) return;
      if (candidates.isEmpty && broad.length > enabled.length) {
        broadTried = true;
        _toast('主弹幕源未命中，正在扩大搜索…');
        candidates = await _app.danmakuService.search(
          keyword,
          endpoints: broad,
          season: season,
        );
        if (!mounted || seq != _danmakuSeq) return;
      }
      if (candidates.isEmpty) {
        _toast('没有找到「$keyword」的弹幕；可在设置 → 弹幕接口启用更多源');
        return;
      }

      Future<({DanmakuCandidate candidate, List<DanmakuItem> items})?>
      fetchFirst() async {
        final ranked = DanmakuService.rankCandidates(
          candidates,
          keyword,
          season: season,
          ep: targetEp,
        );
        final exact = ranked
            .where((c) => candidateMatchesEp(c, targetEp))
            .toList();
        final noEp = ranked.where((c) => epNumberOf(c) == null).toList();
        final rest = ranked
            .where(
              (c) => !candidateMatchesEp(c, targetEp) && epNumberOf(c) != null,
            )
            .toList();
        final picks = <DanmakuCandidate>{
          ...exact,
          ...noEp,
          ...rest,
        }.take(3).toList();
        Future<({DanmakuCandidate candidate, List<DanmakuItem> items})>
        fetchOne(DanmakuCandidate candidate) async {
          try {
            final items = await _app.danmakuService.fetch(
              candidate,
              timeout: const Duration(seconds: 20),
            );
            return (candidate: candidate, items: items);
          } catch (_) {
            return (candidate: candidate, items: const <DanmakuItem>[]);
          }
        }

        if (picks.isEmpty) return null;
        // 最佳候选先单独拉：命中就立刻上屏；空了再并发试其余候选。
        final first = await fetchOne(picks.first);
        if (first.items.isNotEmpty) return first;
        if (picks.length > 1) {
          final restResults = await Future.wait(picks.skip(1).map(fetchOne));
          for (final result in restResults) {
            if (result.items.isNotEmpty) return result;
          }
        }
        return null;
      }

      var hit = await fetchFirst();
      if ((hit == null) && !broadTried && broad.length > enabled.length) {
        broadTried = true;
        _toast('已找到条目但没有可用弹幕，正在换源重试…');
        candidates = await _app.danmakuService.search(
          keyword,
          endpoints: broad,
          season: season,
        );
        if (!mounted || seq != _danmakuSeq) return;
        if (candidates.isNotEmpty) hit = await fetchFirst();
      }
      if (!mounted || seq != _danmakuSeq) return;
      if (hit == null) {
        _toast('已找到条目，但第 $targetEp 集没有可用弹幕；可在设置 → 弹幕接口启用更多源');
        return;
      }

      final items = hit.items;
      final all = [
        for (final item in items)
          DanmakuLine(
            time: item.time,
            type: item.type,
            text: item.text,
            size: item.size,
            color: item.color,
          ),
      ];
      _setState(() {
        _allDanmaku = all;
        _danmaku = _filterDanmaku(all);
        _danmakuEnabled = true;
      });
      _toast('弹幕已加载 ${items.length} 条（${hit.candidate.sourceName}）');
    } catch (e) {
      if (mounted) _toast('弹幕加载失败：$e');
    }
  }

  /// 本集字幕记忆键：`资源|集`（和 skipSegments 用的是同一套键）。
  String get _subtitleResource => '${_detail.sourceKey}|${_detail.id}';
  String get _subtitleEpisode => '${_index + 1}';

  Future<void> _showSubtitlePanel() async {
    final detail = _detail;
    // ★ 有记忆就先自动挂上，用户仍可打开面板换一条。
    //
    //   同一部片子第二次播放时，用户 99% 想继续用上次那条字幕。
    //   旧行为是每次都要重新搜、重新下、重新选。
    final remembered = await _autoApplyRememberedSubtitle();
    if (!mounted) return;
    if (remembered) {
      _toast('已自动载入上次的字幕：$_subtitleStatus');
      return;
    }

    final pick = await showSubtitlePanel(
      context,
      service: _app.subtitleService,
      query: SubtitleQuery(
        title: detail.name,
        year: int.tryParse(detail.year),
        episode: _index + 1,
        rawName: _episodeName,
      ),
      currentName: _subtitleStatus,
      onClear: _clearSubtitle,
    );
    if (pick == null) return;
    await _applySubtitle(pick.file);
    // 记住这次选了哪一条（下次自动载入）。
    await _app.saveSubtitleChoice(
      resource: _subtitleResource,
      episode: _subtitleEpisode,
      providerId: pick.candidate.providerId,
      id: pick.candidate.id,
      name: pick.file.name,
    );
  }

  /// 尝试自动载入上次的字幕；成功返回 true。
  ///
  /// 只看本地缓存（`subtitles/cache/`），不联网 —— 缓存没了就当没记忆。
  Future<bool> _autoApplyRememberedSubtitle() async {
    if (_subtitleStatus.isNotEmpty) return false; // 已经有字幕了
    final mem = _app.subtitleChoiceFor(_subtitleResource, _subtitleEpisode);
    if (mem == null) return false;
    final providerId = mem['p'] ?? '';
    final id = mem['i'] ?? '';
    final wantName = mem['n'] ?? '';
    if (providerId.isEmpty || id.isEmpty) return false;

    final candidate = SubtitleCandidate(
      providerId: providerId,
      providerName: '',
      id: id,
      title: wantName,
      language: '',
      format: '',
      downloadUrl: '',
    );
    final cached = _app.subtitleService.cachedChoices(candidate);
    if (cached == null || cached.isEmpty) {
      AppLog.i('subtitle', '字幕记忆命中但缓存已失效（$providerId|$id），退回手动选择');
      return false;
    }
    // 优先同名条目（用户上次选的那条），否则取第一条。
    final chosen = cached.firstWhere(
      (c) => c.name == wantName,
      orElse: () => cached.first,
    );
    await _applySubtitle(chosen.toFile());
    AppLog.i('subtitle', '自动载入上次字幕：${chosen.name}');
    return _subtitleStatus.isNotEmpty;
  }

  /// 起播后自动恢复上次的字幕（由 player_page 在 initialize 成功后调用）。
  Future<void> _autoRestoreSubtitle() async {
    if (_subtitleStatus.isNotEmpty) return;
    if (!mounted) return;
    final ok = await _autoApplyRememberedSubtitle();
    if (ok && mounted) _toast('已自动载入上次的字幕：$_subtitleStatus');
  }

  Future<void> _applySubtitle(SubtitleFile file) async {
    final controller = _controller;
    if (controller == null) {
      _toast('播放器还没准备好，稍后再试');
      return;
    }
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'subtitles'))
        ..createSync(recursive: true);
      final ext = switch (file.format.toLowerCase()) {
        'ass' || 'ssa' => 'ass',
        'vtt' => 'vtt',
        _ => 'srt',
      };
      final target = File(
        p.join(
          dir.path,
          'current-${DateTime.now().millisecondsSinceEpoch}.$ext',
        ),
      );
      await target.writeAsString(file.text);
      controller.setExternalSubtitle(target.path);
      final active = controller.getActiveSubtitleTracks();
      if (active == null || active.isEmpty) {
        controller.setSubtitleTracks(const [0]);
        final retry = controller.getActiveSubtitleTracks();
        if (retry == null || retry.isEmpty) {
          controller.setSubtitleTracks(const [1]);
        }
      }
      if (!mounted) return;
      _setState(() => _subtitleStatus = file.name.isEmpty ? '外挂字幕' : file.name);
      // 疑似 AI 摘要字幕：时间轴能走，但内容只是换场梗概，用户会以为「对不上集数」。
      // 直接说清楚，省得反复重选。
      final health = file.health;
      if (health.isLikelySummary) {
        _toast(
          '字幕已载入，但这是摘要字幕（${health.averageGapSeconds.round()}s/条，'
          '共 ${health.entries} 条），不是逐句对白，画面与文字可能不同步',
        );
      } else {
        _toast('字幕已载入：$_subtitleStatus');
      }
    } catch (e) {
      _toast('字幕挂载失败（当前内核可能不支持外挂字幕）：$e');
    }
  }

  void _clearSubtitle() {
    try {
      _controller?.setExternalSubtitle('');
      _controller?.setSubtitleTracks(const []);
    } catch (_) {
      // 非 fvp 内核忽略
    }
    if (mounted) _setState(() => _subtitleStatus = '');
  }
}
