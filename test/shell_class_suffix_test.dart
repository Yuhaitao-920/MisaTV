import 'package:flutter_test/flutter_test.dart';

/// 加固壳类名 → payload 真实类的后缀剥离规则。
///
/// 这条规则决定 `_payloadCandidates` 能不能在缓存里认出目标载荷：
/// `wanted` 与载荷里的 class 名一个都对不上 → 候选列表为空 →
/// 退回 unidbg 原生解包 → `Init.getSpider` 拿不到实现 →
/// `BaseSpiderCAT.real()` 恒 null → 所有站点 homeContent 全 NPE。
void main() {
  String stripped(String className) {
    final full = className.replaceAll('/', '.');
    final simple = full.split('.').last;
    return simple.endsWith('Guard')
        ? simple.substring(0, simple.length - 'Guard'.length)
        : simple.endsWith('Amns')
        ? simple.substring(0, simple.length - 'Amns'.length)
        : simple.endsWith('CAT') && simple.length > 'CAT'.length
        ? simple.substring(0, simple.length - 'CAT'.length)
        : simple.endsWith('DexNative')
        ? simple.substring(0, simple.length - 'DexNative'.length)
        : '';
  }

  group('壳类后缀剥离', () {
    test('Guard 系（wex / fty）', () {
      expect(stripped('com.github.catvod.spider.WoGGGuard'), 'WoGG');
      expect(stripped('com.github.catvod.spider.AiNewWoggGuard'), 'AiNewWogg');
    });

    test('Amns 系（嗷呜）', () {
      expect(stripped('com.github.catvod.spider.WoggAmns'), 'Wogg');
      expect(stripped('com.github.catvod.spider.AAConfigAmns'), 'AAConfig');
    });

    test('CAT 系（hban.fuck）—— 本轮新增', () {
      // 壳的 BaseSpiderCAT.<init> 去掉 CAT 得到真实类名
      expect(stripped('com.github.catvod.spider.MoggCAT'), 'Mogg');
      expect(stripped('com.github.catvod.spider.HBcms10CAT'), 'HBcms10');
      expect(stripped('com.github.catvod.spider.BiliCAT'), 'Bili');
      expect(stripped('com.github.catvod.spider.PushCAT'), 'Push');
      expect(stripped('com.github.catvod.spider.MarketCAT'), 'Market');
    });

    test('DexNative 系', () {
      expect(stripped('com.github.catvod.spider.FooDexNative'), 'Foo');
    });

    test('普通类不剥离', () {
      expect(stripped('com.github.catvod.spider.Douban'), '');
      expect(stripped('com.github.catvod.spider.CAT'), '');
    });
  });
}