import 'package:file_selector/file_selector.dart';

/// Web 预览版不做本地文件读写（浏览器没有稳定的路径语义）。
class FileDialogService {
  const FileDialogService._();

  static const jsonType = XTypeGroup(
    label: 'JSON',
    extensions: ['json', 'txt'],
  );
  static const pyType = XTypeGroup(label: 'Python', extensions: ['py']);
  static const backupType = XTypeGroup(label: '备份', extensions: ['json']);
  static const liveType = XTypeGroup(
    label: '直播源',
    extensions: ['txt', 'm3u', 'm3u8'],
  );
  static const zipType = XTypeGroup(label: 'ZIP', extensions: ['zip']);
  static const exeType = XTypeGroup(label: '播放器', extensions: ['exe']);
  static const fontType = XTypeGroup(label: '字体', extensions: ['ttf', 'otf']);

  static Future<String?> pickFile({
    required List<XTypeGroup> types,
    String confirmButtonText = '选择',
  }) async => throw UnsupportedError('Web 版不支持本地文件导入');

  static Future<List<String>?> pickFiles({
    required List<XTypeGroup> types,
    String confirmButtonText = '选择',
  }) async => throw UnsupportedError('Web 版不支持本地文件导入');

  static Future<String?> pickDirectory({
    String confirmButtonText = '选择文件夹',
  }) async => throw UnsupportedError('Web 版不支持本地目录导入');

  static Future<String> readText(String path) async =>
      throw UnsupportedError('Web 版不支持读取本地文件');

  static Future<String?> saveText({
    required String suggestedName,
    required String text,
    XTypeGroup? type,
  }) async => throw UnsupportedError('Web 版不支持导出到本地文件');
}
