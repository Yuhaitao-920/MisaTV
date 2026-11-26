import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/live.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/models/vod.dart';
import 'package:kniephos/services/live/epg.dart';
import 'package:kniephos/services/player/player_window_session.dart';

void main() {
  test('点播独立窗口载荷往返保留详情、线路、选集与首播地址', () {
    const detail = VodDetail(
      id: 'v1',
      name: '示例影片',
      pic: 'http://img/p.jpg',
      flags: ['线路一', '线路二'],
      episodes: {
        '线路一': [
          Episode(name: '第1集', url: 'http://a/1.m3u8'),
          Episode(name: '第2集', url: 'http://a/2.m3u8'),
        ],
      },
      sourceKey: 's1',
    );
    const site = SourceBean(key: 's1', name: '示例源', type: 1, api: 'http://api');
    final payload = PlayerWindowPayload.vod(
      VodWindowSession(
        detail: detail,
        site: site,
        flag: '线路一',
        episodeIndex: 1,
        episodes: detail.episodeList('线路一'),
        initialPlay: const PlayResult(
          url: 'http://127.0.0.1:9978/play?url=x',
          flag: '线路一',
          headers: {'Referer': 'http://a/'},
        ),
        startPositionMs: 1234,
        ephemeral: true,
      ),
    );

    final decoded = PlayerWindowPayload.decode(payload.encode());
    expect(decoded, isNotNull);
    expect(decoded!.kind, 'vod');
    final vod = decoded.vod!;
    expect(vod.detail.name, '示例影片');
    expect(vod.detail.flags, ['线路一', '线路二']);
    expect(vod.detail.episodes['线路一']!.length, 2);
    expect(vod.detail.episodes['线路一']![1].name, '第2集');
    expect(vod.site.api, 'http://api');
    expect(vod.site.type, 1);
    expect(vod.flag, '线路一');
    expect(vod.episodeIndex, 1);
    expect(vod.episodes.length, 2);
    expect(vod.initialPlay!.url, 'http://127.0.0.1:9978/play?url=x');
    expect(vod.initialPlay!.headers['Referer'], 'http://a/');
    expect(vod.startPositionMs, 1234);
    expect(vod.ephemeral, isTrue);
  });

  test('直播独立窗口载荷往返保留频道、分组与 EPG', () {
    const channel = LiveChannel(
      name: 'CCTV1',
      urls: ['http://live/1.m3u8\$线路A', 'http://live/2.m3u8'],
      logo: 'http://logo.png',
      epg: 'http://epg.xml',
      header: {'Referer': 'http://live/'},
    );
    const bean = LiveBean(
      name: '直播源',
      api: '',
      type: '0',
      url: 'http://live.txt',
    );
    const group = LiveGroup(group: '央视', channels: [channel]);
    const epg = EpgEntry(
      current: EpgProgram(
        title: '新闻联播',
        start: '19:00',
        end: '19:30',
        startTime: 100,
        endTime: 200,
      ),
    );
    final payload = PlayerWindowPayload.live(
      LiveWindowSession(
        bean: bean,
        channel: channel,
        initialLine: channelLines(channel).first,
        epg: epg,
        groups: const [group],
        epgEntries: const {'CCTV1': epg},
        initialGroup: '央视',
      ),
    );

    final decoded = PlayerWindowPayload.decode(payload.encode());
    expect(decoded, isNotNull);
    expect(decoded!.kind, 'live');
    final live = decoded.live!;
    expect(live.bean.name, '直播源');
    expect(live.channel.name, 'CCTV1');
    expect(live.channel.urls.length, 2);
    expect(live.channel.header?['Referer'], 'http://live/');
    expect(live.initialLine.url, 'http://live/1.m3u8');
    expect(live.initialLine.name, '线路A');
    expect(live.groups.single.group, '央视');
    expect(live.groups.single.channels.single.name, 'CCTV1');
    expect(live.epgEntries['CCTV1']!.current!.title, '新闻联播');
    expect(live.initialGroup, '央视');
  });
  test('窗口参数里的载荷路径：必须解掉 misa-player: 前缀', () {
    // 子窗口是 `multi_window <id> <argument>` 重跑同一入口的，参数带前缀；
    // 不解前缀就会拿它当文件路径，子窗口只会显示「播放会话已失效」。
    expect(
      standalonePlayerPayloadPath(
        'misa-player:E:\\data\\player-windows\\session-1.json',
      ),
      r'E:\data\player-windows\session-1.json',
    );
    expect(
      standalonePlayerPayloadPath('  misa-player:C:/tmp/s.json  '),
      'C:/tmp/s.json',
    );
    expect(standalonePlayerPayloadPath(null), isNull);
    expect(standalonePlayerPayloadPath(''), isNull);
    expect(standalonePlayerPayloadPath('misa-player:   '), isNull);
    expect(
      standalonePlayerPayloadPath(r'C:\Users\x\session.json'),
      isNull,
      reason: '主窗口没有前缀参数，不能误判成子窗口',
    );
  });
}
