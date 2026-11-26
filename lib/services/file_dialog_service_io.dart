import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// 本地文件/目录选择与保存。桌面端走系统对话框；Web 版在 `*_web.dart` 里统一拒绝。
class FileDialogService {
  const FileDialogService._();

  /// Android 侧的写入通道。
  ///
  /// 复用 `sleep_inhibitor` 这个通道名是历史原因：`MainActivity` 里
  /// keep-screen-on 与 exportLogFile 挂在同一个 MethodChannel 上。改通道名要
  /// 同步改 Kotlin 侧，否则 Android 上备份导出会静默失败。
  static const _exportChannel = MethodChannel(
    'com.kniephos.kniephos/sleep_inhibitor',
  );

  static const jsonType = XTypeGroup(
    label: 'JSON / TVBox 订阅',
    extensions: ['json', 'txt'],
  );
  static const pyType = XTypeGroup(label: 'Python 蜘蛛', extensions: ['py']);
  static const backupType = XTypeGroup(
    label: 'MisaTV / Win-Box 备份',
    extensions: ['json'],
  );
  static const liveType = XTypeGroup(
    label: '直播源（TXT / M3U）',
    extensions: ['txt', 'm3u', 'm3u8'],
  );
  static const zipType = XTypeGroup(label: '本地包（ZIP）', extensions: ['zip']);
  static const exeType = XTypeGroup(label: '第三方播放器', extensions: ['exe']);
  static const fontType = XTypeGroup(
    label: '字体（TTF / OTF）',
    extensions: ['ttf', 'otf'],
  );

  /// 选择单个文件，返回绝对路径；取消返回 null。
  static Future<String?> pickFile({
    required List<XTypeGroup> types,
    String confirmButtonText = '选择',
  }) async {
    final file = await openFile(
      acceptedTypeGroups: types,
      confirmButtonText: confirmButtonText,
    );
    return file?.path;
  }

  /// 多选文件，返回绝对路径列表；取消返回 null。
  static Future<List<String>?> pickFiles({
    required List<XTypeGroup> types,
    String confirmButtonText = '选择',
  }) async {
    final files = await openFiles(
      acceptedTypeGroups: types,
      confirmButtonText: confirmButtonText,
    );
    if (files.isEmpty) return null;
    return files.map((file) => file.path).toList();
  }

  /// 选择目录，返回绝对路径；取消返回 null。
  static Future<String?> pickDirectory({String confirmButtonText = '选择文件夹'}) =>
      getDirectoryPath(confirmButtonText: confirmButtonText);

  /// 读取文本文件（备份导入等）。
  static Future<String> readText(String path) => File(path).readAsString();

  /// 选择保存位置并写入文本；取消返回 null，成功返回文件路径。
  static Future<String?> saveText({
    required String suggestedName,
    required String text,
    XTypeGroup? type,
  }) async {
    // Android 没有系统「另存为」对话框（file_selector 的 getSaveLocation 在
    // Android 上不可用），改为写进 MediaStore 的 Downloads/MisaTV。
    // 走 exportLogFile 通道复用 MainActivity 里现成的 MediaStore 写入实现。
    if (Platform.isAndroid) {
      final safeName = suggestedName.trim().isEmpty
          ? 'misatv-export.txt'
          : suggestedName.trim();
      final tmp = File(
        '${Directory.systemTemp.path}/misatv_export_${DateTime.now().millisecondsSinceEpoch}_$safeName',
      );
      await tmp.writeAsString(text);
      try {
        final saved = await _exportChannel.invokeMethod<String>(
          'exportLogFile',
          {'path': tmp.path, 'name': safeName},
        );
        return saved;
      } finally {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      }
    }
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: type == null ? const [] : [type],
      confirmButtonText: '保存',
    );
    if (location == null) return null;
    final file = File(location.path);
    await file.writeAsString(text);
    return file.path;
  }
}
