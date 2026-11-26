import 'package:flutter/material.dart';

import 'detail_opener.dart';
import 'tv_detail_page.dart';

/// TV 版的详情页打开器：用精简的 `TvDetailPage`。
///
/// 只有 `main_tv.dart` import 这个文件。它**不 import `pages/detail_page.dart`**，
/// 所以完整的详情页（4152 行，含剧照墙 / 演职员 / 影评等额外请求）不会进
/// TV 构建的依赖闭包。
void installTvDetailOpener() {
  installDetailOpener((
    context,
    item, {
    required autoPlay,
    required fromStart,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            TvDetailPage(item: item, autoPlay: autoPlay, fromStart: fromStart),
      ),
    );
  });
}
