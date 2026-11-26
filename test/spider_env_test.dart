import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jar_spider/spider_env.dart';
import 'package:path/path.dart' as p;

void main() {
  test('SpiderEnv 写齐四条网盘 Cookie 通道', () async {
    final root = Directory.systemTemp.createTempSync('spider_env_test_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final cache = p.join(root.path, 'jvm_cache', 'spider');
    const quark = '__kp=quark; __pus=pus';
    const uc = '__pus=uc';
    await SpiderEnv.sync(
      spiderCacheDir: cache,
      cookies: const {'quark': quark, 'uc': uc, 'baidu': 'BDUSS=bd'},
      seed: const {'Wex_ucpan_token': 'tok', 'Wex_ucpan_device_id': 'dev'},
      tmpDir: root.path,
      dataDir: root.path,
      ext: jsonEncode({'Cloud-drive': 'tvfan/custom.txt'}),
    );

    // 1. wex 裸 cookie 文件
    expect(
      File(p.join(cache, 'files', 'TV', '.quarkcookie')).readAsStringSync(),
      quark,
    );
    expect(
      File(p.join(cache, 'files', 'TV', '.ucpancookie')).readAsStringSync(),
      uc,
    );

    // 2. SharedPreferences 种子（含 UC TV Token 与强制 Java 多线程）
    final seed = File(p.join(cache, 'shared_prefs', 'seed.txt'))
        .readAsStringSync();
    expect(seed, contains('Wex_quark_cookie\t$quark'));
    expect(seed, contains('Wex_ucpan_token\ttok'));
    expect(seed, contains('Wex_ucpan_device_id\tdev'));
    expect(seed, contains('pan.thread_proxy_mode\tjava'));

    // 3. Pizazz 临时目录（quark/uc 需三字段非空）
    final pizazz = File(
      p.join(root.path, 'tvbox-ext', 'TVBox', 'quark_cookie.txt'),
    );
    final pizazzBody = jsonDecode(pizazz.readAsStringSync()) as Map;
    expect(pizazzBody['cookie'], quark);
    expect((pizazzBody['nickname'] as String).isNotEmpty, isTrue);
    expect((pizazzBody['member_type'] as String).isNotEmpty, isTrue);

    // 4. fty Cloud-drive（默认落点 + 源 ext 声明的位置都要写）
    for (final path in [
      p.join(root.path, 'tvfan', 'Cloud-drive.txt'),
      p.join(root.path, 'tvfan', 'custom.txt'),
    ]) {
      final body = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(body['quarkCookie'], quark);
      expect(body['ucCookie'], uc);
    }
  });

  test('解绑后不残留旧 Cookie', () async {
    final root = Directory.systemTemp.createTempSync('spider_env_test_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final cache = p.join(root.path, 'jvm_cache', 'spider');
    await SpiderEnv.sync(
      spiderCacheDir: cache,
      cookies: const {'quark': 'q'},
      tmpDir: root.path,
      dataDir: root.path,
    );
    expect(
      File(p.join(root.path, 'tvfan', 'Cloud-drive.txt')).existsSync(),
      isTrue,
    );

    // 第二次同步时 quark 已解绑 → 文件/凭据都要消失
    await SpiderEnv.sync(
      spiderCacheDir: cache,
      cookies: const {},
      tmpDir: root.path,
      dataDir: root.path,
    );
    expect(
      File(p.join(cache, 'files', 'TV', '.quarkcookie')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(cache, 'shared_prefs', 'seed.txt')).readAsStringSync(),
      isNot(contains('Wex_quark_cookie')),
    );
    expect(
      File(p.join(root.path, 'tvbox-ext', 'TVBox', 'quark_cookie.txt'))
          .existsSync(),
      isFalse,
    );
    final cloud = File(p.join(root.path, 'tvfan', 'Cloud-drive.txt'));
    expect(
      (jsonDecode(cloud.readAsStringSync()) as Map).containsKey('quarkCookie'),
      isFalse,
    );
  });

  test('哔哩 / 115 落到 TVBox 站点 Cookie 通道', () async {
    final root = Directory.systemTemp.createTempSync('spider_env_test_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final cache = p.join(root.path, 'jvm_cache', 'spider');
    const bili = 'SESSDATA=bili; bili_jct=jct';
    const pan115 = 'UID=1; CID=2; SEID=3';
    await SpiderEnv.sync(
      spiderCacheDir: cache,
      cookies: const {'bili': bili, '115': pan115},
      tmpDir: root.path,
      dataDir: root.path,
    );

    // 订阅里 csp_Bili 的 ext 写的就是这个中继地址，内容必须是裸 Cookie 串。
    expect(
      File(p.join(root.path, 'TVBox', 'bili_cookie.txt')).readAsStringSync(),
      bili,
    );
    expect(
      File(p.join(root.path, 'TVBox', '115.txt')).readAsStringSync(),
      pan115,
    );
    // wex 系 / prefs 种子也同步一份，覆盖读 prefs 的 jar。
    expect(
      File(p.join(cache, 'files', 'TV', '.115cookie')).readAsStringSync(),
      pan115,
    );
    final seed = File(p.join(cache, 'shared_prefs', 'seed.txt'))
        .readAsStringSync();
    expect(seed, contains('Wex_115_cookie\t$pan115'));

    // 解绑后写入空文件（不是删除）：中继对缺失文件回 404 + 中文正文，
    // 蜘蛛会把那段正文当 Cookie 用，反而更糟。
    await SpiderEnv.sync(
      spiderCacheDir: cache,
      cookies: const {},
      tmpDir: root.path,
      dataDir: root.path,
    );
    expect(
      File(p.join(root.path, 'TVBox', 'bili_cookie.txt')).readAsStringSync(),
      '',
    );
    expect(File(p.join(root.path, 'TVBox', '115.txt')).readAsStringSync(), '');
    expect(
      File(p.join(cache, 'files', 'TV', '.115cookie')).existsSync(),
      isFalse,
    );
  });
}
