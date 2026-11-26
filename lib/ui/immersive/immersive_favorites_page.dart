import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/vod.dart';
import 'immersive_metrics.dart';
import 'immersive_widgets.dart';

/// 沉浸观影收藏页。
class ImmersiveFavoritesPage extends StatelessWidget {
  const ImmersiveFavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final m = ImmersiveMetrics.of(context);
    final items = app.favorites;

    return Padding(
      padding: EdgeInsets.fromLTRB(m.gutter, m.contentTop, m.gutter, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '我的收藏',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                '${items.length} 部',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.42),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: ImmersiveEmpty(
                      title: '还没有收藏',
                      message: '详情页右上角的星标可以收藏喜欢的影片',
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: m.posterMaxExtent,
                      mainAxisExtent: m.cardExtent,
                      crossAxisSpacing: 18,
                      mainAxisSpacing: 22,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return Stack(
                        children: [
                          ImmersiveCard(
                            title: item.name,
                            year: item.year,
                            subtitle: item.remarks.isEmpty
                                ? item.sourceName
                                : item.remarks,
                            fallback: item.pic,
                            badge: item.hasUpdate ? '有更新' : '',
                            showText: false,
                            width: double.infinity,
                            onTap: () {
                              openImmersiveItem(
                                context,
                                VodItem(
                                  id: item.vodId,
                                  name: item.name,
                                  pic: item.pic,
                                  sourceKey: item.sourceKey,
                                  sourceName: item.sourceName,
                                  remarks: item.remarks,
                                ),
                              );
                            },
                          ),
                          Positioned(
                            right: 4,
                            top: 4,
                            child: _RemoveFavoriteButton(
                              onPressed: () => app.removeFavorite(item.key),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _RemoveFavoriteButton extends StatefulWidget {
  const _RemoveFavoriteButton({required this.onPressed});

  final Future<void> Function() onPressed;

  @override
  State<_RemoveFavoriteButton> createState() => _RemoveFavoriteButtonState();
}

class _RemoveFavoriteButtonState extends State<_RemoveFavoriteButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: IconButton(
        tooltip: '取消收藏',
        onPressed: () => widget.onPressed(),
        icon: Icon(
          Icons.star_rounded,
          size: 20,
          color: _hover ? Colors.white : Colors.white.withValues(alpha: 0.50),
        ),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: _hover ? 0.62 : 0.30),
          minimumSize: const Size(32, 32),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
