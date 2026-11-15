import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/platform/window_service.dart';
import '../../services/runtime_extension.dart';
import '../pages/settings_page.dart';
import 'immersive_favorites_page.dart';
import 'immersive_history_page.dart';
import 'immersive_home_page.dart';
import 'immersive_live_page.dart';
import 'immersive_metrics.dart';
import 'immersive_search_page.dart';
import 'immersive_widgets.dart';

/// 沉浸观影模式的外壳：顶部细导航 + 全屏页面。
class ImmersiveShell extends StatefulWidget {
  const ImmersiveShell({super.key});

  @override
  State<ImmersiveShell> createState() => _ImmersiveShellState();
}

class _ImmersiveShellState extends State<ImmersiveShell> {
  int _index = 0;
  int _handledSearchSeq = 0;
  final GlobalKey<SettingsPageState> _settingsKey =
      GlobalKey<SettingsPageState>();
  Timer? _clock;
  String _time = '';

  static const _items = <({IconData icon, String label})>[
    (icon: Icons.home_rounded, label: '首页'),
    (icon: Icons.search_rounded, label: '搜索'),
    (icon: Icons.live_tv_rounded, label: '直播'),
    (icon: Icons.history_rounded, label: '历史'),
    (icon: Icons.favorite_rounded, label: '收藏'),
    (icon: Icons.settings_rounded, label: '设置'),
  ];

  @override
  void initState() {
    super.initState();
    RuntimeInstallPrompt.instance.onReveal = _revealRuntimeInstall;
    // 沉浸观影 = 独占全屏；退出该模式时还原原来的窗口大小与位置。
    unawaited(enterImmersiveFullscreen());
    _tick();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    RuntimeInstallPrompt.instance.onReveal = null;
    RuntimeInstallPrompt.instance.hostContext = null;
    _clock?.cancel();
    unawaited(exitImmersiveFullscreen());
    super.dispose();
  }

  void _tick() {
    final now = DateTime.now();
    final text =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    if (text != _time && mounted) setState(() => _time = text);
  }

  Future<void> _revealRuntimeInstall(RuntimeExtension kind) async {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _index = 5);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _settingsKey.currentState?.revealRuntime(kind);
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    if (index == 4) unawaited(AppScope.of(context).checkFavoriteUpdates());
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final metrics = ImmersiveMetrics.of(context);
    RuntimeInstallPrompt.instance.hostContext = context;
    if (app.pendingSearchSeq != _handledSearchSeq) {
      _handledSearchSeq = app.pendingSearchSeq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _select(1);
      });
    }

    final pages = IndexedStack(
      index: _index,
      children: [
        const ImmersiveHomePage(),
        const ImmersiveSearchPage(),
        const ImmersiveLivePage(),
        const ImmersiveHistoryPage(),
        const ImmersiveFavoritesPage(),
        Padding(
          padding: EdgeInsets.only(top: metrics.contentTop),
          child: SettingsPage(key: _settingsKey),
        ),
      ],
    );

    return Theme(
      data: immersiveTheme(context),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(child: pages),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _TopBar(
                items: _items,
                index: _index,
                time: _time,
                metrics: metrics,
                onSelect: _select,
                onExit: () => app.setPlayerSettings(
                  app.playerSettings.copyWith(immersiveMode: false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.items,
    required this.index,
    required this.time,
    required this.metrics,
    required this.onSelect,
    required this.onExit,
  });

  final List<({IconData icon, String label})> items;
  final int index;
  final String time;
  final ImmersiveMetrics metrics;
  final ValueChanged<int> onSelect;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: metrics.topBarHeight,
      padding: EdgeInsets.only(
        left: metrics.compact ? 14 : 28,
        right: metrics.compact ? 14 : 28,
        top: metrics.compact ? metrics.topPadding : 0,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xF2050705), Color(0x00050705)],
        ),
      ),
      child: metrics.compact
          ? _buildCompact(context, theme)
          : _buildWide(context, theme),
    );
  }

  /// 宽屏：品牌 + 单行导航 + 时间 + 退出，保持原布局不变。
  Widget _buildWide(BuildContext context, ThemeData theme) {
    return Row(
      children: [
        Text(
          'MisaTV',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(width: 10),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              '沉浸观影',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
        const SizedBox(width: 46),
        for (var i = 0; i < items.length; i++)
          _NavTab(
            item: items[i],
            selected: i == index,
            onTap: () => onSelect(i),
          ),
        const Spacer(),
        Text(
          time,
          style: theme.textTheme.titleMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.56),
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(width: 18),
        IconButton(
          tooltip: '退出沉浸观影',
          onPressed: onExit,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            minimumSize: const Size(40, 40),
          ),
          icon: Icon(
            Icons.fullscreen_exit_rounded,
            color: Colors.white.withValues(alpha: 0.86),
          ),
        ),
      ],
    );
  }

  /// 手机：顶栏拆两行——品牌/时间行贴状态栏下方，6 个导航等宽均分一行。
  /// 单行原布局在 360dp 宽屏必然溢出，这里用竖排图标+小字保证不挤。
  Widget _buildCompact(BuildContext context, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Text(
                'MisaTV',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(width: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    '沉浸观影',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Text(
                time,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white.withValues(alpha: 0.56),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '退出沉浸观影',
                onPressed: onExit,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  minimumSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                ),
                icon: Icon(
                  Icons.fullscreen_exit_rounded,
                  size: 20,
                  color: Colors.white.withValues(alpha: 0.86),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 48,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavTab(
                    item: items[i],
                    selected: i == index,
                    compact: true,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NavTab extends StatefulWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final ({IconData icon, String label}) item;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_NavTab> createState() => _NavTabState();
}

class _NavTabState extends State<_NavTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selected;
    final color = selected
        ? theme.colorScheme.primary
        : Colors.white.withValues(alpha: _hover ? 0.88 : 0.50);
    final decoration = BoxDecoration(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : (_hover ? Colors.white.withValues(alpha: 0.06) : null),
      borderRadius: BorderRadius.circular(8),
    );

    // 手机：图标在上、文字在下，等宽均分，触摸目标保持 48 高。
    if (widget.compact) {
      return GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: decoration,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.item.icon, size: 19, color: color),
              const SizedBox(height: 2),
              Text(
                widget.item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: color,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: decoration,
          child: Row(
            children: [
              Icon(widget.item.icon, size: 17, color: color),
              const SizedBox(width: 7),
              Text(
                widget.item.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
