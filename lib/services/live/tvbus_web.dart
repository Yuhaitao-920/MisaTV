import '../../models/site_config.dart';
import '../../models/vod.dart';

/// Web 版没有 TVBus（Go 引擎是 Android 原生 `.so`）。
class TvBusService {
  TvBusService._();
  static final TvBusService instance = TvBusService._();

  bool get supported => false;

  Future<String> resolve({
    required String url,
    required TvBusCore core,
    Map<String, String> headers = const {},
    String? baseUrl,
  }) async => throw SourceException('TVBus 仅支持 Android');

  Future<void> stop() async {}

  Future<void> shutdown() async {}
}
