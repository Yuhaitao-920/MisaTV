import 'dart:io';

import 'package:path/path.dart' as p;

/// 改名 MisaTV 后，Windows 应用数据目录（`%APPDATA%\<company>\<product>`）随版本信息改变。
///
/// 首次启动时把旧的 `com.kniephos\Kniephos` 整体搬到新目录，
/// 避免订阅、网盘登录态与已下载运行时“凭空消失”。只搬一次：
/// 新目录已有内容时不动（回滚旧版或二次启动都安全）。
Future<void> migrateLegacySupportDir(String newPath) async {
  if (!Platform.isWindows) return;
  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    final legacy = Directory(p.join(appData, 'com.kniephos', 'Kniephos'));
    final target = Directory(newPath);
    if (legacy.existsSync()) {
      try {
        final marker = File(p.join(target.path, '.migrated-from-kniephos'));
        var ready = false;
        if (target.existsSync()) {
          if (target.listSync().isEmpty) {
            await target.delete(recursive: true);
          } else if (marker.existsSync()) {
            ready = true; // 已完整搬迁过（回滚/二次启动）→ 不覆盖
            // 上次因旧进程占用没删掉的备份目录：这次再尽力清理（删不掉也无妨）。
            try {
              await legacy.delete(recursive: true);
            } catch (_) {}
          }
        }
        if (!ready) {
          await target.parent.create(recursive: true);
          try {
            await legacy.rename(target.path);
            await marker.writeAsString('renamed', flush: true);
          } catch (_) {
            // 目录被占用（旧版残留 java.exe / 杀毒软件扫描）时 rename 会拒绝访问；
            // 退化为逐文件复制，先保证数据能用，再尽力清掉旧目录。
            // 上次复制被打断时目标目录非空但没有标记文件 → 这里会继续补拷。
            await _copyDirectory(legacy, target);
            await marker.writeAsString('copied', flush: true);
            try {
              await legacy.delete(recursive: true);
            } catch (_) {
              // 仍被占用 → 留在原地当备份，下次启动也不会重复搬（新目录已有标记）。
            }
          }
        }
      } catch (_) {
        // 极端情况（跨盘/无权限）：放弃搬迁，按新目录重新开始（不影响启动）。
      }
    }
  }
  // WebView2 的会话目录按 exe 文件名生成，一并搬走，免去重新扫码登录。
  try {
    final exe = Platform.resolvedExecutable;
    final legacyWebView = Directory(
      p.join(p.dirname(exe), 'kniephos.exe.WebView2'),
    );
    final targetWebView = Directory('$exe.WebView2');
    if (legacyWebView.existsSync() && !targetWebView.existsSync()) {
      await legacyWebView.rename(targetWebView.path);
    }
  } catch (_) {
    // 被占用（旧版仍在运行）→ 下次启动再试。
  }
}

/// 递归复制目录（单文件失败不中断，锁住的文件下次启动还能再补）。
Future<void> _copyDirectory(Directory from, Directory to) async {
  await to.create(recursive: true);
  // 偏好文件优先：它最小、最重要，哪怕复制大目录时被打断也不丢订阅与登录态。
  final prefs = File(p.join(from.path, 'shared_preferences.json'));
  if (prefs.existsSync()) {
    try {
      await prefs.copy(p.join(to.path, 'shared_preferences.json'));
    } catch (_) {}
  }
  await for (final entity in from.list(followLinks: false)) {
    final name = p.basename(entity.path);
    final targetPath = p.join(to.path, name);
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(targetPath));
    } else if (entity is File) {
      if (name == 'shared_preferences.json') continue; // 上面已优先复制
      try {
        await entity.copy(targetPath);
      } catch (_) {
        // 被占用/正在写入的单文件跳过
      }
    }
  }
}
