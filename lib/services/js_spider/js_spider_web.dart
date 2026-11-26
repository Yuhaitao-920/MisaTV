import '../../models/site_config.dart';
import '../../models/vod.dart';

/// Web 版没有 QuickJS FFI，JS 蜘蛛不可用；接口保持与 IO 版一致。
class JsSpiderService {
  JsSpiderService({
    Map<String, String> Function()? driveTokens,
    Map<String, String> Function()? localSeed,
  });

  bool get available => false;

  /// Web 版没有执行器，开关仅做接口兼容。
  void setWorkerCount(int count) {}

  Future<CmsResult> home(SourceBean site) async => const CmsResult();

  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) async => const CmsResult();

  Future<VodDetail?> detail(SourceBean site, String id) async => null;

  Future<List<VodItem>> search(SourceBean site, String keyword) async =>
      const [];

  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String id, {
    List<String> vipFlags = const [],
  }) async => null;

  Future<void> dispose() async {}
}
