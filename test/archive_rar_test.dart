import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/subtitle/archive.dart';
import 'package:kniephos/services/subtitle/subtitle_from_bytes.dart';
import 'package:kniephos/services/subtitle/pick_entry.dart';
import 'package:kniephos/services/subtitle/subtitle_models.dart';
import 'package:kniephos/services/subtitle/subtitle_package_store.dart';

/// RAR / 7Z / BZ2 解包（koni_archive，纯 Dart）。
///
/// 背景：assrt 上大量字幕以 `.rar` 发布 —— 实测 id=733904
/// 「人性本兽 Animals 2026」整包是 rar，内含 4 个 srt（简中/eng/SDH/繁中）。
/// 早期实现直接抛「暂不支持解压 RAR 压缩包，请手动解压后选择字幕文件」，
/// 对用户是死路。
///
/// 这里用真实样本（`G:\_pkg.rar`，161.9 KB）验证端到端；
/// 样本缺失时跳过需要网络的部分，只跑不依赖样本的契约测试。
void main() {
  const sample = r'G:\_pkg.rar';

  group('归档识别', () {
    test('RAR / 7Z / BZ2 魔数', () {
      expect(
        detectArchiveKind(<int>[0x52, 0x61, 0x72, 0x21, 0, 0]),
        ArchiveKind.rar,
      );
      expect(
        detectArchiveKind(<int>[0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]),
        ArchiveKind.sevenZip,
      );
      expect(detectArchiveKind(<int>[0x42, 0x5a, 0x68, 0]), ArchiveKind.bz2);
    });

    test('needsKoni：zip/gz 走同步，其余走异步', () {
      expect(ArchiveKind.zip.needsKoni, isFalse);
      expect(ArchiveKind.gz.needsKoni, isFalse);
      expect(ArchiveKind.rar.needsKoni, isTrue);
      expect(ArchiveKind.sevenZip.needsKoni, isTrue);
      expect(ArchiveKind.bz2.needsKoni, isTrue);
    });

    test('supported 全部为真（不再有「明确不支持」）', () {
      for (final k in ArchiveKind.values) {
        expect(k.supported, isTrue, reason: '${k.label} 应可解');
      }
    });

    test('同步入口遇到 RAR 明确提示改走异步（不静默返回空）', () {
      final rar = <int>[0x52, 0x61, 0x72, 0x21, 0, 0];
      expect(
        () => extractArchiveEntries(rar),
        throwsA(
          isA<SubtitleException>().having(
            (e) => e.message,
            'message',
            contains('需要异步解包'),
          ),
        ),
      );
    });
  });

  group('真实 RAR 样本', () {
    test('能解出 4 个 srt 并挑出简中', () async {
      final f = File(sample);
      if (!f.existsSync()) {
        // ignore: avoid_print
        print('样本缺失，跳过：$sample');
        return;
      }
      final bytes = f.readAsBytesSync();
      final entries = await extractArchiveEntriesAsync(bytes);
      expect(entries.length, 4);
      expect(
        entries.every((e) => e.name.toLowerCase().endsWith('.srt')),
        isTrue,
      );

      // 走完整链路：解包 → 按视频名挑条目 → 解码
      final file = await subtitleFromBytesAsync(
        bytes,
        fileName: '人性本兽 Animals (2026).rar',
        videoName: 'Animals.2026.2160p.WEB.h265.mkv',
      );
      // ignore: avoid_print
      print('挑中：${file.name}  ${file.text.length} 字符');
      expect(file.name.toLowerCase().endsWith('.srt'), isTrue);
      expect(file.text, contains('-->'), reason: '应是 SRT 时间码');
      expect(file.text.length, greaterThan(1000));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('同步版对同一个 RAR 会抛（契约：必须用 async）', () {
      final f = File(sample);
      if (!f.existsSync()) return;
      final bytes = f.readAsBytesSync();
      expect(
        () => subtitleFromBytes(bytes, fileName: 'x.rar'),
        throwsA(isA<SubtitleException>()),
      );
    });
  });
  group('多字幕选择', () {
    test('pickFirst:false → 抛 SubtitleChoicesException，候选按中文优先排序', () async {
      final f = File(sample);
      if (!f.existsSync()) return;
      Object? caught;
      try {
        await subtitleFromBytesAsync(
          f.readAsBytesSync(),
          fileName: '人性本兽 Animals (2026).rar',
          videoName: 'Animals.2026.2160p.WEB.h265.mkv',
          pickFirst: false,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<SubtitleChoicesException>());
      final choices = (caught as SubtitleChoicesException).choices;
      expect(choices.length, greaterThan(1), reason: '包里 4 条，应全部列出');
      // 第一条必须是简中（语言优先级），不能是 SDH
      expect(choices.first.name, contains('简中'));
      expect(
        choices.any((c) => c.name.toLowerCase().contains('sdh')),
        isTrue,
        reason: 'SDH 仍在候选里，只是排在后面',
      );
      expect(choices.every((c) => c.text.contains('-->')), isTrue);
    });

    test('pickFirst:true → 自动挑一条，且优先中文（不再是 SDH）', () async {
      final f = File(sample);
      if (!f.existsSync()) return;
      final file = await subtitleFromBytesAsync(
        f.readAsBytesSync(),
        fileName: 'x.rar',
        videoName: 'Animals.2026.2160p.WEB.h265.mkv',
      );
      expect(file.name, contains('简中'));
      expect(file.text, contains('-->'));
    });
  });
  group('字幕包缓存（第二次点击不再下载）', () {
    test('写完能读回，且新实例（模拟重启）也能命中', () async {
      final f = File(sample);
      if (!f.existsSync()) return;
      configurePackageStore(r'G:\_t_pkgcache');

      const key = 'assrt|733904';
      final raw = f.readAsBytesSync();
      final entries = await extractArchiveEntriesAsync(raw);
      final choices = <SubtitleChoice>[
        for (final e in entries)
          SubtitleChoice(
            name: e.name,
            format: extOf(e.name),
            text: String.fromCharCodes(e.bytes),
          ),
      ];
      expect(choices.length, 4);

      writePackageCache(key, _enc(choices));
      final back = readPackageCache(key);
      expect(back, isNotNull);
      final decoded = _dec(back!);
      expect(decoded.length, 4);
      expect(decoded.first.name, contains('简中'), reason: '顺序要保住');
      expect(decoded.every((c) => c.text.contains('-->')), isTrue);

      Directory(r'G:\_t_pkgcache').deleteSync(recursive: true);
    });
  });
}

String _enc(List<SubtitleChoice> list) => '[${list.map((c) => '{"n":"${c.name}","f":"${c.format}","t":"${c.text.replaceAll('"', r'\"').replaceAll('\n', r'\n')}"}').join(',')}]';

List<SubtitleChoice> _dec(String raw) {
  final out = <SubtitleChoice>[];
  final re = RegExp(r'\{"n":"(.*?)","f":"(.*?)","t":"(.*?)"\}', dotAll: true);
  for (final m in re.allMatches(raw)) {
    out.add(SubtitleChoice(
      name: m.group(1)!,
      format: m.group(2)!,
      text: m.group(3)!.replaceAll(r'\n', '\n').replaceAll(r'\"', '"'),
    ));
  }
  return out;
}