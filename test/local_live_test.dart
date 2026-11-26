import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/core/utils/file_url.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/services/live_service.dart';

void main() {
  test('本地 TXT 直播源可直接读取', () async {
    final dir = await Directory.systemTemp.createTemp('kniephos-live-');
    final file = File('${dir.path}/local.txt');
    await file.writeAsString('央视,#genre#\nCCTV1,http://a.test/1.m3u8\n');
    final service = LiveService(AppHttp());
    final groups = await service.load(
      LiveBean(
        name: '本地',
        api: fileUrlOf(file.path),
        type: '0',
        url: fileUrlOf(file.path),
      ),
    );
    expect(groups.length, 1);
    expect(groups.first.group, '央视');
    expect(groups.first.channels.length, 1);
    await dir.delete(recursive: true);
  });

  test('带 api 的直播源按蜘蛛处理（无需写 type）', () {
    const bean = LiveBean(
      name: '央視頻',
      api: 'https://a.test/yangshipin.py',
      type: '0',
      url: 'https://capi.yangshipin.cn/api/oms/pc/navigation/home_top_nav',
      ext: 'https://a.test/yangshipin.json',
      timeout: 30,
    );
    expect(bean.isSpider, isTrue);
    expect(bean.supported, isTrue);
    expect(bean.spiderInput, bean.url);
    final site = bean.spiderSite!;
    expect(site.type, 3);
    expect(site.api, bean.api);
    expect(site.ext, bean.ext);
  });

  test('普通 txt 直播源不因 api 字段被误判成蜘蛛', () {
    const bean = LiveBean(
      name: '本地',
      api: 'file:///C:/live.txt',
      type: '0',
      url: 'file:///C:/live.txt',
    );
    expect(bean.isSpider, isFalse);
    expect(bean.spiderSite, isNull);
  });

  test('识别本机 do=py 直播代理地址', () {
    expect(
      LiveService.isSpiderProxyUrl(
        'http://127.0.0.1:9978/proxy?do=py&pid=1&cnlid=2',
      ),
      isTrue,
    );
    expect(
      LiveService.isSpiderProxyUrl('http://127.0.0.1:9978/proxy?do=live'),
      isFalse,
    );
    expect(LiveService.isSpiderProxyUrl('https://a.test/proxy?do=py'), isFalse);
  });

  test('本地 M3U 直播源可直接读取', () async {
    final dir = await Directory.systemTemp.createTemp('kniephos-live-');
    final file = File('${dir.path}/local.m3u');
    await file.writeAsString(
      '#EXTM3U x-tvg-url="http://epg.test/e.xml"\n'
      '#EXTINF:-1 tvg-name="CCTV1" group-title="央视",CCTV1\n'
      'http://a.test/1.m3u8\n',
    );
    final service = LiveService(AppHttp());
    final groups = await service.load(
      LiveBean(
        name: '本地',
        api: fileUrlOf(file.path),
        type: '0',
        url: fileUrlOf(file.path),
      ),
    );
    expect(groups.length, 1);
    expect(groups.first.channels.first.name, 'CCTV1');
    await dir.delete(recursive: true);
  });
}
