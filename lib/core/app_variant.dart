/// TV 精简版开关。
///
/// 通过编译期常量控制：`flutter build apk --dart-define=MISA_TV=true`。
///
/// 用 `--dart-define` 而不是 productFlavors 的原因：
///   · Dart 侧能直接 `if (kMisaTv)` 把整块 UI 摇掉（tree-shaking），
///     只改 Gradle 的话不用的页面仍会被编译进 AOT；
///   · 同一个 Flutter 工程不需要维护两套 main 与两份 pubspec。
///
/// TV 版保留：沉浸观影界面、Python 蜘蛛、JS 蜘蛛、jar/DEX 蜘蛛（安卓原生
/// DexClassLoader，不需要 JRE）、直播、网盘、WebDAV、弹幕、流转。
/// TV 版移除：常规 UI 页面、一起看、DLNA 投屏、外部播放器管理、
/// JVM 运行时资源、aria2c、多余字体。
library;

/// 是否为 TV 精简版构建。
const bool kMisaTv = bool.fromEnvironment('MISA_TV');

/// 常规（全功能）版：`!kMisaTv`。
const bool kMisaFull = !kMisaTv;
