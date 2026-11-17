import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/platform/window_service.dart';
import 'core/theme/app_theme.dart';
import 'state/app_state.dart';
import 'ui/shell/app_shell.dart';
import 'ui/widgets/app_backdrop.dart';
import 'ui/widgets/app_title_bar.dart';
import 'ui/widgets/update_gate.dart';

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found');
    return scope!.notifier!;
  }
}

/// 是否显示自绘窗口标题栏：只在首页 / 底部导航各页显示。
///
/// 进入详情、播放器、直播播放等**带返回按钮**的二级页面时隐藏，让内容铺满整个
/// 窗口；返回上一层后自动恢复。只统计 [PageRoute]，对话框 / 底部弹层不影响。
final ValueNotifier<bool> appTitleBarVisible = ValueNotifier<bool>(true);

/// 全局 Navigator：沉浸模式的 Esc / 遥控器返回需要从任意二级页面执行返回。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'app-navigator',
);

/// 返回键分发：没有可 pop 的页面时，由 [ImmersiveShell] 退回首页 Tab。
final ValueNotifier<int> immersiveBackRequests = ValueNotifier<int>(0);

void _handleImmersiveBack() {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return;
  if (navigator.canPop()) {
    navigator.maybePop();
    return;
  }
  immersiveBackRequests.value++;
}

class _AppTitleBarObserver extends NavigatorObserver {
  final Set<Route<dynamic>> _pages = <Route<dynamic>>{};

  void _sync() => appTitleBarVisible.value = _pages.length <= 1;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      if (route.isFirst) {
        // 初始化 / 状态恢复时可能一次塞多条历史：以首条为根页面重算。
        _pages
          ..clear()
          ..add(route);
      } else {
        _pages.add(route);
      }
      _sync();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_pages.remove(route)) _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_pages.remove(route)) _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _pages.remove(oldRoute);
    if (newRoute is PageRoute) _pages.add(newRoute);
    _sync();
  }
}

final NavigatorObserver _titleBarObserver = _AppTitleBarObserver();

class KniephosApp extends StatelessWidget {
  const KniephosApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final seed = state.accentColor;
          return MaterialApp(
            title: 'MisaTV',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.build(seed, Brightness.light),
            darkTheme: AppTheme.build(seed, Brightness.dark),
            themeMode: state.themeMode,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            // 自绘标题栏放在 Navigator 之上：页面与弹窗都不会盖住窗口按钮。
            // 背景用 CustomPaint 直接画在内容之下（同一绘制层），见 AppBackdropPainter 注释。
            navigatorObservers: [_titleBarObserver],
            navigatorKey: appNavigatorKey,
            builder: (context, child) {
              final theme = Theme.of(context);
              Widget frame = CustomPaint(
                painter: AppBackdropPainter(
                  dark: theme.brightness == Brightness.dark,
                ),
                child: Column(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: appTitleBarVisible,
                      builder: (context, visible, _) =>
                          visible && !state.playerSettings.immersiveMode
                          ? const AppTitleBar()
                          : const SizedBox.shrink(),
                    ),
                    Expanded(child: child ?? const SizedBox.shrink()),
                  ],
                ),
              );
              if (state.playerSettings.immersiveMode) {
                // 大屏模式：Esc / 遥控器返回先 pop 二级页面，根页面交给外壳回首页。
                frame = CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.escape):
                        _handleImmersiveBack,
                    const SingleActivator(LogicalKeyboardKey.browserBack):
                        _handleImmersiveBack,
                    const SingleActivator(LogicalKeyboardKey.gameButtonB):
                        _handleImmersiveBack,
                  },
                  child: frame,
                );
              }
              return windowFrame(frame);
            },
            // 启动后检查 GitHub release，有新版本就弹窗（见 UpdateGate）。
            home: const UpdateGate(child: AppShell()),
          );
        },
      ),
    );
  }
}
