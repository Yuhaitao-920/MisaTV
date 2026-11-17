import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/vod.dart';
import 'immersive_metrics.dart';
import 'immersive_widgets.dart';

/// 沉浸观影历史页：横图卡片墙 + 观看进度。
class ImmersiveHistoryPage extends StatelessWidget {
  const ImmersiveHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final m = ImmersiveMetrics.of(context);
    final items = app.history;

    return Padding(
      padding: EdgeInsets.fromLTRB(m.gutter, m.contentTop, m.gutter, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '观看历史',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                '${items.length} 条',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.42),
                ),
              ),
              const Spacer(),
              if (items.isNotEmpty)
                TextButton.icon(
                  onPressed: () async {
                    await app.clearHistory();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已清空观看历史')),
                      );
                    }
                  },
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('清空历史'),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: ImmersiveEmpty(
                      title: '还没有观看记录',
                      message: '从首页或搜索打开一部影片，播放进度会自动记录',
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    gridDelegate:
                        SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 336,
                          mainAxisExtent: m.cardExtent,
                          crossAxisSpacing: 18,
                          mainAxisSpacing: 22,
                        ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final vod = VodItem(
                        id: item.vodId,
                        name: item.name,
                        pic: item.pic,
                        sourceKey: item.sourceKey,
                        sourceName: item.sourceName,
                        remarks: item.remarks,
                      );
                      void open({bool autoPlay = true, bool fromStart = false}) {
                        openImmersiveItem(
                          context,
                          vod,
                          autoPlay: autoPlay,
                          fromStart: fromStart,
                        );
                      }

                      void menu() => showImmersiveActionMenu(
                        context,
                        title: item.name,
                        actions: [
                          (
                            icon: Icons.play_arrow_rounded,
                            label: '继续播放',
                            onTap: () => open(),
                          ),
                          (
                            icon: Icons.replay_rounded,
                            label: '从头播放',
                            onTap: () => open(fromStart: true),
                          ),
                          (
                            icon: Icons.info_outline_rounded,
                            label: '查看详情',
                            onTap: () => open(autoPlay: false),
                          ),
                        ],
                      );

                      return ImmersiveCard(
                        title: item.name,
                        subtitle: item.episodeName.isEmpty
                            ? item.sourceName
                            : '${item.episodeName} · ${item.sourceName}',
                        fallback: item.pic,
                        badge: item.episodeName,
                        progress: item.progress,
                        showText: false,
                        width: double.infinity,
                        onTap: () => open(),
                        onLongPress: menu,
                        onSecondaryTap: menu,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
