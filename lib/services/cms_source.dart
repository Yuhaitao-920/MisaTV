import '../core/net/app_http.dart';
import '../models/site_config.dart';
import '../models/vod.dart';
import 'movie_parser.dart';

class CmsSource {
  CmsSource(this.http);
  final AppHttp http;

  String _ac(int type) => type == 0 ? 'videolist' : 'detail';

  Future<String> _fetch(String url, int timeoutSeconds) async {
    final res = await http.getText(
      url,
      timeout: Duration(seconds: timeoutSeconds),
    );
    return res.body;
  }

  Uri _buildUri(String api, Map<String, String> params) {
    final base = Uri.parse(api);
    final query = <String, String>{...base.queryParameters, ...params};
    return base.replace(queryParameters: query);
  }

  Future<CmsResult> home(SourceBean site) async {
    if (!site.supported) throw SourceException(site.unsupportedReason);
    try {
      final text = await _fetch(site.api, site.timeout);
      final body = MovieParser.parse(text, site.type, site.key);
      final items = MovieParser.toItems(body.movie, site.key);
      final prose = CmsResult(
        classes: body.classes,
        items: items,
        page: body.movie?.page ?? 0,
        pagecount: body.movie?.pagecount ?? 0,
        total: body.movie?.recordcount ?? 0,
      );
      if (items.isEmpty && body.classes.isNotEmpty) {
        try {
          final fallback = await category(
            site,
            body.classes.first.id,
            '1',
            const {},
          );
          if (fallback.items.isNotEmpty) {
            return CmsResult(
              classes: body.classes,
              items: fallback.items,
              page: fallback.page,
              pagecount: fallback.pagecount == 0 ? 1 : fallback.pagecount,
              total: fallback.total == 0
                  ? fallback.items.length
                  : fallback.total,
              homeFallback: true,
            );
          }
        } catch (_) {
          // 回退失败不影响分类浏览
        }
      }
      return prose;
    } on AppHttpException catch (e) {
      throw SourceException(e.message);
    }
  }

  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) async {
    if (!site.supported) throw SourceException(site.unsupportedReason);
    final params = <String, String>{'ac': _ac(site.type), 't': tid, 'pg': pg};
    if (filters.isNotEmpty) {
      var json = '{';
      var first = true;
      for (final e in filters.entries) {
        if (!first) json += ',';
        first = false;
        json += '"${e.key}":"${e.value.replaceAll('"', r'\"')}"';
      }
      json += '}';
      params['f'] = json;
    }
    final uri = _buildUri(site.api, params);
    try {
      final text = await _fetch(uri.toString(), site.timeout);
      final body = MovieParser.parse(text, site.type, site.key);
      return CmsResult(
        items: MovieParser.toItems(body.movie, site.key),
        page: body.movie?.page ?? 0,
        pagecount: body.movie?.pagecount ?? 0,
        total: body.movie?.recordcount ?? 0,
      );
    } on AppHttpException catch (e) {
      throw SourceException(e.message);
    }
  }

  Future<VodDetail?> detail(SourceBean site, String id) async {
    if (!site.supported) throw SourceException(site.unsupportedReason);
    final uri = _buildUri(site.api, {'ac': _ac(site.type), 'ids': id});
    try {
      final text = await _fetch(uri.toString(), site.timeout);
      final body = MovieParser.parse(text, site.type, site.key);
      return MovieParser.toDetail(body.movie, site.key);
    } on AppHttpException catch (e) {
      throw SourceException(e.message);
    }
  }

  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    if (!site.supported) throw SourceException(site.unsupportedReason);
    final uri = _buildUri(site.api, {'ac': _ac(site.type), 'wd': keyword});
    try {
      final text = await _fetch(uri.toString(), site.timeout);
      final body = MovieParser.parse(text, site.type, site.key);
      return MovieParser.toItems(body.movie, site.key);
    } on AppHttpException catch (e) {
      throw SourceException(e.message);
    }
  }
}
