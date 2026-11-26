import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/theme/app_theme.dart';
import '../../models/vod.dart';
import '../../services/discover/cover_images.dart';
import '../../services/fonts/hero_fonts.dart';
import '../detail_opener.dart';
import '../widgets/mouse_drag_scroll.dart';
import 'designed_title.dart';
import 'hero_title_style.dart';
import 'immersive_metrics.dart';
import 'title_tint.dart';

/// 沉浸观影统一的大屏主题：强制深色 + 透明 Scaffold 背景。
ThemeData immersiveTheme(BuildContext context) {
  final app = AppScope.of(context);
  final base = AppTheme.build(app.accentColor, Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    dividerColor: Colors.white.withValues(alpha: 0.10),
    cardTheme: base.cardTheme.copyWith(
      color: Colors.white.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: const Color(0xFF141A15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: const Color(0xFF20261F),
    ),
  );
}

/// 大屏可聚焦点击区域：鼠标悬停 / 键盘焦点共用同一套高亮。
///
/// 沉浸模式里的卡片大多是自绘的，不能依赖 InkWell 的焦点能力；
/// 这里统一补上焦点节点、方向键遍历与 Enter / 遥控器 OK 激活。
class ImmersiveFocusable extends StatefulWidget {
  const ImmersiveFocusable({
    super.key,
    required this.onTap,
    required this.builder,
    this.focusNode,
    this.autofocus = false,
    this.onLongPress,
    this.onSecondaryTap,
    this.onFocusChange,
    this.mouseCursor = SystemMouseCursors.click,
  });

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 鼠标右键 / 触控板双指点按：通常绑定到和长按相同的上下文菜单。
  final VoidCallback? onSecondaryTap;

  /// [active] = 鼠标悬停或键盘焦点，调用方据此画高亮。
  final Widget Function(BuildContext context, bool active) builder;

  /// 外部焦点节点（焦点记忆 / 初始焦点）；不传时内部自建。
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;
  final MouseCursor mouseCursor;

  @override
  State<ImmersiveFocusable> createState() => _ImmersiveFocusableState();
}

class _ImmersiveFocusableState extends State<ImmersiveFocusable> {
  FocusNode? _internalNode;
  bool _hover = false;
  bool _focused = false;

  FocusNode get _node =>
      widget.focusNode ??
      (_internalNode ??= FocusNode(debugLabel: 'immersive-focusable'));

  @override
  void dispose() {
    _internalNode?.dispose();
    super.dispose();
  }

  void _activate() {
    // 鼠标点击也把焦点带过来，避免焦点留在已隐藏的页面上。
    _node.requestFocus();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onFocusChange: (value) {
        if (mounted) setState(() => _focused = value);
        widget.onFocusChange?.call(value);
      },
      onKeyEvent: (node, event) {
        // 只处理卡片自己获得焦点的情况：卡片里可能嵌着节目单按钮，
        // 子按钮聚焦时回车应该触发子按钮，而不是整张卡。
        if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.gameButtonA ||
            key == LogicalKeyboardKey.space) {
          _activate();
          return KeyEventResult.handled;
        }
        // 遥控器菜单键 / 键盘 C 键：和长按、右键一样打开上下文菜单。
        if (widget.onLongPress != null &&
            (key == LogicalKeyboardKey.contextMenu ||
                key == LogicalKeyboardKey.keyC)) {
          widget.onLongPress!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: widget.mouseCursor,
        onEnter: (_) {
          if (!_hover) setState(() => _hover = true);
        },
        onExit: (_) {
          if (_hover) setState(() => _hover = false);
        },
        child: Semantics(
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _activate,
            onSecondaryTap: widget.onSecondaryTap,
            onLongPress: widget.onLongPress == null
                ? null
                : () {
                    _node.requestFocus();
                    widget.onLongPress!();
                  },
            child: Builder(
              builder: (context) => widget.builder(context, _hover || _focused),
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面 ImageProvider：渲染和后台预取必须共用同一个 key，
/// 否则 Flutter 的 ImageCache 命中不了，预取等于白下。
ImageProvider immersiveCoverProvider(String url, int decodeWidth) =>
    ResizeImage(NetworkImage(url), width: decodeWidth);

/// 只在图片实际是横图时才显示：封面来源偶尔会把竖版海报标成 16:9，
/// 直接铺到 Hero / 卡片上就是「竖版异形图」。
///
/// 解码后的宽高才是可信的；比例不足时整块留空，让下面的渐变兜底。
class _AspectSafeImage extends StatefulWidget {
  const _AspectSafeImage({
    required this.image,
    this.fit = BoxFit.cover,
    this.filterQuality = FilterQuality.medium,
    this.onResolved,
  });

  final ImageProvider image;
  final BoxFit fit;
  final FilterQuality filterQuality;

  /// 解码完成后的结果：true = 横图已显示，false = 比例不合格 / 加载失败。
  final ValueChanged<bool>? onResolved;

  /// 低于这个宽高比的图片一律不显示（竖版海报 / 4:3 截图）。
  static const double minRatio = 1.4;

  @override
  State<_AspectSafeImage> createState() => _AspectSafeImageState();
}

class _AspectSafeImageState extends State<_AspectSafeImage> {
  bool? _accepted;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _AspectSafeImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      // 新图解析可能是同步命中缓存；放到帧后再 setState，避免在 build 中标记脏。
      _detach();
      _accepted = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolve();
      });
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _resolve() {
    _detach();
    _accepted = null;
    try {
      final stream = widget.image.resolve(const ImageConfiguration());
      _stream = stream;
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          final ratio = info.image.height <= 0
              ? 0.0
              : info.image.width / info.image.height;
          stream.removeListener(listener);
          if (mounted) {
            final accepted = ratio >= _AspectSafeImage.minRatio;
            setState(() => _accepted = accepted);
            widget.onResolved?.call(accepted);
          }
        },
        onError: (Object _, StackTrace? _) {
          stream.removeListener(listener);
          if (mounted) {
            setState(() => _accepted = false);
            widget.onResolved?.call(false);
          }
        },
      );
      _listener = listener;
      stream.addListener(listener);
    } catch (_) {
      _accepted = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted != true) return const SizedBox.shrink();
    return Image(
      image: widget.image,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

/// 横图封面：先显示源里的竖版图，随后用豆瓣 / TMDB / IMDb 的横图替换。
class ImmersiveBackdrop extends StatefulWidget {
  const ImmersiveBackdrop({
    super.key,
    required this.title,
    this.year = '',
    this.fallback = '',
    this.fit = BoxFit.cover,
    this.scrim = false,
    this.placeholderTitle = '',
    this.artworkTitle = '',
    this.altTitle = '',
  });

  final String title;
  final String year;

  /// 源里的海报地址（可能是竖图、也可能是豆瓣 418 图）。
  final String fallback;
  final BoxFit fit;

  /// 是否叠一层从下到上的暗角（卡片文字用）。
  final bool scrim;

  /// 没有任何横图时，在占位渐变上显示片名，避免卡片只剩一块黑。
  final String placeholderTitle;

  /// 封面匹配使用的剧名；为空时用 [title]。
  final String artworkTitle;

  /// 元数据里的英文 / 日文原名：TMDB 条目只有原名时用它补匹配。
  final String altTitle;

  @override
  State<ImmersiveBackdrop> createState() => _ImmersiveBackdropState();
}

class _ImmersiveBackdropState extends State<ImmersiveBackdrop> {
  Future<String?>? _future;
  String _key = '';

  /// 竖版源海报会被 [_AspectSafeImage] 拦掉；只有真正显示了横图时才隐藏
  /// 占位片名，避免卡片上「模糊海报 + 片名」叠在一起。
  final ValueNotifier<bool> _fallbackVisible = ValueNotifier<bool>(false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensure();
  }

  @override
  void didUpdateWidget(covariant ImmersiveBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fallback != widget.fallback) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fallbackVisible.value = false;
      });
    }
    _ensure();
  }

  @override
  void dispose() {
    _fallbackVisible.dispose();
    super.dispose();
  }

  void _ensure() {
    final artwork = widget.artworkTitle.trim().isNotEmpty
        ? widget.artworkTitle.trim()
        : widget.title;
    final altTitle = widget.altTitle.trim();
    final key = '$artwork|${widget.year}|$altTitle';
    if (key == _key) return;
    _key = key;
    // 固定 TMDB 优先：先高分辨率横图，再剧照，最后走其它来源兜底。
    _future = AppScope.of(context).artworkService
        .backdrop(artwork, year: widget.year, altTitle: altTitle);
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.fallback.trim();
    final placeholder = widget.placeholderTitle.trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 按容器实际宽度解码：300px 的卡片不去解 1920px 的图，
        // 内存占用和首帧解码时间都能降一个数量级。
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 640.0;
        final decodeWidth = (logicalWidth * dpr).round().clamp(320, 1920);
        return Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF1A231B),
                    Color(0xFF0B0F0B),
                    Color(0xFF141A14),
                  ],
                  stops: [0, 0.55, 1],
                ),
              ),
            ),
            // 源海报先模糊铺底：匹配横图要联网搜索 + 下载，等它回来之前
            // 不再是一块纯黑；模糊后也看不出是把竖图裁成了 16:9。
            if (fallback.isNotEmpty)
              ClipRect(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                  child: Opacity(
                    opacity: 0.62,
                    child: _AspectSafeImage(
                      image: ResizeImage(NetworkImage(fallback), width: 420),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.none,
                      onResolved: (accepted) {
                        _fallbackVisible.value = accepted;
                      },
                    ),
                  ),
                ),
              ),
            // 模糊海报上再压一层暗角，保证左上角标题 / 卡片文字仍然清楚。
            if (fallback.isNotEmpty)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x66000000),
                      Color(0x22000000),
                      Color(0x88000000),
                    ],
                    stops: [0, 0.5, 1],
                  ),
                ),
              ),
            if (placeholder.isNotEmpty)
              ValueListenableBuilder<bool>(
                valueListenable: _fallbackVisible,
                builder: (context, visible, _) {
                  if (visible) return const SizedBox.shrink();
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        widget.placeholderTitle,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.36),
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ),
                  );
                },
              ),
            FutureBuilder<String?>(
              future: _future,
              builder: (context, snapshot) {
                final url = snapshot.data;
                if (url == null || url.isEmpty) {
                  return const SizedBox.shrink();
                }
                return _AspectSafeImage(
                  image: immersiveCoverProvider(url, decodeWidth),
                  fit: widget.fit,
                  filterQuality: FilterQuality.medium,
                );
              },
            ),
            if (widget.scrim)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xE6000000)],
                    stops: [0.45, 1],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// TV 风格的横版卡片（16:9 为主），悬停放大 + 描边。
/// 沉浸卡片的默认竖版封面：直接用资源站给的封面，不再逐卡补横图。
class _ImmersivePoster extends StatelessWidget {
  const _ImmersivePoster({
    required this.url,
    required this.title,
    this.headers = const <String, String>{},
  });

  final String url;
  final String title;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final display = doubanImageDisplayUrl(url);
    if (display.isEmpty) return _placeholder(context);
    return Image.network(
      display,
      fit: BoxFit.cover,
      headers: headers.isEmpty ? null : headers,
      cacheWidth: 420,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => _placeholder(context),
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : _placeholder(context),
    );
  }

  Widget _placeholder(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.32),
            accent.withValues(alpha: 0.12),
            theme.colorScheme.secondary.withValues(alpha: 0.20),
          ],
        ),
      ),
      child: Center(
        child: Text(
          title.trim().isEmpty ? '?' : title.trim().characters.first,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }
}

class ImmersiveCard extends StatefulWidget {
  const ImmersiveCard({
    super.key,
    required this.title,
    this.year = '',
    this.subtitle = '',
    this.fallback = '',
    this.imageHeaders = const <String, String>{},
    this.badge = '',
    required this.onTap,
    this.width = 300,
    this.showText = true,
    this.progress = 0,
    this.focusNode,
    this.onFocus,
    this.autofocus = false,
    this.onLongPress,
    this.onSecondaryTap,
  });

  final String title;
  final String year;
  final String subtitle;
  final String fallback;
  final Map<String, String> imageHeaders;
  final String badge;
  final VoidCallback onTap;
  final double width;
  final bool showText;

  /// 0~1 的观看进度；0 不绘制。
  final double progress;

  /// 遥控器 / 键盘焦点节点：不传时卡片内部自建，仍可键盘聚焦。
  final FocusNode? focusNode;

  /// 获得焦点时回调，供外层记录「上次聚焦的是哪个条目」。
  final VoidCallback? onFocus;

  /// 首次进入页面时是否自动抢焦点（列表首项 / 详情页主按钮用）。
  final bool autofocus;

  /// 长按 / 遥控器菜单键 / C 键。
  final VoidCallback? onLongPress;

  /// 鼠标右键。
  final VoidCallback? onSecondaryTap;

  @override
  State<ImmersiveCard> createState() => _ImmersiveCardState();
}

class _ImmersiveCardState extends State<ImmersiveCard> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ImmersiveFocusable(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onSecondaryTap,
      onFocusChange: (hasFocus) {
        if (hasFocus) widget.onFocus?.call();
      },
      builder: (context, active) => AnimatedScale(
        scale: active ? 1.035 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: active
                        ? theme.colorScheme.primary.withValues(alpha: 0.75)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.24,
                            ),
                            blurRadius: 22,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : const [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    // 沉浸货架 / 搜索 / 历史 / 收藏统一用竖版海报，
                    // 只有 Hero 与详情页背景才走横图补图逻辑。
                    aspectRatio: 2 / 3,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _ImmersivePoster(
                          url: widget.fallback,
                          headers: widget.imageHeaders,
                          title: widget.title,
                        ),
                        if (widget.showText)
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Color(0xB3000000)],
                                stops: [0.55, 1],
                              ),
                            ),
                          ),
                        if (widget.badge.isNotEmpty)
                          Positioned(
                            left: 10,
                            top: 10,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.62),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                child: Text(
                                  widget.badge,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (widget.progress > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(12),
                              ),
                              child: LinearProgressIndicator(
                                value: widget.progress.clamp(0.0, 1.0),
                                minHeight: 4,
                                backgroundColor: Colors.black.withValues(
                                  alpha: 0.34,
                                ),
                              ),
                            ),
                          ),
                        if (widget.showText)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 10,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    shadows: const [
                                      Shadow(
                                        blurRadius: 8,
                                        color: Colors.black,
                                      ),
                                    ],
                                  ),
                                ),
                                if (widget.subtitle.isNotEmpty)
                                  Text(
                                    widget.subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.66,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!widget.showText) ...[
                const SizedBox(height: 8),
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (widget.subtitle.isNotEmpty)
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.58),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ImmersiveSection extends StatelessWidget {
  const ImmersiveSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

/// 可鼠标左键拖拽、带左右翻页按钮的横向货架。
class ImmersiveShelf extends StatefulWidget {
  const ImmersiveShelf({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.height = 224,
    this.trailing,
  });

  final String title;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double height;
  final Widget? trailing;

  @override
  State<ImmersiveShelf> createState() => _ImmersiveShelfState();
}

class _ImmersiveShelfState extends State<ImmersiveShelf> {
  final ScrollController _controller = ScrollController();
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _controller.removeListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  void _sync() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final back = position.pixels > 2;
    final forward = position.maxScrollExtent - position.pixels > 2;
    if (back == _canBack && forward == _canForward) return;
    setState(() {
      _canBack = back;
      _canForward = forward;
    });
  }

  void _page(double direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target =
        (position.pixels + direction * (position.viewportDimension * 0.82))
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(width: 12),
            if (widget.trailing != null) widget.trailing!,
            const Spacer(),
            _ShelfArrow(
              icon: Icons.chevron_left_rounded,
              enabled: _canBack,
              onTap: () => _page(-1),
            ),
            const SizedBox(width: 6),
            _ShelfArrow(
              icon: Icons.chevron_right_rounded,
              enabled: _canForward,
              onTap: () => _page(1),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: widget.height,
          child: ScrollConfiguration(
            behavior: const MouseDragScrollBehavior(),
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: 18),
              itemBuilder: widget.itemBuilder,
            ),
          ),
        ),
      ],
    );
  }
}

class _ShelfArrow extends StatelessWidget {
  const _ShelfArrow({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: enabled ? onTap : null,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: enabled ? 0.09 : 0.04),
        disabledBackgroundColor: Colors.white.withValues(alpha: 0.03),
        minimumSize: const Size(38, 38),
        shape: const CircleBorder(),
      ),
      icon: Icon(
        icon,
        size: 22,
        color: Colors.white.withValues(alpha: enabled ? 0.82 : 0.20),
      ),
    );
  }
}

/// 首页顶部海报轮播。
class ImmersiveHeroItem {
  const ImmersiveHeroItem({
    required this.title,
    required this.onTap,
    this.year = '',
    this.subtitle = '',
    this.description = '',
    this.fallback = '',
    this.actionLabel = '查看详情',
    this.originalTitle = '',
    this.genres = const [],
    this.countries = const [],
  });

  final String title;
  final String year;
  final String subtitle;
  final String description;
  final String fallback;
  final String actionLabel;
  final VoidCallback onTap;

  /// 豆瓣原名（日文 / 韩文 / 英文），按地区和类型选字体时使用。
  final String originalTitle;
  final List<String> genres;
  final List<String> countries;

  ImmersiveHeroItem copyWith({
    String? originalTitle,
    List<String>? genres,
    List<String>? countries,
    String? description,
    String? subtitle,
  }) {
    return ImmersiveHeroItem(
      title: title,
      onTap: onTap,
      year: year,
      subtitle: subtitle ?? this.subtitle,
      description: description ?? this.description,
      fallback: fallback,
      actionLabel: actionLabel,
      originalTitle: originalTitle ?? this.originalTitle,
      genres: genres ?? this.genres,
      countries: countries ?? this.countries,
    );
  }
}

class ImmersiveHero extends StatefulWidget {
  const ImmersiveHero({super.key, required this.items, this.height = 520});

  final List<ImmersiveHeroItem> items;
  final double height;

  @override
  State<ImmersiveHero> createState() => _ImmersiveHeroState();
}

class _ImmersiveHeroState extends State<ImmersiveHero> {
  final PageController _controller = PageController();
  Timer? _timer;
  Timer? _prefetchTimer;
  int _index = 0;
  bool _hover = false;
  bool _prefetchScheduled = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 轮播切换是 7 秒一次；提前把后面几张的封面地址解析好，
    // 切过去时只剩图片下载，不再等豆瓣 / IMDb 搜索。
    if (_prefetchScheduled) return;
    _prefetchScheduled = true;
    _schedulePrefetch();
  }

  void _schedulePrefetch({int delayMs = 800}) {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      final items = widget.items;
      if (items.isEmpty) return;
      final artwork = AppScope.of(context).artworkService;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final decodeWidth = (MediaQuery.sizeOf(context).width * dpr)
          .round()
          .clamp(320, 1920);
      // 只预取当前及接下来 3 张：全局图片缓存是 48MB，1920 宽的 Hero
      // 解码后每张约 8MB，一次预取 8 张会把正在显示的图挤出去。
      final start = _index.clamp(0, items.length - 1);
      for (var offset = 0; offset < 4 && offset < items.length; offset++) {
        final item = items[(start + offset) % items.length];
        if (item.title.trim().isEmpty) continue;
        // 已解析 / 正在解析的会命中缓存或 inflight，不会重复请求。
        unawaited(() async {
          final url = await artwork.backdrop(
            item.title,
            year: item.year,
            altTitle: item.originalTitle,
          );
          if (!mounted || url == null || url.isEmpty) return;
          // 光解析地址还不够：这里把图片本身也拉进 Flutter 的 ImageCache，
          // 轮播切过去时不用再等下载 + 解码。
          await precacheImage(
            immersiveCoverProvider(url, decodeWidth),
            context,
            onError: (_, _) {},
          );
        }());
      }
    });
  }

  @override
  void didUpdateWidget(covariant ImmersiveHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) {
      _index = 0;
      if (_controller.hasClients) _controller.jumpToPage(0);
      _startTimer();
      _schedulePrefetch();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.items.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted || _hover || !_controller.hasClients) return;
      final next = (_index + 1) % widget.items.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _step(int direction) {
    if (!_controller.hasClients) return;
    final target = (_index + direction)
        .clamp(0, widget.items.length - 1)
        .toInt();
    if (target == _index) return;
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _prefetchTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final m = ImmersiveMetrics.of(context);
    return MouseRegion(
      onEnter: (_) => _hover = true,
      onExit: (_) => _hover = false,
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            ScrollConfiguration(
              behavior: const MouseDragScrollBehavior(),
              child: PageView.builder(
                controller: _controller,
                itemCount: items.length,
                onPageChanged: (value) {
                  setState(() => _index = value);
                  // 切页后重新排预取，保证后面几张始终是接下来的片目。
                  _schedulePrefetch(delayMs: 300);
                },
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ImmersiveBackdrop(
                        title: item.title,
                        year: item.year,
                        altTitle: item.originalTitle,
                        fallback: item.fallback,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Color(0xF20A0D0A), Color(0x000A0D0A)],
                            stops: [0.0, 0.74],
                          ),
                        ),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x66000000),
                              Colors.transparent,
                              Color(0xFF080B08),
                            ],
                            stops: [0, 0.32, 1],
                          ),
                        ),
                      ),
                      Positioned(
                        left: m.heroInset,
                        right: m.heroInset,
                        bottom: m.heroBottom,
                        child: TitleTint(
                          title: item.title,
                          year: item.year,
                          altTitle: item.originalTitle,
                          fallbackUrl: item.fallback,
                          builder: (context, tint) => ListenableBuilder(
                            listenable: HeroFontService.instance,
                            builder: (context, _) {
                              final plan = buildHeroTitlePlan(
                                title: item.title,
                                originalTitle: item.originalTitle,
                                genres: item.genres,
                                countries: item.countries,
                                tint: tint,
                              );
                              final tagline = heroTagline(
                                genres: item.genres,
                                countries: item.countries,
                                fallback: item.subtitle,
                              );
                              final heroTextMaxWidth = m.compact || m.short
                                  ? MediaQuery.sizeOf(context).width -
                                        m.heroInset * 2
                                  : double.infinity;
                              // 横屏手机：竖排标题与右侧信息并排，标题不能占满整行。
                              final verticalTitleWidth = m.short
                                  ? heroTextMaxWidth * 0.58
                                  : heroTextMaxWidth;
                              final info = _HeroInfoColumn(
                                item: item,
                                compact: plan.vertical,
                                descriptionWidth: plan.vertical
                                    ? (m.short
                                          ? heroTextMaxWidth * 0.36
                                          : (m.compact
                                                ? heroTextMaxWidth
                                                : 560))
                                    : (m.compact || m.short
                                          ? heroTextMaxWidth
                                          : 760),
                              );
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (plan.vertical)
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        DesignedTitle(
                                          plan: plan,
                                          maxWidth: verticalTitleWidth,
                                          maxHeight: (widget.height - 220)
                                              .clamp(80.0, double.infinity)
                                              .toDouble(),
                                          overline: tagline,
                                        ),
                                        SizedBox(width: m.short ? 16 : 26),
                                        Flexible(child: info),
                                      ],
                                    )
                                  else ...[
                                    DesignedTitle(
                                      plan: plan,
                                      maxWidth: heroTextMaxWidth,
                                      maxHeight: (widget.height - 220)
                                          .clamp(80.0, double.infinity)
                                          .toDouble(),
                                      overline: tagline,
                                    ),
                                    info,
                                  ],
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (items.length > 1)
              Positioned(
                right: m.compact || m.short ? 16 : 56,
                bottom: m.compact || m.short ? 16 : 58,
                child: Row(
                  children: [
                    for (var i = 0; i < items.length; i++)
                      GestureDetector(
                        onTap: () => _controller.animateToPage(
                          i,
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeOutCubic,
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: i == _index ? 26 : 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 6),
                          decoration: BoxDecoration(
                            color: i == _index
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.32),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                    const SizedBox(width: 18),
                    _HeroArrow(
                      icon: Icons.chevron_left_rounded,
                      onTap: () => _step(-1),
                    ),
                    const SizedBox(width: 8),
                    _HeroArrow(
                      icon: Icons.chevron_right_rounded,
                      onTap: () => _step(1),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 年份 / 简介 / 按钮。竖排标题时放到条幅右侧，横排时放在标题下方。
class _HeroInfoColumn extends StatelessWidget {
  const _HeroInfoColumn({
    required this.item,
    required this.compact,
    required this.descriptionWidth,
  });

  final ImmersiveHeroItem item;
  final bool compact;
  final double descriptionWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.year.isNotEmpty) ...[
          if (!compact) const SizedBox(height: 12),
          Text(
            item.year,
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.66),
            ),
          ),
        ],
        if (item.description.isNotEmpty) ...[
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: descriptionWidth),
            child: Text(
              item.description,
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.white.withValues(alpha: 0.80),
                height: 1.6,
              ),
            ),
          ),
        ],
        const SizedBox(height: 26),
        FilledButton.icon(
          onPressed: item.onTap,
          icon: const Icon(Icons.play_arrow_rounded, size: 24),
          label: Text(item.actionLabel),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
            textStyle: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡片点击：豆瓣推荐源没有可播线路，改为全源搜索。
///
/// [autoPlay] 为 true 时详情加载完直接起播（继续观看 / 历史卡）；
/// [fromStart] 配合它使用，忽略历史进度从头播放。
void openImmersiveItem(
  BuildContext context,
  VodItem item, {
  bool autoPlay = false,
  bool fromStart = false,
}) {
  final app = AppScope.of(context);
  final titleOnly =
      item.id.trim().isNotEmpty && item.id.trim() == item.name.trim();
  if (app.isDoubanSourceKey(item.sourceKey) || titleOnly) {
    app.requestSearch(item.name);
    return;
  }
  // 详情页的具体实现由各入口注入（见 ui/detail_opener.dart）：
  // 全功能版是 pages/detail_page.dart，TV 版是 tv_detail_page.dart。
  // 这里只依赖注入点，避免把 4000 多行的常规详情页拖进 TV 构建。
  openImmersiveDetail(context, item, autoPlay: autoPlay, fromStart: fromStart);
}

/// 沉浸模式统一的上下文菜单：长按、遥控器菜单键、右键都会打开它。
Future<void> showImmersiveActionMenu(
  BuildContext context, {
  required String title,
  required List<({IconData icon, String label, VoidCallback onTap})> actions,
}) async {
  if (actions.isEmpty) return;
  final theme = immersiveTheme(context);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF141A15),
    showDragHandle: true,
    builder: (sheetContext) => Theme(
      data: theme,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 24, 10),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (var i = 0; i < actions.length; i++)
              ListTile(
                autofocus: i == 0,
                leading: Icon(actions[i].icon),
                title: Text(actions[i].label),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  actions[i].onTap();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class _HeroArrow extends StatelessWidget {
  const _HeroArrow({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.42),
        minimumSize: const Size(42, 42),
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 24, color: Colors.white.withValues(alpha: 0.86)),
    );
  }
}

class ImmersiveEmpty extends StatelessWidget {
  const ImmersiveEmpty({
    super.key,
    required this.title,
    this.message = '',
    this.action,
  });

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.wb_twilight_rounded,
            size: 56,
            color: Colors.white.withValues(alpha: 0.20),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}
