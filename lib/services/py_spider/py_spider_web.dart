import '../../models/site_config.dart';
import '../../models/vod.dart';

/// 蜘蛛 `localProxy` 的返回值（Web 版没有运行时，仅保持接口一致）。
class SpiderProxyResult {
  const SpiderProxyResult({
    required this.status,
    required this.contentType,
    required this.body,
    this.headers = const {},
  });

  final int status;
  final String contentType;
  final String body;
  final Map<String, String> headers;

  String header(String name) => headers[name] ?? '';
}

/// Web 版没有嵌入式 Python 运行时；接口保持与 IO 版一致。
class PySpiderService {
  PySpiderService({Map<String, String> Function()? driveTokens});

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

  Future<String> live(SourceBean site, String url) async => '';

  Future<SpiderProxyResult> proxy(
    SourceBean site,
    Map<String, String> params,
  ) async => throw UnsupportedError('Web 版不支持 PY 蜘蛛直播代理');

  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String id, {
    List<String> vipFlags = const [],
  }) async => null;

  Future<void> shutdown() async {}
}
