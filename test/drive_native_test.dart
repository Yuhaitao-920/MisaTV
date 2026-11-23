import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/drive/baidu_native.dart';
import 'package:kniephos/services/drive/uc_native.dart';

String _descriptor(String provider, Map<String, Object?> data) =>
    '$provider@${base64.encode(utf8.encode(jsonEncode(data)))}';

void main() {
  group('百度分享识别', () {
    test('分享链接：short 保留首位 1，提取码可选', () {
      final ref = extractBaiduShare(
        'https://pan.baidu.com/s/1abcDEF_xyz?pwd=ab12',
      );
      expect(ref, isNotNull);
      expect(ref!.short, '1abcDEF_xyz');
      expect(ref.pwd, 'ab12');
      // verify 接口必须去掉首位那个 `1`。
      expect(verifySurl(ref.short), 'abcDEF_xyz');
    });

    test('完整描述符直接给出免转存凭据', () {
      final text = _descriptor('baidu', <String, Object?>{
        'shareId': '123456',
        'uk': '987654',
        'fileId': '112233',
        'randsk': 'sekey',
        'name': '第6集.mp4',
      });
      expect(looksLikeBaiduShare(text), isTrue);
      final file = extractBaiduSharedFile(text);
      expect(file, isNotNull);
      expect(file!.shareId, '123456');
      expect(file.uk, '987654');
      expect(file.fsid, '112233');
      expect(file.sekey, 'sekey');
      expect(file.name, '第6集.mp4');
    });

    test('只有 surl 的播放描述 JSON 交回蜘蛛（提取码在 jar 内存里）', () {
      const text = '{"surl":"abcdefgh","name":"第6集.mp4"}';
      expect(looksLikeBaiduShare(text), isFalse);
    });

    test('do=pan 自有文件：纯数字 fs_id 才识别', () {
      expect(
        looksLikeBaiduShare(
          'http://127.0.0.1:-1/proxy?do=pan&site=baidu&fileId=1122334455',
        ),
        isTrue,
      );
      expect(
        looksLikeBaiduShare(
          'http://127.0.0.1:-1/proxy?do=pan&site=baidu&fileId=abc',
        ),
        isFalse,
      );
    });
  });

  group('UC 分享识别', () {
    test('分享链接与提取码', () {
      final ref = extractUcShare('https://drive.uc.cn/s/abcdef123?pwd=ab12');
      expect(ref, isNotNull);
      expect(ref!.pwdId, 'abcdef123');
      expect(ref.passcode, 'ab12');
      expect(looksLikeUcShare('https://drive.uc.cn/s/abcdef123'), isTrue);
    });

    test('描述符', () {
      final text = _descriptor('uc', <String, Object?>{
        'shareId': 'abcdef123',
        'fileId': 'fid-1',
        'passcode': 'ab12',
        'name': '第6集.mp4',
      });
      final ref = extractUcShare(text);
      expect(ref, isNotNull);
      expect(ref!.pwdId, 'abcdef123');
      expect(ref.fileId, 'fid-1');
      expect(ref.passcode, 'ab12');
      expect(looksLikeUcShare(text), isTrue);
    });

    test('FTY 复合集地址按结构识别，不依赖线路名', () {
      const fid = '0123456789abcdef0123456789abcdef';
      const sid = 'abcdefghij0123456789';
      const text =
          '第6集__$fid+$sid+0123456789abcdef0123456789abcdef';
      expect(extractUcShare(text, flag: 'UC网盘')?.pwdId, sid);
      expect(extractUcShare(text, flag: 'UC')?.fileId, fid);
      // 「夸克无限」线路实际会下发 UC 复合串（真机日志），必须照 UC 解析。
      expect(extractUcShare(text, flag: '夸克无限#2')?.pwdId, sid);
      expect(looksLikeUcShare(text, flag: '夸克无限#2'), isTrue);
      expect(looksLikeUcCompound(text), isTrue);
    });
  });
}
