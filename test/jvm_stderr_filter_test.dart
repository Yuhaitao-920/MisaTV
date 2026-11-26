import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jar_spider/spider_host.dart';

void main() {
  group('JvmStderrFilter', () {
    test('普通行原样保留', () {
      final filter = JvmStderrFilter();
      expect(filter.feed('[host-proxy] listening port=1234'), [
        '[host-proxy] listening port=1234',
      ]);
      expect(filter.feed('普通日志'), ['普通日志']);
    });

    test('堆栈折叠成一行并保留首行与帧数', () {
      final filter = JvmStderrFilter();
      expect(filter.feed('java.lang.NullPointerException: boom'), isEmpty);
      expect(filter.feed('    at com.foo.Bar.baz(Bar.java:1)'), isEmpty);
      expect(filter.feed('    at com.foo.Bar.qux(Bar.java:2)'), isEmpty);
      expect(filter.feed('\tat com.foo.Other.run(Other.java:3)'), isEmpty);
      final out = filter.feed('after');
      expect(out.length, 2);
      expect(out.first, contains('NullPointerException: boom'));
      expect(out.first, contains('堆栈 3 行已折叠'));
      expect(out.last, 'after');
    });

    test('重复异常超过阈值后降频，但仍保留计数', () {
      final filter = JvmStderrFilter(spamThreshold: 2);
      final out = <String>[];
      for (var i = 0; i < 5; i++) {
        out.addAll(filter.feed('java.lang.IllegalStateException: same'));
        out.addAll(filter.feed('    at com.foo.Bar.baz(Bar.java:1)'));
        out.addAll(filter.feed('next'));
      }
      // 前 2 次逐条输出；之后每 N 次才输出一条（第 4 次），第 3/5 次被降频。
      expect(
        out.where((line) => line.contains('IllegalStateException')).length,
        3,
      );
      expect(out.where((line) => line.contains('同类第 2 次')).length, 1);
    });

    test('JVM 启动告警不进入 errorTail', () {
      final filter = JvmStderrFilter();
      expect(
        filter.feed('WARNING: System::setSecurityManager has been called by X'),
        isEmpty,
      );
      expect(
        filter.feed(
          'WARNING: Please consider reporting this to the maintainers of X',
        ),
        isEmpty,
      );
    });

    test('流结束冲掉未闭合的堆栈块', () {
      final filter = JvmStderrFilter();
      expect(filter.feed('java.lang.RuntimeException: x'), isEmpty);
      expect(filter.feed('    at A.b(A.java:1)'), isEmpty);
      final out = filter.flush();
      expect(out.single, contains('RuntimeException: x'));
      expect(out.single, contains('堆栈 1 行已折叠'));
    });
  });
}
