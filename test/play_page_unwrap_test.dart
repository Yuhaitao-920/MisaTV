import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/play_page_unwrap.dart';

void main() {
  group('PlayPageUnwrap', () {
    test('识别云播播放页/分享页', () {
      expect(
        PlayPageUnwrap.needsUnwrap('https://hn.bfvvs.com/play/dL9YVj4e'),
        isTrue,
      );
      expect(
        PlayPageUnwrap.needsUnwrap(
          'https://vodcnd17.ky32e.com/share/Ho2ezRYGZn',
        ),
        isTrue,
      );
      expect(
        PlayPageUnwrap.needsUnwrap(
          'https://hn.bfvvs.com/play/dL9YVj4e/index.m3u8',
        ),
        isFalse,
      );
      expect(
        PlayPageUnwrap.needsUnwrap('https://cdn.example.com/a.mp4'),
        isFalse,
      );
      expect(
        PlayPageUnwrap.needsUnwrap('http://127.0.0.1:9978/proxy?do=live'),
        isFalse,
      );
      // 网盘 CDN 直链没有扩展名，但绝不能按播放页抓取（会拉整集文件并超时）。
      expect(
        PlayPageUnwrap.needsUnwrap(
          'https://dl-pc-zb.drive.quark.cn/sLBEEPqR/2360212341/'
          '380bdd8455104bdfbc1a049e9d84a07d6afd082a/'
          '6afd082a26e80e6f47c642358e8c849bd8bc6c6f?auth_key=1',
        ),
        isFalse,
      );
      expect(
        PlayPageUnwrap.needsUnwrap(
          'https://drive.uc.cn/s/0123456789abcdef0123456789abcdef',
        ),
        isFalse,
      );
      expect(
        PlayPageUnwrap.needsUnwrap(
          'https://d.pcs.baidu.com/file/abc123?fid=1&sign=1',
        ),
        isFalse,
      );
    });

    test('提取 const vid 的绝对直链', () {
      const html = """
      <script>
      const vid = 'https://hn.bfvvs.com/play/dL9YVj4e/index.m3u8';
      </script>
      """;
      expect(
        PlayPageUnwrap.extractMediaUrl(
          html,
          'https://hn.bfvvs.com/play/dL9YVj4e',
        ),
        'https://hn.bfvvs.com/play/dL9YVj4e/index.m3u8',
      );
    });

    test('提取 var main 的相对清单并补全域名', () {
      const html =
          '<script>var main = "/20260724/q6oju1DY/index.m3u8";</script>';
      expect(
        PlayPageUnwrap.extractMediaUrl(
          html,
          'https://vodcnd16.0jtv2.com/share/WgtdMnoieh',
        ),
        'https://vodcnd16.0jtv2.com/20260724/q6oju1DY/index.m3u8',
      );
    });

    test('提取转义斜杠的 main 与签名参数', () {
      const html =
          r'<script>var main = "\/20261021\/13873_29bdda88\/index.m3u8?sign=abc";</script>';
      expect(
        PlayPageUnwrap.extractMediaUrl(
          html,
          'https://svip.ryiplay18.com/share/827cf4bc2f28f73e24c151cad3be7567',
        ),
        'https://svip.ryiplay18.com/20261021/13873_29bdda88/index.m3u8?sign=abc',
      );
    });

    test('没有 main 时退回 playlist 里的相对地址', () {
      const html =
          '<script>var playlist = \'[{"url":"/20261008/q1QuUgw8/517kb/hls/index.m3u8"}]\';</script>';
      expect(
        PlayPageUnwrap.extractMediaUrl(
          html,
          'https://vodcnd17.ky32e.com/share/Ho2ezRYGZn',
        ),
        'https://vodcnd17.ky32e.com/20261008/q1QuUgw8/517kb/hls/index.m3u8',
      );
    });

    test('图片地址（封面 / 图床模板）在打开播放器前被识别', () {
      // 真机日志里的「嗷呜橘汁」线路：源站把图床变换地址当播放地址。
      expect(
        looksLikeImageMediaUrl(
          'https://p3-heycan-sign.byteimg.com/tos-cn-i-3jr8j4ixpe/'
          'bc2147ca48a046c1b36c7e78cd542373~tplv-q356p4ooq1-image.image?rk3s=1',
        ),
        isTrue,
      );
      expect(
        looksLikeImageMediaUrl('https://cdn.example.com/poster/cover.jpg'),
        isTrue,
      );
      // 视频（含带签名的 query）不受影响。
      expect(
        looksLikeImageMediaUrl('https://cdn.example.com/a.mp4?sign=abc'),
        isFalse,
      );
      expect(
        looksLikeImageMediaUrl(
          'https://cdn.example.com/media/index.m3u8?image=1',
        ),
        isFalse,
      );
      expect(
        looksLikeImageMediaUrl('http://127.0.0.1:9978/play?url=a.mp4'),
        isFalse,
      );
    });

    test('页面里没有直链时返回 null', () {
      expect(
        PlayPageUnwrap.extractMediaUrl(
          '<html><body>404 Not Found</body></html>',
          'https://hn.bfvvs.com/play/x',
        ),
        isNull,
      );
    });
  });
  // ── 网盘 CDN 直链放行（2026-11-16 新增）────────────────────────────
  //
  // 实测依据：日志里 15 次「云播页面解析失败」间隔精确等于 10.0 秒，都发生在
  // 夸克直链 `dl-pc-zb-j.drive.quark.cn/<一长串hex>` 上。这些路径没有扩展名，
  // 命中了 `return !path.contains('.')` 兜底分支 → 每次播放白等 10 秒。
  group('网盘直链放行', () {
    test('夸克各节点都放行（后缀匹配，不写死节点名）', () {
      for (final host in [
        'dl-pc-zb.drive.quark.cn',
        'dl-pc-zb-j.drive.quark.cn',
        'dl-pc-sz.drive.quark.cn',
        'dl-pc-bj.drive.quark.cn',
        'dl-pc.drive.quark.cn',
      ]) {
        final url =
            'https://$host/Nh8lcOkA/12642123410/'
            '6b2e970ba6b844f18c0bda12873108c3/6af3759ae5ab767a2'
            '?auth_key=1795558660-18801219-752040&sp=abc&token=xyz';
        expect(
          PlayPageUnwrap.needsUnwrap(url),
          isFalse,
          reason: '$host 是网盘取流节点，不该被当播放页',
        );
      }
    });

    test('夸克 API 主机不在放行范围（后缀必须精确到 .drive.quark.cn）', () {
      // 防止有人为了省事放宽成 .quark.cn —— 那样 pan.quark.cn 分享页会被误杀。
      expect(
        PlayPageUnwrap.needsUnwrap(
          'https://drive-pc.quark.cn/1/clouddrive/file/x',
        ),
        isTrue,
      );
    });

    test('百度 PCS / 阿里 / 123 / 天翼 都放行', () {
      final cases = <String>[
        'https://d.pcs.baidu.com/file/abc123?fid=1',
        'https://c.pcs.baidu.com/file/abc123',
        'https://bj29.cn-beijing.data.aliyundrive.com/x/y',
        'https://open-api.alipan.com/x/y',
        'https://download.123pan.com/x/y',
        'https://down.189.cn/x/y',
      ];
      for (final url in cases) {
        expect(
          PlayPageUnwrap.needsUnwrap(url),
          isFalse,
          reason: '$url 是网盘取流域名',
        );
      }
    });

    test('普通云播页仍走解析（不能被误杀）', () {
      final cases = <String>[
        'https://v.qq.com/x/play/abc.html',
        'https://some-cdn.com/player/index',
        'https://example.com/share/abcdef',
        'https://example.com/vodplay/123-1-1',
      ];
      for (final url in cases) {
        expect(
          PlayPageUnwrap.needsUnwrap(url),
          isTrue,
          reason: '$url 没有扩展名且不是网盘域，应走页面解析',
        );
      }
    });
  });
  group('isDriveCdnUrl（直链超时后该不该改走壳内 /chunk）', () {
    test('夸克 CDN 各节点都算网盘直链', () {
      // 实测出现过的节点：dl-pc-zb / dl-pc-zb-j / dl-pc-sz（夸克按地域下发）。
      expect(
        PlayPageUnwrap.isDriveCdnUrl(
          'https://dl-pc-zb.drive.quark.cn/lcssf1Du/5449112341/1f63bb37',
        ),
        isTrue,
      );
      expect(
        PlayPageUnwrap.isDriveCdnUrl(
          'https://dl-pc-zb-j.drive.quark.cn/gHoEOz6E/1608112341/083185a3',
        ),
        isTrue,
      );
      expect(
        PlayPageUnwrap.isDriveCdnUrl(
          'https://dl-pc-sz.drive.quark.cn/Wis1rGaT/2331212341/c6064b9e',
        ),
        isTrue,
      );
    });

    test('UC / 百度取流域名同样识别', () {
      expect(
        PlayPageUnwrap.isDriveCdnUrl(
          'https://d.pcs.baidu.com/file/801d5bc68ieec95d1b8559fe376f79f',
        ),
        isTrue,
      );
      expect(
        PlayPageUnwrap.isDriveCdnUrl(
          'https://cdn.drive.uc.cn/some/file.mkv',
        ),
        isTrue,
      );
    });

    test('普通 CDN / 本机地址不算', () {
      for (final url in [
        'https://vodcnd17.ky32e.com/share/Ho2ezRYGZn/index.m3u8',
        'http://127.0.0.1:19980/chunk?id=f1510cb12c1a40c6&thread=4&chunk=0',
        'https://cdn.example.com/video.mkv',
        '',
        'not a url',
      ]) {
        expect(
          PlayPageUnwrap.isDriveCdnUrl(url),
          isFalse,
          reason: '不该把 $url 判成网盘直链',
        );
      }
    });
  });
}
