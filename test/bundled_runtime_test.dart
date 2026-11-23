import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/bundled_runtime.dart';
import 'package:path/path.dart' as p;

void main() {
  group('BundledRuntime', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bundled_rt_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Directory makeBundled(String name, Map<String, String> files) {
      final dir = Directory(p.join(tmp.path, 'runtime', name));
      dir.createSync(recursive: true);
      files.forEach((rel, content) {
        final f = File(p.join(dir.path, rel));
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(content);
      });
      return dir;
    }

    test('随包目录不存在时 locate 返回 null', () {
      expect(BundledRuntime.locate('jre', exeDir: tmp.path), isNull);
    });

    test('locate 命中 <exe>/runtime/<name>', () {
      makeBundled('jre', {'bin/java.exe': 'x'});
      final dir = BundledRuntime.locate('jre', exeDir: tmp.path);
      expect(dir, isNotNull);
      expect(File(p.join(dir!.path, 'bin/java.exe')).existsSync(), isTrue);
    });

    test('seed 把嵌套目录整体复制到目标', () {
      makeBundled('jre', {
        'bin/java.exe': 'java',
        'legal/java.base/LICENSE': 'GPL',
      });
      final target = Directory(p.join(tmp.path, 'out', 'jre'));
      expect(BundledRuntime.seed('jre', target, exeDir: tmp.path), isTrue);
      expect(File(p.join(target.path, 'bin/java.exe')).readAsStringSync(), 'java');
      expect(File(p.join(target.path, 'legal/java.base/LICENSE')).readAsStringSync(), 'GPL');
    });

    test('目标已存在文件时不覆盖、直接返回 true', () {
      makeBundled('jre', {'bin/java.exe': 'new'});
      final target = Directory(p.join(tmp.path, 'out', 'jre'));
      target.createSync(recursive: true);
      File(p.join(target.path, 'keep.txt')).writeAsStringSync('mine');
      expect(BundledRuntime.seed('jre', target, exeDir: tmp.path), isTrue);
      expect(File(p.join(target.path, 'keep.txt')).existsSync(), isTrue);
      expect(File(p.join(target.path, 'bin/java.exe')).existsSync(), isFalse);
    });

    test('随包缺失时 seed 返回 false（调用方回落到下载）', () {
      final target = Directory(p.join(tmp.path, 'out', 'python'));
      expect(BundledRuntime.seed('python', target, exeDir: tmp.path), isFalse);
    });
  });
}
