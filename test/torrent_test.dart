import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/torrent/aria2_sidecar.dart';
import 'package:kniephos/services/torrent/magnet.dart';

void main() {
  final hash = List<String>.filled(40, 'a').join();
  final base32Zero = List<String>.filled(32, 'A').join();
  final invalidBase32 = List<String>.filled(32, '1').join();

  group('infoHash 归一', () {
    test('40 hex 转小写', () {
      expect(
        normalizeBtih('ABCDEF0123456789ABCDEF0123456789ABCDEF01'),
        'abcdef0123456789abcdef0123456789abcdef01',
      );
    });

    test('32 base32 → 40 hex', () {
      expect(normalizeBtih(base32Zero), List<String>.filled(40, '0').join());
    });

    test('非法长度/字符返回空串', () {
      expect(normalizeBtih('abc'), '');
      expect(normalizeBtih(invalidBase32), '');
    });
  });

  group('magnet 解析', () {
    test('xt / dn / tr 全解析', () {
      final info = parseMagnet(
        'magnet:?xt=urn:btih:${hash.toUpperCase()}&dn=${Uri.encodeComponent('流浪地球 2160p')}'
        '&tr=${Uri.encodeComponent('udp://tr.test:1337/announce')}&tr=${Uri.encodeComponent('https://tr2/announce')}',
      );
      expect(info, isNotNull);
      expect(info!.infoHash, hash);
      expect(info.displayName, '流浪地球 2160p');
      expect(info.trackers.length, 2);
      expect(info.trackers.first, 'udp://tr.test:1337/announce');
    });

    test('多 xt 只认第一个可用的 btih', () {
      final info = parseMagnet('magnet:?xt=urn:sha1:xxxx&xt=urn:btih:$hash');
      expect(info, isNotNull);
      expect(info!.infoHash, hash);
    });

    test('非 magnet / 缺 btih 返回 null', () {
      expect(parseMagnet('https://x/a.mp4'), isNull);
      expect(parseMagnet('magnet:?dn=x'), isNull);
    });
  });

  group('tracker 追加', () {
    test('只追加缺失项且不重复', () {
      final base =
          'magnet:?xt=urn:btih:$hash&tr=${Uri.encodeComponent(publicTrackers.first)}';
      final added = withTrackers(base);
      expect(
        added.contains('tr=${Uri.encodeComponent(publicTrackers.first)}'),
        isTrue,
      );
      for (final tracker in publicTrackers.skip(1)) {
        expect(added.contains(Uri.encodeComponent(tracker)), isTrue);
      }
      expect(parseMagnet(added)!.trackers.length, publicTrackers.length);
      // 二次追加不增长。
      expect(withTrackers(added), added);
      // 非法磁力原样返回。
      expect(withTrackers('not-magnet'), 'not-magnet');
    });
  });

  group('种子文件', () {
    test('偏移按顺序累加', () {
      final files = withTorrentOffsets([
        (index: 1, path: '/a/01.mkv', length: 100),
        (index: 2, path: '/a/02.mkv', length: 200),
        (index: 3, path: '/a/poster.jpg', length: 5),
      ]);
      expect(files.map((f) => f.offset).toList(), [0, 100, 300]);
    });

    test('扩展名与正片白名单', () {
      expect(extOf('C:\\a\\b.MP4'), 'mp4');
      expect(extOf('.gitignore'), '');
      expect(extOf('noext'), '');
      expect(isVideoFile('/x/y.rmvb'), isTrue);
      expect(isVideoFile('/x/y.srt'), isFalse);
    });

    test('选片：集名线索优先，否则体积最大', () {
      final files = withTorrentOffsets([
        (index: 1, path: '/show/Show.E01.mkv', length: 900),
        (index: 2, path: '/show/Show.E03.mkv', length: 600),
        (index: 3, path: '/show/Show.E02.mkv', length: 1200),
        (index: 4, path: '/show/notes.txt', length: 9999),
      ]);
      expect(pickVideoFile(files, preferName: 'E03')!.index, 2);
      expect(pickVideoFile(files)!.index, 3);
      expect(
        pickVideoFile(
          withTorrentOffsets([(index: 1, path: '/a.srt', length: 10)]),
        ),
        isNull,
      );
    });

    test('内置可播判定', () {
      expect(webPlayBlockReason('a.mp4'), isNull);
      expect(webPlayBlockReason('a.webm'), isNull);
      expect(webPlayBlockReason('a.mkv'), contains('MKV'));
      expect(webPlayBlockReason('movie.HEVC.mp4'), contains('HEVC'));
      expect(webPlayBlockReason('movie_x265_1080p.mp4'), contains('HEVC'));
      expect(addUriOptions('/tmp/bt')['dir'], '/tmp/bt');
      expect(addUriOptions('/tmp/bt')['pause-metadata'], 'true');
    });
  });

  group('aria2 协议', () {
    test('followedBy 兼容数组与字符串', () {
      expect(firstFollowedBy(['gid-1']), 'gid-1');
      expect(firstFollowedBy('gid-2'), 'gid-2');
      expect(firstFollowedBy(null), '');
      expect(firstFollowedBy(<Object?>[]), '');
    });

    test('命令行关键参数', () {
      final args = aria2Args(
        port: 6810,
        secret: 'sec',
        dir: 'C:\\bt',
        stopWithPid: 1234,
      );
      expect(args.contains('--enable-rpc=true'), isTrue);
      expect(args.contains('--rpc-listen-port=6810'), isTrue);
      expect(args.contains('--rpc-secret=sec'), isTrue);
      expect(args.contains('--dir=C:\\bt'), isTrue);
      expect(args.contains('--bt-prioritize-piece=head=8M,tail=8M'), isTrue);
      expect(args.contains('--stop-with-process=1234'), isTrue);
      expect(
        aria2Args(
          port: 1,
          secret: 's',
          dir: 'd',
        ).any((a) => a.startsWith('--stop-with-process')),
        isFalse,
      );
    });
  });

  group('piece 门控', () {
    test('MSB-first 位序', () {
      expect(isPieceSet('80', 0), isTrue);
      expect(isPieceSet('80', 1), isFalse);
      expect(isPieceSet('01', 7), isTrue);
      expect(isPieceSet('FF', 7), isTrue);
      expect(isPieceSet('', 0), isFalse);
      expect(isPieceSet('80', 8), isFalse);
      expect(isPieceSet('80', -1), isFalse);
    });

    test('区间判定', () {
      expect(isPieceRangeSet('FF', 0, 7), isTrue);
      expect(isPieceRangeSet('FF', 0, 8), isFalse);
      expect(isPieceRangeSet('80', 0, 0), isTrue);
      expect(isPieceRangeSet('80', 1, 2), isFalse);
      expect(isPieceRangeSet('00', 5, 4), isTrue);
    });

    test('文件字节区间 → torrent piece', () {
      final range = piecesForByteRange(1024, 1024, 0, 2047);
      expect(range.first, 1);
      expect(range.last, 2);
      expect(piecesForByteRange(0, 0, 10, 20).first, 0);
    });
  });

  group('路由与地址', () {
    test('parseBtRoute 合法/非法', () {
      expect(parseBtRoute('/bt/$hash/3')!.fileIndex, 3);
      expect(parseBtRoute('/bt/${hash.toUpperCase()}/1')!.infoHash, hash);
      expect(parseBtRoute('/bt/$hash/0'), isNull);
      expect(parseBtRoute('/bt/short/1'), isNull);
      expect(parseBtRoute('/bt/$hash/1/extra'), isNull);
    });

    test('btStreamUrl 去尾斜杠拼接', () {
      expect(
        btStreamUrl('http://127.0.0.1:9978/', hash, 2),
        'http://127.0.0.1:9978/bt/$hash/2',
      );
      expect(
        btStreamUrl('http://127.0.0.1:9978', hash, 2),
        'http://127.0.0.1:9978/bt/$hash/2',
      );
    });

    test('magnetKey 与首段门控常量', () {
      expect(magnetKey('magnet:?xt=urn:btih:$hash'), hash);
      expect(magnetKey('bad'), '');
      expect(btHeadGateBytes, 512 * 1024);
    });
  });
}
