/// 随包运行时：发布包在 `<exe>/runtime/<name>` 放构建期准备好的运行时目录
/// （由 `tool/prepare_windows_runtimes.ps1` 生成）。安装时优先从这里复制，
/// 不再走网络下载；随包缺失才回落原有的下载逻辑。
///
/// 之所以「复制」而不是直接使用：安装目录里还要写 shims、版本标记和缓存，
/// 直接指向程序目录会在只读安装位置（如 Program Files）失败。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class BundledRuntime {
  const BundledRuntime._();

  /// 随包目录；不存在或非 Windows 返回 null。
  /// [exeDir] 仅供测试注入，正常调用不传。
  static Directory? locate(String name, {String? exeDir}) {
    if (!Platform.isWindows) return null;
    try {
      final base = exeDir ?? File(Platform.resolvedExecutable).parent.path;
      final dir = Directory(p.join(base, 'runtime', name));
      return dir.existsSync() ? dir : null;
    } catch (_) {
      return null;
    }
  }

  /// 把 `<exe>/runtime/<name>` 复制到 target（target 已有内容则跳过）。
  /// 返回 true 表示 target 事后已就绪（随包复制成功，或本来就有内容）。
  static bool seed(String name, Directory target, {String? exeDir}) {
    final src = locate(name, exeDir: exeDir);
    if (src == null) return false;
    try {
      if (target.existsSync() && target.listSync().isNotEmpty) return true;
      _copyTree(src, target);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void _copyTree(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final entity in src.listSync()) {
      final dest = p.join(dst.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyTree(entity, Directory(dest));
      } else if (entity is File) {
        entity.copySync(dest);
      }
    }
  }
}
