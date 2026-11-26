import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jar_spider/jar_spider.dart';

int _skipConstantPool(Uint8List bytes) {
  final count = (bytes[8] << 8) | bytes[9];
  var i = 10;
  for (var n = 1; n < count; n++) {
    final tag = bytes[i++];
    switch (tag) {
      case 1:
        final len = (bytes[i] << 8) | bytes[i + 1];
        i += 2 + len;
      case 7:
      case 8:
      case 16:
      case 19:
      case 20:
        i += 2;
      case 15:
        i += 3;
      case 3:
      case 4:
      case 9:
      case 10:
      case 11:
      case 12:
      case 17:
      case 18:
        i += 4;
      case 5:
      case 6:
        i += 8;
        n++;
      default:
        throw StateError('非法常量池 tag $tag');
    }
  }
  return i;
}

void main() {
  late Directory temp;
  late File payload;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('kniephos_shim_');
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes('com/github/catvod/spider/MyCrypto.class', [1, 2, 3]),
      )
      ..addFile(
        ArchiveFile.bytes('com/github/catvod/spider/AwInit.class', [
          9,
          9,
          9,
          9,
        ]),
      )
      ..addFile(ArchiveFile.bytes('assets/libwex_v7.so', [7, 7, 7, 7, 7]))
      ..addFile(
        ArchiveFile.bytes('com/github/catvod/spider/ManJuAiHuoLong.class', [
          4,
          4,
        ]),
      );
    payload = File('${temp.path}/payload.r2.jar')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('补丁类覆盖原类，assets 与其余类保留，AwInit 换成带 show 的垫片', () {
    final patched = File('${temp.path}/MyCrypto.class')
      ..writeAsBytesSync([8, 8, 8]);
    final bytes = JarSpiderService.buildPayloadShim(
      payload: payload,
      patched: {'com/github/catvod/spider/MyCrypto.class': patched},
    );
    expect(bytes, isNotNull);

    final out = ZipDecoder().decodeBytes(bytes!);
    final files = {for (final f in out.files) f.name: f};
    expect(files.keys, contains('assets/libwex_v7.so'));
    expect(
      files.keys,
      contains('com/github/catvod/spider/ManJuAiHuoLong.class'),
    );
    expect(files['com/github/catvod/spider/MyCrypto.class']!.readBytes(), [
      8,
      8,
      8,
    ]);

    final awInit = files['com/github/catvod/spider/AwInit.class']!.readBytes()!;
    expect(awInit.length, greaterThan(100));
    expect(
      [awInit[0], awInit[1], awInit[2], awInit[3]],
      [0xca, 0xfe, 0xba, 0xbe],
    );
    final latin = String.fromCharCodes(awInit);
    expect(latin, contains('show'));
    expect(latin, contains('(Ljava/lang/String;)V'));

    // 常量池能完整走完，且紧跟着的 access_flags 是 public super。
    final body = _skipConstantPool(awInit);
    expect((awInit[body] << 8) | awInit[body + 1], 0x0021);
  });

  test('嗷呜 shim 排除载荷自带的 MyCrypto，改用 Java 影子类', () {
    final patched = File('${temp.path}/MyCrypto.class')
      ..writeAsBytesSync([8, 8, 8]);
    final bytes = JarSpiderService.buildPayloadShim(
      payload: payload,
      patched: {'com/github/catvod/spider/MyCrypto.class': patched},
      excludeAowuCrypto: true,
    );
    expect(bytes, isNotNull);
    final out = ZipDecoder().decodeBytes(bytes!);
    final names = out.files.map((f) => f.name).toSet();
    expect(names, isNot(contains('com/github/catvod/spider/MyCrypto.class')));
    expect(names, contains('com/github/catvod/spider/ManJuAiHuoLong.class'));
  });

  test('payload 里没有 AwInit 时也会补上垫片', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('com/github/catvod/spider/Other.class', [1]));
    payload.writeAsBytesSync(ZipEncoder().encode(archive));
    final bytes = JarSpiderService.buildPayloadShim(
      payload: payload,
      patched: {},
    );
    expect(bytes, isNotNull);
    final out = ZipDecoder().decodeBytes(bytes!);
    expect(
      out.files.any((f) => f.name == 'com/github/catvod/spider/AwInit.class'),
      isTrue,
    );
  });
}
