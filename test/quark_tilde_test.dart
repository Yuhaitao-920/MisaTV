import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/drive/quark_native.dart';

/// CAT 系壳（`csp_MoggCAT` 等）的夸克线路返回的 `~~` 串。
///
/// 实测样本（P123 / 木偶4K 的 `quark#1`）：
///   f0fa80322caa4b579c0f89cb46004ffc~~13db5508613442d0fc3c3062d78986a4
///     ~~803858da27e1~~NmW+8Wgx3gA9eJotbpYaKEKf1oK9Bdakc/8gMi…
///
/// 段序：fid ~~ share_fid_token ~~ pwd_id ~~ name
void main() {
  group('夸克 ~~ 描述串', () {
    test('四段：解析出 fid / token / pwdId / name', () {
      const raw =
          'f0fa80322caa4b579c0f89cb46004ffc'
          '~~13db5508613442d0fc3c3062d78986a4'
          '~~803858da27e1'
          '~~NmW+8Wgx3gA9eJotbpYaKEKf1oK9Bdakc/8gMi';
      final ref = extractQuarkShare(raw, flag: 'quark#1');
      expect(ref, isNotNull);
      expect(ref!.fileId, 'f0fa80322caa4b579c0f89cb46004ffc');
      expect(ref.fileToken, '13db5508613442d0fc3c3062d78986a4');
      expect(ref.pwdId, '803858da27e1');
      expect(ref.name, startsWith('NmW+8Wgx3gA9eJotbpYaKEKf1oK9Bdakc'));
    });

    test('只有线路名是夸克时才解释（避免误吃百度 ++ 串）', () {
      const raw =
          'f0fa80322caa4b579c0f89cb46004ffc'
          '~~13db5508613442d0fc3c3062d78986a4'
          '~~803858da27e1~~name.mp4';
      expect(extractQuarkShare(raw, flag: 'd盘#1'), isNull);
      expect(extractQuarkShare(raw, flag: '百度原画'), isNull);
      expect(extractQuarkShare(raw, flag: '夸克原画'), isNotNull);
      expect(extractQuarkShare(raw, flag: 'quark#1'), isNotNull);
    });

    test('段数不足 / 段格式不对 → null，不误判', () {
      expect(extractQuarkShare('abc~~def', flag: 'quark'), isNull);
      expect(
        extractQuarkShare('short~~short~~short~~n', flag: 'quark'),
        isNull,
      );
      // 百度 ++ 串不能当夸克
      expect(
        extractQuarkShare(
          '67698425202++1100830236519++773303697958675++a.mkv',
          flag: 'quark',
        ),
        isNull,
      );
      // URL 不参与
      expect(
        extractQuarkShare(
          'https://pan.quark.cn/s/abcdef',
          flag: 'quark',
        ),
        isNotNull, // 走链接分支
      );
    });
  });
  group('文件名含分隔符', () {
    test('~~ 出现在文件名里也不截断', () {
      const raw =
          'f0fa80322caa4b579c0f89cb46004ffc'
          '~~13db5508613442d0fc3c3062d78986a4'
          '~~803858da27e1'
          '~~a~~b.mkv';
      final ref = extractQuarkShare(raw, flag: 'quark#1');
      expect(ref, isNotNull);
      expect(ref!.fileId, 'f0fa80322caa4b579c0f89cb46004ffc');
      expect(ref.pwdId, '803858da27e1');
      expect(ref.name, 'a~~b.mkv');
    });
  });
}