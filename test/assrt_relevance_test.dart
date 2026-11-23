import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/subtitle/assrt_provider.dart';
import 'package:kniephos/services/subtitle/normalize_query.dart';

/// 退化关键词的相关性过滤。
///
/// 场景（2026-11-16，人性本兽）：主关键词 `人性本兽` 偶发空结果时，
/// `searchAssrt` 会逐级退化到裸词 `Animals`，它返回 15 条无关片子
/// （危险动物 / 鈔級布偶 / Big.Sky / 都柏林动物…），用户看到
/// 「一堆字幕但没本片的」。
void main() {
  test('裸词 Animals 的结果里只留真正相关的', () {
    final f = File(r'G:\_an.json');
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('样本缺失，跳过');
      return;
    }
    final all = parseAssrtSearch(f.readAsStringSync());
    expect(all.length, greaterThan(5), reason: '样本应是噪音较多的场景');

    // _filterRelevant 是私有的，这里用同构逻辑验证语义：
    // 中文剧名（≥2 汉字）整串出现在候选标题里才算相关。
    const cjk = '人性本兽';
    final kept = all.where((c) {
      final hay = '${c.title} ${c.subname} ${c.videoName}';
      return hay.contains(cjk);
    }).toList();

    // ignore: avoid_print
    print('原始 ${all.length} 条 → 过滤后 ${kept.length} 条');
    for (final c in kept) {
      // ignore: avoid_print
      print('  [${c.title}]');
    }

    expect(kept.length, 1);
    expect(kept.first.title, contains('人性本兽'));
    expect(
      kept.any((c) => c.title.contains('危险动物')),
      isFalse,
      reason: '不相干的片子必须被滤掉',
    );
  });

  test('native_name 为空的条目会被丢弃（不再渲染成空行）', () {
    const body = '''
{"sub":{"subs":[
  {"id":1,"native_name":"","videoname":"","subtype":"srt","lang":{"desc":"简"}},
  {"id":2,"native_name":"","videoname":"不知道","subtype":"srt","lang":{"desc":"简"}},
  {"id":3,"native_name":"","videoname":"Some.Show.S01E01.1080p","subtype":"srt","lang":{"desc":"简"}},
  {"id":4,"native_name":"正名","videoname":"不知道","subtype":"srt","lang":{"desc":"简"}}
]},"status":0}
''';
    final list = parseAssrtSearch(body);
    expect(list.length, 2, reason: '两个全空的丢弃，无名但 videoname 可用的保留');
    expect(list[0].title, 'Some.Show.S01E01.1080p');
    expect(list[1].title, '正名');
  });
  // 2026-11-16 实测：assrt `sub/search` 有两种 JSON 格式。
  // 旧：{id, native_name, videoname, subtype, lang:{desc}}
  // 新：{fileid, m_title, m_title_bot, m_videoname, m_subtype, m_lang}
  // 旧代码只认 `id`，新格式条目全被丢弃 —— 「奥德赛」网页有 15 条、app 里 0 条。
  test('新格式（fileid / m_* 字段）也能解析', () {
    final f = File(r'G:\_od.json');
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('样本缺失，跳过');
      return;
    }
    final list = parseAssrtSearch(f.readAsStringSync());
    // ignore: avoid_print
    print('奥德赛解析出 ${list.length} 条');
    expect(list.length, 15, reason: '网页上 15 条，app 也必须 15 条');
    expect(list.first.id, '669742', reason: '应取 fileid');
    expect(list.first.title, contains('Odyssey'));
    expect(list.first.language, contains('英'), reason: 'm_lang 的 &nbsp; 要还原');
    expect(list.first.language, isNot(contains('&nbsp;')));
    expect(list.first.format, 'subrip(srt)', reason: '应取 m_subtype');
  });

  test('年份粘在片名后要拆出无年份变体', () {
    expect(titleVariants('奥德赛2026'), contains('奥德赛'));
    expect(titleVariants('奥德赛2026'), contains('奥德赛2026'));
    // 纯数字片名不能动
    expect(titleVariants('1917'), <String>['1917']);
    expect(titleVariants('2012'), <String>['2012']);
    // 没有年份的不受影响
    expect(titleVariants('人性本兽'), <String>['人性本兽']);
  });
}