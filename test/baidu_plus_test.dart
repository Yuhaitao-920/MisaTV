import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/drive/baidu_native.dart';

/// CAT 系壳（`csp_MoggCAT` 的 `d盘` 线路）的 `++` 描述串。
///
/// 实测样本（P123 / 木偶4K / 傻样）：
///   67698425202++1100830236519++773303697958675++A.Record...mp4++ZCBLkVQK8qM2eKG…
///   18620956731++1100830236519++233961913384010++The.Madison...mkv++ZCBLkVQK8qM2eKG…
///
/// 段序：uk ++ shareId ++ fs_id ++ name ++ seKey
/// 第 5 段 seKey 是必须的（不带时 share/list 回 errno=9019 need verify）。
void main() {
  group('百度 ++ 描述串', () {
    test('五段：解析出 uk / shareId / fs_id / name / seKey', () {
      // ★ 段序：shareId ++ uk ++ fs_id ++ name ++ seKey
      const raw =
          '67698425202'
          '++1100830236519'
          '++773303697958675'
          '++A.Record.of.a.Mortals.Journey.to.Immortality.S01E01.2020.2160p.mp4'
          '++ZCBLkVQK8qM2eKGaBcDeF=';
      expect(looksLikeBaiduShare(raw), isTrue);
      final f = extractBaiduSharedFile(raw);
      expect(f, isNotNull);
      expect(f!.shareId, '67698425202');
      expect(f.uk, '1100830236519');
      expect(f.fsid, '773303697958675');
      expect(f.sekey, 'ZCBLkVQK8qM2eKGaBcDeF=');
      expect(f.name, contains('A.Record.of.a.Mortals.Journey'));
    });

    test('四段（缺 seKey）不识别——交回 jar 兜底，不白等网络', () {
      const raw = '67698425202++1100830236519++773303697958675++name.mp4';
      expect(extractBaiduSharedFile(raw), isNull);
      expect(looksLikeBaiduShare(raw), isFalse);
    });

    test('前三位必须是纯数字', () {
      const bad = 'abc++1100830236519++773303697958675++n.mp4++sekey=';
      expect(extractBaiduSharedFile(bad), isNull);
    });

    test('不误吃夸克的 ~~ 串', () {
      const quark =
          'f0fa80322caa4b579c0f89cb46004ffc'
          '~~13db5508613442d0fc3c3062d78986a4'
          '~~803858da27e1~~name.mp4';
      expect(extractBaiduSharedFile(quark), isNull);
      expect(looksLikeBaiduShare(quark), isFalse);
    });

    test('URL 不参与', () {
      expect(extractBaiduSharedFile('https://pan.baidu.com/s/1abc'), isNull);
    });
  });
}
