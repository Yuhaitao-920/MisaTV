import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/models/source_health.dart';
import 'package:kniephos/models/vod.dart';
import 'package:kniephos/services/play_result_parser.dart';

SourceBean _site({int type = 3, String ext = ''}) =>
    SourceBean(key: 'k', name: '测试源', type: type, api: 'csp_Test', ext: ext);

void main() {
  group('最终播放地址校验', () {
    test('协议地址与本地绝对路径放行', () {
      expect(isPlayableMediaUrl('https://cdn.example.com/a.m3u8'), isTrue);
      expect(isPlayableMediaUrl('rtmp://live.example.com/a'), isTrue);
      expect(isPlayableMediaUrl(r'D:\films\a.mkv'), isTrue);
      expect(isPlayableMediaUrl('file:///D:/films/a.mkv'), isTrue);
    });

    test('空地址、占位视频、源内参数、相对路径被拒绝', () {
      expect(isPlayableMediaUrl('   '), isFalse);
      expect(isPlayableMediaUrl('/mizhicdn/video/error.mp4'), isFalse);
      expect(isPlayableMediaUrl('https://cdn.example.com/error.mp4'), isFalse);
      expect(
        isPlayableMediaUrl('parse_api=https://a.com&url=b&token=1'),
        isFalse,
      );
      expect(isPlayableMediaUrl('第1集\$https://a.com/1.mp4'), isFalse);
      expect(isPlayableMediaUrl('/play/segment.ts'), isFalse);
    });
  });

  group('蜘蛛播放结果归一化', () {
    test('正常直链可播', () {
      final play = normalizeSpiderPlay(
        '{"parse":0,"url":"https://a.com/1.m3u8"}',
        'flag',
      );
      expect(play.playable, isTrue);
      expect(play.url, 'https://a.com/1.m3u8');
    });

    test('parse:0 但地址是选集参数时不给播放器', () {
      final play = normalizeSpiderPlay(
        '{"parse":0,"url":"parse_api=x&url=y&token=1"}',
        'flag',
      );
      expect(play.playable, isFalse);
      expect(play.url, isEmpty);
      expect(play.message, isNotEmpty);
    });

    test('错误占位视频被拒绝', () {
      final play = normalizeSpiderPlay(
        '{"parse":0,"url":"https://a.com/mizhicdn/video/error.mp4"}',
        'flag',
      );
      expect(play.playable, isFalse);
    });

    test('磁力链接保留为外部链接，交给内置 BT 引擎', () {
      const magnet =
          'magnet:?xt=urn:btih:0a4f25522548cd938ac63385e1803377267312ee&dn=test';
      final play = normalizeSpiderPlay('{"parse":0,"url":"$magnet"}', 'flag');
      expect(play.playable, isFalse);
      expect(play.url, isEmpty);
      expect(play.externalLink, magnet);
      expect(play.message, contains('磁力'));
    });

    test('蜘蛛声明 parse 也优先识别磁力链接', () {
      const magnet =
          'magnet:?xt=urn:btih:bfe6f2023fcc74a9be606b30e3a89ed0a4a3d999';
      final play = normalizeSpiderPlay('{"parse":1,"url":"$magnet"}', 'flag');
      expect(play.externalLink, magnet);
      expect(play.parse, 0);
    });

    test('parse=1 保留 header，网页嗅探要用源内 UA / Referer', () {
      final play = normalizeSpiderPlay(
        '{"parse":1,"url":"https://www.pandalive.co.kr/play/1",'
            '"header":{"User-Agent":"UA","Referer":"https://www.pandalive.co.kr/"}}',
        'IVS',
      );
      expect(play.parse, 1);
      expect(play.url, 'https://www.pandalive.co.kr/play/1');
      expect(play.headers['User-Agent'], 'UA');
      expect(play.headers['Referer'], 'https://www.pandalive.co.kr/');
      expect(play.message, contains('第三方解析'));
    });
  });

  group('源体检分类', () {
    test('首页有条目 → ok-content', () {
      final health = SourceHealth.fromHome(
        _site(type: 1),
        CmsResult(
          items: const [VodItem(id: '1', name: '影片')],
        ),
      );
      expect(health.status, 'ok-content');
      expect(health.ok, isTrue);
      expect(health.items, 1);
    });

    test('首页回退算有内容', () {
      final health = SourceHealth.fromHome(
        _site(type: 1),
        CmsResult(
          items: const [VodItem(id: '1', name: '影片')],
          classes: const [SortClass(id: '1', name: '电影')],
          homeFallback: true,
        ),
      );
      expect(health.status, 'ok-content');
      expect(health.message, contains('回退'));
    });

    test('只有分类 → ok-classes', () {
      final health = SourceHealth.fromHome(
        _site(type: 1),
        CmsResult(
          classes: const [SortClass(id: '1', name: '电影')],
        ),
      );
      expect(health.status, 'ok-classes');
      expect(health.ok, isTrue);
    });

    test('蜘蛛空主页且 ext 未配置 → needs-ext', () {
      final health = SourceHealth.fromHome(_site(), const CmsResult());
      expect(health.status, 'needs-ext');
      expect(health.needsExt, isTrue);
    });

    test('蜘蛛空主页但已有 ext → empty', () {
      final health = SourceHealth.fromHome(
        _site(ext: '{"siteUrl":"https://a.com"}'),
        const CmsResult(),
      );
      expect(health.status, 'empty');
      expect(health.ok, isFalse);
    });

    test('异常 → error', () {
      final health = SourceHealth.failure(_site(), SourceException('JAR 加载失败'));
      expect(health.status, 'error');
      expect(health.message, 'JAR 加载失败');
    });
  });
}
