import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/platform/archive_extract.dart';

void main() {
  test('extractZipArchive 用内置解压（.whl 这类 zip 也支持）', () async {
    final dir = await Directory.systemTemp.createTemp('misa_zip_');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final archive = Archive()
      ..add(ArchiveFile('bin/java.exe', 3, [104, 105, 33]))
      ..add(ArchiveFile('Lib/site-packages/requests/__init__.py', 1, [120]));
    final bytes = ZipEncoder().encodeBytes(archive);
    final file = File('${dir.path}/payload.whl');
    await file.writeAsBytes(bytes, flush: true);

    final out = Directory('${dir.path}/out');
    await extractZipArchive(file.path, out.path);

    expect(File('${out.path}/bin/java.exe').existsSync(), isTrue);
    expect(
      File('${out.path}/Lib/site-packages/requests/__init__.py').existsSync(),
      isTrue,
    );
  });
}
