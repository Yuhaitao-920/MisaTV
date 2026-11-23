import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/movie_parser.dart';

void main() {
  group('MovieParser XML', () {
    test('解析分类、列表与选集', () {
      const xml = r'''
      <rss version="5.1">
        <list page="1" pagecount="2" pagesize="20" recordcount="25">
          <video>
            <id>1</id>
            <tid>2</tid>
            <name>测试影片</name>
            <type>动作</type>
            <pic>http://img/p.jpg</pic>
            <area>中国</area>
            <year>2024</year>
            <note>更新至02</note>
            <des>简介</des>
            <dl>
              <dd flag="线路1">第01集$http://v/1.m3u8#第02集$http://v/2.m3u8</dd>
            </dl>
          </video>
        </list>
        <class>
          <ty id="1">电影</ty>
          <ty id="2">剧集</ty>
        </class>
      </rss>
      ''';
      final body = MovieParser.parseXml(xml);
      expect(body.classes.length, 2);
      expect(body.classes[1].id, '2');
      expect(body.movie?.videos.length, 1);
      final detail = MovieParser.toDetail(body.movie, 'src');
      expect(detail?.name, '测试影片');
      expect(detail?.flags, ['线路1']);
      expect(detail?.episodeList('线路1').length, 2);
      expect(detail?.episodeList('线路1')[1].url, 'http://v/2.m3u8');
    });

    test('XML 空响应不抛错', () {
      expect(() => MovieParser.parseXml('<html>oops</html>'), returnsNormally);
      expect(MovieParser.parseXml('<html>oops</html>').movie, isNull);
    });
  });

  group('MovieParser JSON', () {
    test(r'$$$ 多线路与筛选组', () {
      const json = '''
      {
        "class": [
          {"type_id":"1","type_name":"电影","filters":[{"key":"area","name":"地区","value":[{"n":"全部","v":""},{"n":"大陆","v":"大陆"}]}]},
          {"type_id":"2","type_name":"剧集"}
        ],
        "filters": {"2": {"year": {"name":"年份","value":[{"n":"2024","v":"2024"}]}}},
        "list": [
          {
            "vod_id":"9","vod_name":"片子","type_id":"1","type_name":"电影",
            "vod_pic":"http://pic/a.jpg@Referer=http://ref",
            "vod_year":"2023","vod_remarks":"HD",
            "vod_play_from":"线路A\$\$\$线路B",
            "vod_play_url":"第01集\$http://a/1.m3u8#第02集\$http://a/2.m3u8\$\$\$正片\$http://b/full.mp4"
          }
        ],
        "page": 1, "pagecount": 3, "limit": 20, "total": 50
      }
      ''';
      final body = MovieParser.parseJson(json);
      expect(body.classes.length, 2);
      expect(body.classes[0].filters.length, 1);
      expect(body.classes[1].filters.length, 1);
      expect(body.classes[1].filters.first.name, '年份');
      expect(body.movie?.pagecount, 3);
      expect(body.movie?.videos.first.pic, 'http://pic/a.jpg');
      final detail = MovieParser.toDetail(body.movie, 'src');
      expect(detail?.flags, ['线路A', '线路B']);
      expect(detail?.episodes['线路A']?.length, 2);
      expect(detail?.episodes['线路B']?.first.url, 'http://b/full.mp4');
    });

    test('空年份不显示成 0，folder 条目标记保留', () {
      const json = '''
      {
        "list": [
          {
            "vod_id": "click_huya@@1", "vod_name": "英雄联盟",
            "vod_pic": "http://pic/a.jpg", "vod_tag": "folder"
          },
          {"vod_id": "1", "vod_name": "片子"}
        ]
      }
      ''';
      final items = MovieParser.toItems(
        MovieParser.parseJson(json).movie,
        'src',
      );
      expect(items[0].year, '');
      expect(items[0].tag, 'folder');
      expect(items[0].isFolder, isTrue);
      expect(items[1].year, '');
      expect(items[1].isFolder, isFalse);
    });

    test('detailContent 返回多条 folder 目录时全部保留', () {
      const json = '''
      {
        "list": [
          {"vod_id": "quark-51", "vod_name": "夸克网盘 51", "vod_tag": "folder"},
          {"vod_id": "baidu-2", "vod_name": "百度网盘 2", "vod_tag": "folder"}
        ]
      }
      ''';
      final detail = MovieParser.toDetail(
        MovieParser.parseJson(json).movie,
        'src',
      );
      expect(detail, isNotNull);
      expect(detail!.folders.length, 2);
      expect(detail.folders.first.id, 'quark-51');
      expect(detail.folders.last.name, '百度网盘 2');
      expect(detail.folders.every((folder) => folder.isFolder), isTrue);
      expect(detail.flags, isEmpty);
      expect(detail.episodes, isEmpty);
    });
  });
}
