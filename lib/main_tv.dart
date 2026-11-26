import 'main.dart' show runKniephosTv;
import 'ui/detail_tv.dart';
import 'ui/shell/tv_shell.dart';

/// TV 精简版的入口。
///
/// 构建命令：
/// ```bash
/// flutter build apk --release --flavor tv --target main_tv.dart \
///   --target-platform android-arm64
/// ```
///
/// 与 `main.dart` 共用全部初始化逻辑（`runKniephosTv` 内部就是同一个
/// `_bootstrap`），**唯一区别是根界面**。
///
/// 这个文件刻意**不 import `ui/shell/app_shell.dart`**：
/// `AppShell` 顶部导入了 home / favorites / history / live / search /
/// settings 六个常规页面（合计约 7600 行），一旦被 import 就会整个编译进
/// `libapp.so`。TV 版只渲染沉浸界面，没必要背这部分产物。
///
/// 也**不 import `core/app_variant.dart`** —— 入口文件本身已经区分了变体，
/// 不需要再在运行时判断（那样反而会把两边的代码都拉进来）。
void main(List<String> args) {
  runKniephosTv(
    args,
    () => const TvShell(),
    // 用精简详情页（tv_detail_page.dart），不装完整的 DetailPage。
    installDetailOpener: installTvDetailOpener,
  );
}
