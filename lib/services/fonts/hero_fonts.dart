import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';

/// 沉浸 Hero 标题可用的字体槽位（按地区 × 类型划分）。
///
/// 字体不随安装包内置：用户在设置页下载，或把本地字体导入某个槽位后才生效。
enum HeroFontRole {
  // 中文
  zhBrush,
  zhRomance,
  zhCrime,
  zhHorror,
  zhWar,
  zhAnimation,
  zhKai,
  zhPen,
  zhModern,
  zhJianghu,
  zhSong,
  // 日本語
  jaCrime,
  jaDrama,
  jaAnimation,
  jaComedy,
  jaWar,
  jaScifi,
  jaBrushBold,
  jaBrushLight,
  jaOld,
  jaCute,
  jaPop,
  jaHand,
  jaDeco,
  jaModern,
  // 한국어
  koDrama,
  koCrime,
  koComedy,
  koBrush,
  koPen,
  koCute,
  koHand,
  koSerif,
  // Latin
  latinAction,
  latinRomance,
  latinScifi,
  latinHorror,
  latinComedy,
  latinPoster,
  latinEpic,
  latinSlab,
  latinGothic,
  latinType,
  latinRetro,
  latinWestern,
  latinFat,
  latinDeco,
}

/// 一个可选字体包的元数据（全部为 SIL Open Font License 字体）。
class HeroFontPack {
  const HeroFontPack({
    required this.role,
    required this.group,
    required this.title,
    required this.tagline,
    required this.url,
    required this.fallbackUrl,
    required this.sizeBytes,
  });

  final HeroFontRole role;

  /// 设置页分组：中文 / 日本語 / 한국어 / Latin。
  final String group;
  final String title;
  final String tagline;
  final String url;
  final String fallbackUrl;
  final int sizeBytes;

  String get sizeLabel => '${(sizeBytes / 1048576).toStringAsFixed(1)} MB';
}

/// 下载源：主地址走 jsDelivr（国内通常比 GitHub raw 稳），失败再回退 raw。
const List<HeroFontPack> heroFontPacks = [
  // ------------------------------------------------------------------ 中文
  HeroFontPack(
    role: HeroFontRole.zhRomance,
    group: '中文',
    title: '宋楷 · 爱情文艺',
    tagline: '中国大陆 / 港台 · 爱情 / 剧情 / 都市',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zcoolxiaowei/ZCOOLXiaoWei-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/zcoolxiaowei/ZCOOLXiaoWei-Regular.ttf',
    sizeBytes: 6313808,
  ),
  HeroFontPack(
    role: HeroFontRole.zhBrush,
    group: '中文',
    title: '书法 · 古装武侠',
    tagline: '中国大陆 / 港台 · 古装 / 武侠 / 仙侠',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mashanzheng/MaShanZheng-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/mashanzheng/MaShanZheng-Regular.ttf',
    sizeBytes: 5857936,
  ),
  HeroFontPack(
    role: HeroFontRole.zhCrime,
    group: '中文',
    title: '龙藏行书 · 武侠江湖',
    tagline: '中国大陆 / 港台 · 武侠 / 仙侠 / 江湖',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/longcang/LongCang-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/longcang/LongCang-Regular.ttf',
    sizeBytes: 5162508,
  ),
  HeroFontPack(
    role: HeroFontRole.zhHorror,
    group: '中文',
    title: '行草 · 恐怖志怪',
    tagline: '中国大陆 / 港台 · 恐怖 / 惊悚 / 志怪',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zhimangxing/ZhiMangXing-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/zhimangxing/ZhiMangXing-Regular.ttf',
    sizeBytes: 4063532,
  ),
  HeroFontPack(
    role: HeroFontRole.zhWar,
    group: '中文',
    title: '窄黑 · 战争历史',
    tagline: '中国大陆 / 港台 · 战争 / 历史 / 灾难',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zcoolqingkehuangyou/ZCOOLQingKeHuangYou-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/zcoolqingkehuangyou/ZCOOLQingKeHuangYou-Regular.ttf',
    sizeBytes: 8328684,
  ),
  HeroFontPack(
    role: HeroFontRole.zhAnimation,
    group: '中文',
    title: '快乐体 · 动画喜剧',
    tagline: '中国大陆 / 港台 · 动画 / 喜剧 / 家庭',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zcoolkuaile/ZCOOLKuaiLe-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/zcoolkuaile/ZCOOLKuaiLe-Regular.ttf',
    sizeBytes: 1514968,
  ),
  HeroFontPack(
    role: HeroFontRole.zhKai,
    group: '中文',
    title: '霞鹜文楷 · 都市情感',
    tagline: '中国大陆 / 港台 · 都市 / 情感 / 文艺',
    url: 'https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKai-Regular.ttf',
    fallbackUrl: 'https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKai-Regular.ttf',
    sizeBytes: 25928940,
  ),
  HeroFontPack(
    role: HeroFontRole.zhPen,
    group: '中文',
    title: '毛草 · 恐怖手写',
    tagline: '中国大陆 / 港台 · 恐怖 / 志怪 / 惊悚',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/liujianmaocao/LiuJianMaoCao-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/liujianmaocao/LiuJianMaoCao-Regular.ttf',
    sizeBytes: 4951804,
  ),
  HeroFontPack(
    role: HeroFontRole.zhModern,
    group: '中文',
    title: '霞鹜新晰黑 · 都市犯罪',
    tagline: '中国大陆 / 港台 · 都市 / 犯罪 / 职场',
    url: 'https://github.com/lxgw/LxgwNeoXiHei/releases/download/v1.309/LXGWNeoXiHei.ttf',
    fallbackUrl: 'https://github.com/lxgw/LxgwNeoXiHei/releases/download/v1.309/LXGWNeoXiHei.ttf',
    sizeBytes: 7475784,
  ),
  HeroFontPack(
    role: HeroFontRole.zhJianghu,
    group: '中文',
    title: '漓雨手书 · 江湖毛笔',
    tagline: '中国大陆 / 港台 · 武侠 / 仙侠 / 古装',
    url: 'https://github.com/InkPantherType/LiyuShoushu/releases/download/v0.107/LiyuShoushu.ttf',
    fallbackUrl: 'https://github.com/InkPantherType/LiyuShoushu/releases/download/v0.107/LiyuShoushu.ttf',
    sizeBytes: 25024512,
  ),
  HeroFontPack(
    role: HeroFontRole.zhSong,
    group: '中文',
    title: '霞鹜新致宋 · 年代正剧',
    tagline: '中国大陆 / 港台 · 年代 / 文艺 / 悬疑',
    url: 'https://github.com/lxgw/LxgwNeoZhiSong/releases/download/v1.071/LXGWNeoZhiSong.ttf',
    fallbackUrl: 'https://github.com/lxgw/LxgwNeoZhiSong/releases/download/v1.071/LXGWNeoZhiSong.ttf',
    sizeBytes: 10483620,
  ),

  // ------------------------------------------------------------------ 日本語
  HeroFontPack(
    role: HeroFontRole.jaCrime,
    group: '日本語',
    title: '毛笔 · 犯罪惊悚',
    tagline: '日本 · 犯罪 / 惊悚 / 恐怖 / 动作',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/yujisyuku/YujiSyuku-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/yujisyuku/YujiSyuku-Regular.ttf',
    sizeBytes: 8430348,
  ),
  HeroFontPack(
    role: HeroFontRole.jaDrama,
    group: '日本語',
    title: '明朝 · 剧情文艺',
    tagline: '日本 · 剧情 / 爱情 / 家庭',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/shipporiminchob1/ShipporiMinchoB1-ExtraBold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/shipporiminchob1/ShipporiMinchoB1-ExtraBold.ttf',
    sizeBytes: 15088060,
  ),
  HeroFontPack(
    role: HeroFontRole.jaAnimation,
    group: '日本語',
    title: '装饰黑 · 动画',
    tagline: '日本 · 动画 / 奇幻 / 冒险',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/delagothicone/DelaGothicOne-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/delagothicone/DelaGothicOne-Regular.ttf',
    sizeBytes: 2508848,
  ),
  HeroFontPack(
    role: HeroFontRole.jaComedy,
    group: '日本語',
    title: '手写黑 · 喜剧',
    tagline: '日本 · 喜剧 / 日常 / 青春',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/rocknrollone/RocknRollOne-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/rocknrollone/RocknRollOne-Regular.ttf',
    sizeBytes: 2682824,
  ),
  HeroFontPack(
    role: HeroFontRole.jaWar,
    group: '日本語',
    title: '古籍明朝 · 战争历史',
    tagline: '日本 · 战争 / 历史 / 时代剧',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenantique/ZenAntique-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/zenantique/ZenAntique-Regular.ttf',
    sizeBytes: 5507920,
  ),
  HeroFontPack(
    role: HeroFontRole.jaScifi,
    group: '日本語',
    title: '点阵体 · 科幻',
    tagline: '日本 · 科幻 / 机甲 / 赛博',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/dotgothic16/DotGothic16-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/dotgothic16/DotGothic16-Regular.ttf',
    sizeBytes: 2069236,
  ),
  HeroFontPack(
    role: HeroFontRole.jaBrushBold,
    group: '日本語',
    title: '太笔 · 时代剧',
    tagline: '日本 · 时代剧 / 历史 / 战争',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/yujiboku/YujiBoku-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/yujiboku/YujiBoku-Regular.ttf',
    sizeBytes: 8525588,
  ),
  HeroFontPack(
    role: HeroFontRole.jaBrushLight,
    group: '日本語',
    title: '细毛笔 · 文艺',
    tagline: '日本 · 文艺 / 剧情 / 家庭',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/yujimai/YujiMai-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/yujimai/YujiMai-Regular.ttf',
    sizeBytes: 8496292,
  ),
  HeroFontPack(
    role: HeroFontRole.jaOld,
    group: '日本語',
    title: '古籍明朝 · 悬疑',
    tagline: '日本 · 悬疑 / 犯罪 / 时代',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenoldmincho/ZenOldMincho-Bold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/zenoldmincho/ZenOldMincho-Bold.ttf',
    sizeBytes: 2912449,
  ),
  HeroFontPack(
    role: HeroFontRole.jaCute,
    group: '日本語',
    title: '圆手写 · 治愈',
    tagline: '日本 · 治愈 / 日常 / 青春',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/hachimarupop/HachiMaruPop-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/hachimarupop/HachiMaruPop-Regular.ttf',
    sizeBytes: 2649787,
  ),
  HeroFontPack(
    role: HeroFontRole.jaPop,
    group: '日本語',
    title: '街头 POP · 喜剧',
    tagline: '日本 · 喜剧 / 综艺 / 青春',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mochiypopone/MochiyPopOne-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/mochiypopone/MochiyPopOne-Regular.ttf',
    sizeBytes: 2990082,
  ),
  HeroFontPack(
    role: HeroFontRole.jaHand,
    group: '日本語',
    title: '手写 · 日记感',
    tagline: '日本 · 日常 / 青春 / 文艺',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/yomogi/Yomogi-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/yomogi/Yomogi-Regular.ttf',
    sizeBytes: 2297645,
  ),
  HeroFontPack(
    role: HeroFontRole.jaDeco,
    group: '日本語',
    title: '装饰 · 奇幻',
    tagline: '日本 · 奇幻 / 冒险 / 动画',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/rampartone/RampartOne-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/rampartone/RampartOne-Regular.ttf',
    sizeBytes: 2429148,
  ),
  HeroFontPack(
    role: HeroFontRole.jaModern,
    group: '日本語',
    title: '现代明朝 · 剧情',
    tagline: '日本 · 剧情 / 爱情 / 家庭',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/kaiseidecol/KaiseiDecol-Bold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/kaiseidecol/KaiseiDecol-Bold.ttf',
    sizeBytes: 2553102,
  ),

  // ------------------------------------------------------------------ 한국어
  HeroFontPack(
    role: HeroFontRole.koDrama,
    group: '한국어',
    title: '明朝 · 剧情爱情',
    tagline: '韩国 · 剧情 / 爱情 / 家庭',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/nanummyeongjo/NanumMyeongjo-ExtraBold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/nanummyeongjo/NanumMyeongjo-ExtraBold.ttf',
    sizeBytes: 3180888,
  ),
  HeroFontPack(
    role: HeroFontRole.koCrime,
    group: '한국어',
    title: '粗黑 · 犯罪悬疑',
    tagline: '韩国 · 犯罪 / 悬疑 / 动作',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/blackhansans/BlackHanSans-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/blackhansans/BlackHanSans-Regular.ttf',
    sizeBytes: 998424,
  ),
  HeroFontPack(
    role: HeroFontRole.koComedy,
    group: '한국어',
    title: '手写体 · 喜剧',
    tagline: '韩国 · 喜剧 / 青春 / 日常',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/dohyeon/DoHyeon-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/dohyeon/DoHyeon-Regular.ttf',
    sizeBytes: 879764,
  ),
  HeroFontPack(
    role: HeroFontRole.koBrush,
    group: '한국어',
    title: '毛笔 · 古装',
    tagline: '韩国 · 古装 / 历史 / 武侠',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/nanumbrushscript/NanumBrushScript-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/nanumbrushscript/NanumBrushScript-Regular.ttf',
    sizeBytes: 879053,
  ),
  HeroFontPack(
    role: HeroFontRole.koPen,
    group: '한국어',
    title: '手写 · 文艺',
    tagline: '韩国 · 文艺 / 爱情 / 日常',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/nanumpenscript/NanumPenScript-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/nanumpenscript/NanumPenScript-Regular.ttf',
    sizeBytes: 917943,
  ),
  HeroFontPack(
    role: HeroFontRole.koCute,
    group: '한국어',
    title: '卡通 · 喜剧',
    tagline: '韩国 · 喜剧 / 青春 / 家庭',
    url:
        'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/jua/Jua-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/jua/Jua-Regular.ttf',
    sizeBytes: 533511,
  ),
  HeroFontPack(
    role: HeroFontRole.koHand,
    group: '한국어',
    title: '手写 · 青春',
    tagline: '韩国 · 青春 / 校园 / 日常',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/gaegu/Gaegu-Bold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/gaegu/Gaegu-Bold.ttf',
    sizeBytes: 717074,
  ),
  HeroFontPack(
    role: HeroFontRole.koSerif,
    group: '한국어',
    title: '明朝 · 正剧',
    tagline: '韩国 · 剧情 / 历史 / 家庭',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/gowunbatang/GowunBatang-Bold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/gowunbatang/GowunBatang-Bold.ttf',
    sizeBytes: 902061,
  ),

  // ------------------------------------------------------------------ Latin
  HeroFontPack(
    role: HeroFontRole.latinAction,
    group: 'Latin',
    title: 'Anton · 动作犯罪',
    tagline: '欧美 · 动作 / 犯罪 / 战争',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/anton/Anton-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/anton/Anton-Regular.ttf',
    sizeBytes: 170812,
  ),
  HeroFontPack(
    role: HeroFontRole.latinRomance,
    group: 'Latin',
    title: 'Playfair · 爱情文艺',
    tagline: '欧美 · 爱情 / 剧情 / 古典',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/playfairdisplay/PlayfairDisplay%5Bwght%5D.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/playfairdisplay/PlayfairDisplay%5Bwght%5D.ttf',
    sizeBytes: 300724,
  ),
  HeroFontPack(
    role: HeroFontRole.latinScifi,
    group: 'Latin',
    title: 'Orbitron · 科幻',
    tagline: '欧美 · 科幻 / 赛博 / 太空',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/orbitron/Orbitron%5Bwght%5D.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/orbitron/Orbitron%5Bwght%5D.ttf',
    sizeBytes: 38576,
  ),
  HeroFontPack(
    role: HeroFontRole.latinHorror,
    group: 'Latin',
    title: 'Creepster · 恐怖',
    tagline: '欧美 · 恐怖 / 惊悚 / 万圣节',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/creepster/Creepster-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/creepster/Creepster-Regular.ttf',
    sizeBytes: 62724,
  ),
  HeroFontPack(
    role: HeroFontRole.latinComedy,
    group: 'Latin',
    title: 'Bangers · 喜剧动画',
    tagline: '欧美 · 喜剧 / 动画 / 家庭',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/bangers/Bangers-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/bangers/Bangers-Regular.ttf',
    sizeBytes: 93148,
  ),
  HeroFontPack(
    role: HeroFontRole.latinPoster,
    group: 'Latin',
    title: 'Archivo Black · 海报',
    tagline: '欧美 · 动作 / 犯罪 / 战争',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/archivoblack/ArchivoBlack-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/archivoblack/ArchivoBlack-Regular.ttf',
    sizeBytes: 40921,
  ),
  HeroFontPack(
    role: HeroFontRole.latinEpic,
    group: 'Latin',
    title: 'Cinzel · 史诗',
    tagline: '欧美 · 史诗 / 奇幻 / 历史',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/cinzel/Cinzel%5Bwght%5D.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/cinzel/Cinzel%5Bwght%5D.ttf',
    sizeBytes: 59094,
  ),
  HeroFontPack(
    role: HeroFontRole.latinSlab,
    group: 'Latin',
    title: 'Alfa Slab · 粗衬线',
    tagline: '欧美 · 动作 / 冒险 / 喜剧',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/alfaslabone/AlfaSlabOne-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/alfaslabone/AlfaSlabOne-Regular.ttf',
    sizeBytes: 44949,
  ),
  HeroFontPack(
    role: HeroFontRole.latinGothic,
    group: 'Latin',
    title: '哥特 · 恐怖',
    tagline: '欧美 · 恐怖 / 惊悚 / 吸血鬼',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/unifrakturcook/UnifrakturCook-Bold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/unifrakturcook/UnifrakturCook-Bold.ttf',
    sizeBytes: 28240,
  ),
  HeroFontPack(
    role: HeroFontRole.latinType,
    group: 'Latin',
    title: '打字机 · 悬疑',
    tagline: '欧美 · 悬疑 / 犯罪 / 纪实',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/courierprime/CourierPrime-Bold.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/courierprime/CourierPrime-Bold.ttf',
    sizeBytes: 35751,
  ),
  HeroFontPack(
    role: HeroFontRole.latinRetro,
    group: 'Latin',
    title: '霓虹 · 科幻',
    tagline: '欧美 · 科幻 / 赛博 / 复古',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/monoton/Monoton-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/monoton/Monoton-Regular.ttf',
    sizeBytes: 27105,
  ),
  HeroFontPack(
    role: HeroFontRole.latinWestern,
    group: 'Latin',
    title: '西部 · 冒险',
    tagline: '欧美 · 西部 / 冒险 / 动作',
    url:
        'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/rye/Rye-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/rye/Rye-Regular.ttf',
    sizeBytes: 58806,
  ),
  HeroFontPack(
    role: HeroFontRole.latinFat,
    group: 'Latin',
    title: 'Abril Fatface · 爱情',
    tagline: '欧美 · 爱情 / 剧情 / 时尚',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/abrilfatface/AbrilFatface-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/abrilfatface/AbrilFatface-Regular.ttf',
    sizeBytes: 29448,
  ),
  HeroFontPack(
    role: HeroFontRole.latinDeco,
    group: 'Latin',
    title: '装饰艺术 · 剧情',
    tagline: '欧美 · 剧情 / 悬疑 / 年代',
    url: 'https://cdn.jsdelivr.net/gh/google/fonts/main/ofl/limelight/Limelight-Regular.ttf',
    fallbackUrl: 'https://raw.githubusercontent.com/google/fonts/main/ofl/limelight/Limelight-Regular.ttf',
    sizeBytes: 48557,
  ),
];

/// 已安装字体：文件与注册到引擎的 family。
class _InstalledFont {
  const _InstalledFont({
    required this.role,
    required this.path,
    required this.family,
    required this.name,
    required this.custom,
  });

  final HeroFontRole role;
  final String path;
  final String family;
  final String name;
  final bool custom;
}

/// 沉浸标题字体包的下载 / 导入 / 注册。
///
/// 参考 JAR 运行时的扩展模式：应用只带规则不带字体，字体放在
/// `<应用数据>/fonts`，下载或导入后用 [FontLoader] 注册，启动时自动恢复。
class HeroFontService extends ChangeNotifier {
  HeroFontService._();
  static final HeroFontService instance = HeroFontService._();

  final Map<HeroFontRole, _InstalledFont> _installed = {};
  final Set<HeroFontRole> _busy = {};
  final Map<HeroFontRole, double> _progress = {};
  Directory? _dir;
  Future<void>? _initFuture;
  bool _ready = false;

  /// 桌面端才支持运行时字体；Web 版没有可写的应用数据目录。
  bool get supported => !kIsWeb;

  bool get ready => _ready;

  bool installed(HeroFontRole role) => _installed.containsKey(role);

  bool busy(HeroFontRole role) => _busy.contains(role);

  double progress(HeroFontRole role) => _progress[role] ?? 0;

  /// 已安装字体注册到引擎后的 family；未安装返回 null。
  String? familyOf(HeroFontRole role) => _installed[role]?.family;

  /// 自定义导入字体的显示名（下载安装的包返回 null）。
  String? customNameOf(HeroFontRole role) {
    final item = _installed[role];
    return item != null && item.custom ? item.name : null;
  }

  int get installedCount => _installed.length;

  /// 尚未安装的字体包总大小（字节）。
  int get missingBytes => heroFontPacks
      .where((pack) => !_installed.containsKey(pack.role))
      .fold<int>(0, (sum, pack) => sum + pack.sizeBytes);

  int get missingCount =>
      heroFontPacks.where((pack) => !_installed.containsKey(pack.role)).length;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (!supported) return;
    try {
      final dir = await _fontsDir();
      final manifest = await _readManifest();
      final valid = <String, Map<String, dynamic>>{};
      for (final entry in manifest.entries) {
        final role = _roleFromId(entry.key);
        final data = entry.value;
        if (role == null || data is! Map) continue;
        final file = (data['file'] ?? '').toString().trim();
        final family = (data['family'] ?? '').toString().trim();
        if (file.isEmpty || family.isEmpty) continue;
        final path = p.join(dir.path, file);
        final type = File(path);
        if (!await type.exists()) continue;
        try {
          final bytes = await type.readAsBytes();
          if (!_looksLikeFont(bytes)) continue;
          await _register(family, bytes);
          _installed[role] = _InstalledFont(
            role: role,
            path: path,
            family: family,
            name: (data['name'] ?? '').toString().trim(),
            custom: data['custom'] == true,
          );
          valid[entry.key] = Map<String, dynamic>.from(data);
        } catch (e) {
          AppLog.w('font', '字体 ${entry.key} 恢复失败：$e');
        }
      }
      if (valid.length != manifest.length) {
        _dir = dir;
        await _saveManifest();
      }
      AppLog.i('font', '沉浸标题字体：已恢复 ${_installed.length} 个');
    } catch (e) {
      AppLog.w('font', '字体服务初始化失败：$e');
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  Future<Directory> _fontsDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'fonts'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<Map<String, dynamic>> _readManifest() async {
    try {
      final dir = await _fontsDir();
      final file = File(p.join(dir.path, 'index.json'));
      if (!await file.exists()) return const {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const {};
      final fonts = decoded['fonts'];
      return fonts is Map
          ? {for (final e in fonts.entries) '${e.key}': e.value}
          : const {};
    } catch (e) {
      AppLog.w('font', '读取字体清单失败：$e');
      return const {};
    }
  }

  Future<void> _saveManifest() async {
    try {
      final dir = await _fontsDir();
      final fonts = <String, dynamic>{
        for (final entry in _installed.entries)
          entry.key.name: {
            'file': p.basename(entry.value.path),
            'family': entry.value.family,
            'name': entry.value.name,
            'custom': entry.value.custom,
          },
      };
      final file = File(p.join(dir.path, 'index.json'));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert({'version': 1, 'fonts': fonts}),
        flush: true,
      );
    } catch (e) {
      AppLog.w('font', '保存字体清单失败：$e');
    }
  }

  /// 下载并安装一个字体包；进度通过 [progress] 读取。
  Future<void> install(HeroFontPack pack) async {
    if (!supported || _busy.contains(pack.role)) return;
    _busy.add(pack.role);
    _progress[pack.role] = 0;
    notifyListeners();
    try {
      final bytes = await _download(pack, (value) {
        _progress[pack.role] = value;
        notifyListeners();
      });
      if (!_looksLikeFont(bytes)) {
        throw StateError('下载内容不是有效的字体文件');
      }
      await _writeAndRegister(pack, bytes, name: pack.title, custom: false);
      AppLog.i('font', '字体包已安装：${pack.title}');
    } finally {
      _busy.remove(pack.role);
      _progress.remove(pack.role);
      notifyListeners();
    }
  }

  /// 把本地字体文件导入某个槽位（例如从 BOOTH 下载的 ダストデビルM）。
  Future<void> importLocal(HeroFontPack pack, String filePath) async {
    if (!supported || _busy.contains(pack.role)) return;
    _busy.add(pack.role);
    notifyListeners();
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      if (!_looksLikeFont(bytes)) {
        throw StateError('选择的文件不是有效的 TTF / OTF 字体');
      }
      await _writeAndRegister(
        pack,
        bytes,
        name: p.basenameWithoutExtension(filePath),
        custom: true,
      );
      AppLog.i('font', '本地字体已导入：${pack.role.name}');
    } finally {
      _busy.remove(pack.role);
      notifyListeners();
    }
  }

  /// 删除已安装字体。引擎无法卸载已注册字体，重启后彻底释放。
  Future<void> remove(HeroFontRole role) async {
    final old = _installed.remove(role);
    if (old == null) return;
    try {
      await File(old.path).delete();
    } catch (_) {
      // 文件被占用时下次启动会按清单清理。
    }
    await _saveManifest();
    notifyListeners();
  }

  Future<void> _writeAndRegister(
    HeroFontPack pack,
    Uint8List bytes, {
    required String name,
    required bool custom,
  }) async {
    final dir = await _fontsDir();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final family = 'MisaHero${pack.role.name}$stamp';
    final file = File(p.join(dir.path, '${pack.role.name}-$stamp.ttf'));
    await file.writeAsBytes(bytes, flush: true);
    try {
      await _register(family, bytes);
    } catch (e) {
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    }
    final old = _installed[pack.role];
    if (old != null && old.path != file.path) {
      try {
        await File(old.path).delete();
      } catch (_) {}
    }
    _installed[pack.role] = _InstalledFont(
      role: pack.role,
      path: file.path,
      family: family,
      name: name,
      custom: custom,
    );
    await _saveManifest();
    notifyListeners();
  }

  Future<void> _register(String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
    await loader.load();
  }

  Future<Uint8List> _download(
    HeroFontPack pack,
    void Function(double value) onProgress,
  ) async {
    final proxy = await _systemProxy();
    final urls = _candidateUrls(pack);
    final errors = <String>[];
    final attempts = proxy == null ? <String?>[null] : <String?>[proxy, null];
    for (final directive in attempts) {
      for (final url in urls) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10)
          ..idleTimeout = const Duration(seconds: 30)
          ..userAgent = 'MisaTV/1.1';
        if (directive != null) {
          client.findProxy = (_) => directive;
        }
        try {
          final request = await client
              .getUrl(Uri.parse(url))
              .timeout(const Duration(seconds: 20));
          request.headers.set(HttpHeaders.acceptHeader, '*/*');
          final response = await request.close().timeout(
            const Duration(seconds: 45),
          );
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException(
              'HTTP ${response.statusCode}',
              uri: Uri.parse(url),
            );
          }
          final total = response.contentLength;
          final builder = BytesBuilder(copy: false);
          var received = 0;
          await for (final chunk in response.timeout(
            const Duration(seconds: 45),
          )) {
            builder.add(chunk);
            received += chunk.length;
            if (total > 0) onProgress((received / total).clamp(0.0, 1.0));
          }
          if (received < 1024) {
            throw StateError('只收到 $received 字节');
          }
          onProgress(1);
          return builder.takeBytes();
        } catch (e) {
          errors.add('$url: $e');
          AppLog.w(
            'font',
            '字体下载失败（${directive == null ? '直连' : '系统代理'} $url）：$e',
          );
        } finally {
          client.close(force: true);
        }
      }
    }
    throw StateError(
      '字体下载失败（已尝试 ${errors.length} 个下载源）'
      '${errors.isEmpty ? '' : '：${errors.last}'}',
    );
  }

  /// 下载源顺序：GitHub Release 先走国内镜像，再回退直连。
  List<String> _candidateUrls(HeroFontPack pack) {
    final urls = <String>[];
    void add(String value) {
      final url = value.trim();
      if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
    }

    void addWithMirrors(String value) {
      final url = value.trim();
      if (url.isEmpty) return;
      final github =
          url.startsWith('https://github.com/') ||
          url.startsWith('http://github.com/') ||
          url.startsWith('https://raw.githubusercontent.com/');
      if (github) {
        add('https://gh-proxy.com/$url');
      }
      add(url);
    }

    addWithMirrors(pack.url);
    addWithMirrors(pack.fallbackUrl);
    return urls;
  }

  static String? _cachedProxy;
  static bool _proxyChecked = false;

  /// 读取系统代理：Dart 的 HttpClient 默认不跟随 Windows 系统代理，
  /// 国内直连 GitHub Release 很容易失败。
  static Future<String?> _systemProxy() async {
    if (_proxyChecked) return _cachedProxy;
    _proxyChecked = true;
    for (final key in const [
      'HTTPS_PROXY',
      'https_proxy',
      'HTTP_PROXY',
      'http_proxy',
      'ALL_PROXY',
      'all_proxy',
    ]) {
      final value = Platform.environment[key];
      if (value == null || value.trim().isEmpty) continue;
      final parsed = _proxyDirective(value);
      if (parsed != null) return _cachedProxy = parsed;
    }
    if (!Platform.isWindows) return null;
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    try {
      final enable = await Process.run('reg', [
        'query',
        key,
        '/v',
        'ProxyEnable',
      ]);
      final match = RegExp(r'ProxyEnable\s+REG_DWORD\s+0x([0-9a-fA-F]+)')
          .firstMatch(enable.stdout.toString());
      if (match == null || int.tryParse(match.group(1)!, radix: 16) != 1) {
        return null;
      }
      final server = await Process.run('reg', [
        'query',
        key,
        '/v',
        'ProxyServer',
      ]);
      final value = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)')
          .firstMatch(server.stdout.toString())
          ?.group(1)
          ?.trim();
      if (value == null || value.isEmpty) return null;
      return _cachedProxy = _proxyDirective(value);
    } catch (_) {
      return null;
    }
  }

  static String? _proxyDirective(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.contains('=')) {
      final map = <String, String>{};
      for (final part in value.split(';')) {
        final index = part.indexOf('=');
        if (index <= 0) continue;
        map[part.substring(0, index).trim().toLowerCase()] = part
            .substring(index + 1)
            .trim();
      }
      value = map['https'] ?? map['http'] ?? map['socks'] ?? '';
      if (value.isEmpty) return null;
    }
    if (value.toLowerCase().startsWith('socks')) {
      final hostPort = value.replaceFirst(
        RegExp(r'^socks(5)?(h)?://', caseSensitive: false),
        '',
      );
      return hostPort.isEmpty ? null : 'SOCKS $hostPort';
    }
    final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.port;
    return 'PROXY ${uri.host}:${port == 0 ? 80 : port}';
  }

  static bool _looksLikeFont(Uint8List bytes) {
    if (bytes.length < 1024) return false;
    if (bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0) {
      return true; // TrueType
    }
    if (bytes.length < 4) return false;
    final sig = String.fromCharCodes(bytes.sublist(0, 4));
    return sig == 'OTTO' || sig == 'true' || sig == 'ttcf';
  }

  static HeroFontRole? _roleFromId(String id) {
    for (final role in HeroFontRole.values) {
      if (role.name == id) return role;
    }
    // 兼容上一版槽位名，已下载的字体不至于失效。
    return switch (id) {
      'jaBrush' => HeroFontRole.jaCrime,
      'jaMincho' => HeroFontRole.jaDrama,
      'koSerif' => HeroFontRole.koDrama,
      'latinDisplay' => HeroFontRole.latinAction,
      _ => null,
    };
  }
}
