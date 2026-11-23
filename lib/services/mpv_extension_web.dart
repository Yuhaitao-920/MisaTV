import 'package:flutter/foundation.dart';

/// Web 端不支持外部 MPV 扩展。
class MpvExtension {
  MpvExtension._();
  static final MpvExtension instance = MpvExtension._();

  Future<bool> get isInstalled async => false;
  Future<bool> get hasUpdate async => false;
  Future<String> get executablePath async => '';
  Future<Map<String, String>> get meta async => const {};
  Future<String> get rootPath async => '';

  Future<String> install({ValueChanged<MpvProgress>? onProgress}) async {
    throw const MpvException('Yaozhi MPV 扩展仅支持 Windows 桌面版');
  }

  Future<void> remove() async {}

  Future<void> open(
    String url, {
    Map<String, String> headers = const {},
    int startSeconds = 0,
  }) async {
    throw const MpvException('Yaozhi MPV 扩展仅支持 Windows 桌面版');
  }
}

class MpvProgress {
  const MpvProgress(this.received, this.total, this.stage);
  final int received;
  final int total;
  final String stage;

  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class MpvException implements Exception {
  const MpvException(this.message);
  final String message;

  @override
  String toString() => message;
}
