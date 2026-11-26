import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/quotes/movie_quotes.dart';

void main() {
  group('影视台词库', () {
    test('条目完整：台词与片名非空，展示格式统一', () {
      expect(movieQuotes.length, greaterThanOrEqualTo(20));
      for (final quote in movieQuotes) {
        expect(quote.line.trim(), isNotEmpty);
        expect(quote.title.trim(), isNotEmpty);
        expect(quote.display, '${quote.line}——《${quote.title}》');
        expect(quote.display, contains('——《'));
        expect(quote.display, endsWith('》'));
        expect(quote.searchKeyword, quote.title);
      }
    });

    test('台词不重复', () {
      final displays = movieQuotes.map((e) => e.display).toList();
      expect(displays.toSet().length, displays.length);
    });

    test('包含示例台词：你的心脏不会呐喊吗——《海贼王》', () {
      final hits = movieQuotes.where(
        (quote) => quote.title == '海贼王' && quote.line == '你的心脏不会呐喊吗',
      );
      expect(hits.length, 1);
      expect(hits.single.display, '你的心脏不会呐喊吗——《海贼王》');
    });

    test('搜索关键词优先取中文片名', () {
      expect(
        const MovieQuote(line: 'x', title: '环太平洋 Pacific Rim').searchKeyword,
        '环太平洋',
      );
      expect(const MovieQuote(line: 'x', title: '《海贼王》').searchKeyword, '海贼王');
      expect(
        const MovieQuote(
          line: 'x',
          title: 'ef-a tale of memories',
        ).searchKeyword,
        'ef-a tale of memories',
      );
      expect(containsChinese('hello'), isFalse);
      expect(containsChinese('你好 hello'), isTrue);
    });
  });
}
