import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:kniephos/services/quotes/movie_quotes.dart';
import 'package:kniephos/services/quotes/quote_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _item(String line, String from) => {
  'hitokoto': line,
  'from': from,
  'type': 'h',
};

void main() {
  group('parseQuoteBundle', () {
    test('保留中文、清洗出处与标点、过滤占位/外文/超长/重复', () {
      final json = jsonEncode([
        _item('爱你所爱，行你所行。', '《无问西东》'),
        _item('爱你所爱，行你所行。', '《无问西东》'),
        _item('高调做事，低调做人。', '某电视剧'),
        _item('I will always be here for you.', '环太平洋 Pacific Rim'),
        _item('不要温和地走进那个良夜', '星际穿越'),
        _item('', '空台词'),
        _item('有台词', ''),
        _item(List.filled(70, '这').join(), '超长出处'),
        _item('某个网站来的句子', 'www.example.com'),
      ]);
      final quotes = parseQuoteBundle(json);
      expect(quotes.length, 2);
      expect(quotes[0].line, '爱你所爱，行你所行');
      expect(quotes[0].title, '无问西东');
      expect(quotes[1].line, '不要温和地走进那个良夜');
      expect(quotes[1].title, '星际穿越');
    });

    test('非法 JSON / 非数组返回空表', () {
      expect(parseQuoteBundle('不是 json'), isEmpty);
      expect(parseQuoteBundle('{}'), isEmpty);
      expect(parseQuoteBundle('[]'), isEmpty);
    });
  });

  group('QuoteService', () {
    test('在线拉取 h + a，合并去重并写入缓存', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await LocalStore.create();
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (req.url.path.endsWith('/h.json')) {
          return http.Response(
            jsonEncode([
              _item('活着就是为了改变世界。', '某某电影'),
              _item('占位出处会被丢弃', '某电影'),
            ]),
            200,
            headers: _jsonHeaders,
          );
        }
        if (req.url.path.endsWith('/a.json')) {
          return http.Response(
            jsonEncode([
              _item('你的心脏不会呐喊吗', '海贼王'),
              _item('I will always be here for you.', '环太平洋 Pacific Rim'),
            ]),
            200,
            headers: _jsonHeaders,
          );
        }
        return http.Response('not found', 404);
      });
      final service = QuoteService(AppHttp(client: client), store);
      final quotes = await service.load();
      expect(quotes.length, 2);
      expect(quotes.map((q) => q.title), containsAll(['某某电影', '海贼王']));
      expect(calls, 2, reason: 'h.json 与 a.json 各请求一次');
      expect(store.movieQuotesCacheJson, contains('海贼王'));
    });

    test('新实例优先使用缓存；过期后重新拉取', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await LocalStore.create();
      final cached = jsonEncode({
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'quotes': [
          ['缓存里的台词', '缓存电影'],
        ],
      });
      await store.saveMovieQuotesCacheJson(cached);

      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          jsonEncode([_item('在线的新台词', '新电影')]),
          200,
          headers: _jsonHeaders,
        );
      });
      final fresh = QuoteService(AppHttp(client: client), store);
      final list = await fresh.load();
      expect(list.single.line, '缓存里的台词');
      expect(calls, 0, reason: '缓存未过期时不应联网');

      final stale = QuoteService(
        AppHttp(client: client),
        store,
        cacheTtl: Duration.zero,
      );
      final refreshed = await stale.load();
      expect(refreshed.single.line, '在线的新台词');
      expect(calls, 2, reason: 'h 与 a 各拉一次');
    });

    test('无缓存且网络失败时回落到内置台词', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await LocalStore.create();
      final service = QuoteService(
        AppHttp(client: MockClient((_) async => http.Response('boom', 500))),
        store,
      );
      final quotes = await service.load();
      expect(quotes, isNotEmpty);
      expect(quotes.length, movieQuotes.length);
      expect(quotes.first.display, movieQuotes.first.display);
    });
  });
}
