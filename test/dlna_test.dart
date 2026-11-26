import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/dlna/dlna.dart';
import 'package:kniephos/services/dlna/dlna_service.dart';

void main() {
  group('SSDP', () {
    test('M-SEARCH 报文包含目标与 MX', () {
      final request = buildSearchRequest(mxSeconds: 3);
      expect(request.startsWith('M-SEARCH * HTTP/1.1\r\n'), isTrue);
      expect(request.contains('HOST: 239.255.255.250:1900\r\n'), isTrue);
      expect(request.contains('ST: $rendererTarget\r\n'), isTrue);
      expect(request.contains('MX: 3\r\n'), isTrue);
    });

    test('解析 200 应答与 NOTIFY 广播', () {
      const ok =
          'HTTP/1.1 200 OK\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'LOCATION: http://192.168.1.10:8080/desc.xml\r\n\r\n';
      final parsed = parseSsdpResponse(ok);
      expect(parsed, isNotNull);
      expect(parsed!.location, 'http://192.168.1.10:8080/desc.xml');
      expect(
        parsed.usn,
        'uuid:abc::urn:schemas-upnp-org:device:MediaRenderer:1',
      );

      const notify =
          'NOTIFY * HTTP/1.1\r\n'
          'NT: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'LOCATION: http://192.168.1.11:9197/dmr\r\n\r\n';
      final alive = parseSsdpResponse(notify);
      expect(alive, isNotNull);
      expect(alive!.location, 'http://192.168.1.11:9197/dmr');
      expect(alive.st, rendererTarget);
    });

    test('不认自己的 M-SEARCH 与缺 LOCATION 的报文', () {
      expect(parseSsdpResponse(buildSearchRequest()), isNull);
      expect(parseSsdpResponse('HTTP/1.1 200 OK\r\nST: x\r\n'), isNull);
      expect(parseSsdpResponse(''), isNull);
    });
  });

  group('设备描述', () {
    const xml =
        '<?xml version="1.0"?>'
        '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
        '<friendlyName>客厅电视</friendlyName>'
        '<UDN>uuid:living-room</UDN>'
        '<serviceList>'
        '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
        '<controlURL>/AVTransport/control</controlURL></service>'
        '<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>'
        '<controlURL>/RenderingControl/control</controlURL></service>'
        '</serviceList></device></root>';

    test('解析 AVTransport / RenderingControl 并拼绝对地址', () {
      final device = parseDeviceDescription(
        xml,
        'http://192.168.1.10:8080/desc.xml',
      );
      expect(device, isNotNull);
      expect(device!.name, '客厅电视');
      expect(device.udn, 'uuid:living-room');
      expect(device.controlUrl, 'http://192.168.1.10:8080/AVTransport/control');
      expect(
        device.renderingControlUrl,
        'http://192.168.1.10:8080/RenderingControl/control',
      );
    });

    test('无 AVTransport 的设备不列出', () {
      const noAvt =
          '<root><device><friendlyName>音箱</friendlyName>'
          '<serviceList><service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>'
          '<controlURL>/rc</controlURL></service></serviceList></device></root>';
      expect(parseDeviceDescription(noAvt, 'http://host/d.xml'), isNull);
      expect(parseDeviceDescription('', 'http://host/d.xml'), isNull);
      expect(parseDeviceDescription('<bad', 'http://host/d.xml'), isNull);
    });

    test('combineUrl 相对设备根而不是 descriptor 目录', () {
      expect(
        combineUrl('http://host:8080/a/desc.xml', '/ctl'),
        'http://host:8080/ctl',
      );
      expect(
        combineUrl('http://host:8080/a/desc.xml', 'ctl'),
        'http://host:8080/ctl',
      );
      expect(
        combineUrl('http://host:8080/a/desc.xml', 'https://other/ctl'),
        'https://other/ctl',
      );
    });
  });

  group('DIDL 与 SOAP', () {
    test('escapeXml 覆盖五个实体与引号', () {
      expect(escapeXml('a&b<c>d"e\'f'), 'a&amp;b&lt;c&gt;d&quot;e&apos;f');
      expect(escapeXml(null), '');
    });

    test('headersJson 保持顺序', () {
      expect(
        headersJson({'User-Agent': 'UA', 'Referer': 'R'}),
        '{"User-Agent":"UA","Referer":"R"}',
      );
    });

    test('buildMetaData 带标题、描述与资源地址', () {
      const target = DlnaCastTarget(
        url: 'https://cdn.test/a.mp4',
        name: '电影 第1集',
        positionMs: 0,
        headers: {'User-Agent': 'UA'},
      );
      final didl = buildMetaData(target);
      expect(didl.contains('<dc:title>电影 第1集</dc:title>'), isTrue);
      expect(didl.contains('&quot;User-Agent&quot;:&quot;UA&quot;'), isTrue);
      expect(didl.contains('https://cdn.test/a.mp4'), isTrue);
      expect(didl.contains('object.item.videoItem'), isTrue);
    });

    test('buildSetUriBody 对 DIDL 再转义一层', () {
      final body = buildSetUriBody(
        'https://cdn/a.mp4',
        buildMetaData(
          const DlnaCastTarget(
            url: 'https://cdn/a.mp4',
            name: 'x',
            positionMs: 0,
          ),
        ),
      );
      expect(
        body.contains('<CurrentURI>https://cdn/a.mp4</CurrentURI>'),
        isTrue,
      );
      expect(body.contains('&lt;DIDL-Lite'), isTrue);
      expect(body.contains('<DIDL-Lite'), isFalse);
      expect(body.contains('SetAVTransportURI'), isTrue);
    });

    test('formatMs 与 SOAPACTION', () {
      expect(formatMs(0), '00:00:00.000');
      expect(formatMs(-5), '00:00:00.000');
      expect(formatMs(3723456), '01:02:03.456');
      expect(
        soapActionHeader('Play'),
        '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
      );
    });
  });

  group('投屏目标解析', () {
    const relay = 'http://127.0.0.1:9978';
    final hash = List<String>.filled(40, 'a').join();

    test('外部地址原样投出', () {
      final target = parseCastTarget('https://cdn.test/a.m3u8', '片名', 1200);
      expect(target.url, 'https://cdn.test/a.m3u8');
      expect(target.name, '片名');
      expect(target.positionMs, 1200);
      expect(target.localRelay, isFalse);
    });

    test('解开 /play 中继的防盗链参数', () {
      final wrapped = Uri.parse('$relay/play')
          .replace(
            queryParameters: {
              'url': 'https://cdn.test/movie.mp4',
              'ua': 'Test UA',
              'referer': 'https://site.test/',
              'cookie': 'sid=1',
              'dav': 'srv-9',
              'h': '{"X-Custom":"v1"}',
            },
          )
          .toString();
      final target = parseCastTarget(wrapped, '', 5000, relayBase: relay);
      expect(target.url, 'https://cdn.test/movie.mp4');
      expect(target.headers['User-Agent'], 'Test UA');
      expect(target.headers['Referer'], 'https://site.test/');
      expect(target.headers['Cookie'], 'sid=1');
      expect(target.headers['X-Custom'], 'v1');
      expect(target.davId, 'srv-9');
      expect(target.localRelay, isFalse);
      expect(target.name, 'MisaTV 投屏');
    });

    test('本机 /bt 中继标 localRelay', () {
      final target = parseCastTarget(
        '$relay/bt/$hash/1',
        '磁力',
        0,
        relayBase: relay,
      );
      expect(target.localRelay, isTrue);
      expect(target.url.contains('/bt/'), isTrue);
    });

    test('空地址与解不出上游的中继标 localRelay', () {
      expect(parseCastTarget('', 'x', 0).localRelay, isTrue);
      final broken = parseCastTarget(
        '$relay/play?url=not-http',
        'x',
        0,
        relayBase: relay,
      );
      expect(broken.localRelay, isTrue);
    });
  });

  group('投屏动作链', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;
    });

    test('SetAVTransportURI → Play → Seek 三个 SOAP 请求', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final calls = <String>[];
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        calls.add('${req.headers.value('soapaction') ?? ''}\n$body');
        req.response.headers.set('content-type', 'text/xml; charset=utf-8');
        req.response.write(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body/></s:Envelope>',
        );
        await req.response.close();
      });
      try {
        final device = DlnaDevice(
          udn: 'uuid:1',
          name: '客厅电视',
          controlUrl: '/AVTransport/control',
          location: 'http://127.0.0.1:${server.port}/desc.xml',
        );
        final result = await DlnaService().cast(
          device,
          const DlnaCastTarget(
            url: 'https://cdn.test/a.mp4',
            name: '电影',
            positionMs: 9000,
            headers: {'User-Agent': 'UA'},
          ),
        );
        expect(result.ok, isTrue);
        expect(result.device, '客厅电视');
        expect(calls.length, 3);
        expect(calls[0].contains('#SetAVTransportURI"'), isTrue);
        expect(
          calls[0].contains('<CurrentURI>https://cdn.test/a.mp4</CurrentURI>'),
          isTrue,
        );
        expect(calls[0].contains('&lt;DIDL-Lite'), isTrue);
        expect(calls[1].contains('#Play"'), isTrue);
        expect(calls[2].contains('#Seek"'), isTrue);
        expect(calls[2].contains('<Target>00:00:09.000</Target>'), isTrue);
      } finally {
        await server.close(force: true);
      }
    });

    test('设备返回非 2xx 时给出失败原因', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        await req.drain<void>();
        req.response.statusCode = 500;
        await req.response.close();
      });
      try {
        final device = DlnaDevice(
          udn: 'uuid:1',
          name: 'TV',
          controlUrl: '/ctl',
          location: 'http://127.0.0.1:${server.port}/desc.xml',
        );
        final result = await DlnaService().cast(
          device,
          const DlnaCastTarget(
            url: 'https://cdn.test/a.mp4',
            name: 'x',
            positionMs: 0,
          ),
        );
        expect(result.ok, isFalse);
        expect(result.error, contains('HTTP 500'));
      } finally {
        await server.close(force: true);
      }
    });
  });
}
