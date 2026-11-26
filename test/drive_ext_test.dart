import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/drive/drive_ext.dart';

void main() {
  group('enrichSpiderExt', () {
    test('注入 provider 键（含 115 / bili）', () {
      final out = enrichSpiderExt(jsonEncode({'n': '哔哩合集'}), const {
        '115': 'UID=1',
        'bili': 'SESSDATA=x',
      });
      final decoded = jsonDecode(out) as Map;
      expect(decoded['n'], '哔哩合集');
      expect(decoded['115'], 'UID=1');
      expect(decoded['bili'], 'SESSDATA=x');
    });

    test('空 Cookie 不写入，避免把 ext 里的原值覆盖成空串', () {
      final out = enrichSpiderExt(jsonEncode({'quark': 'keep-me'}), const {
        'quark': '  ',
        'bili': '',
      });
      final decoded = jsonDecode(out) as Map;
      expect(decoded['quark'], 'keep-me');
      expect(decoded.containsKey('bili'), isFalse);
    });

    test('非 JSON ext 原样返回', () {
      expect(enrichSpiderExt('not json', const {'115': 'x'}), 'not json');
      expect(enrichSpiderExt('', const {'115': 'x'}), '');
    });
  });
}
