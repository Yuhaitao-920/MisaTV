import 'package:flutter/material.dart';

import 'detail_opener.dart';
import 'pages/detail_page.dart';

/// 全功能版的详情页打开器：用完整的 `DetailPage`。
///
/// 只有 `main.dart` import 这个文件；`main_tv.dart` 走 `detail_tv.dart`，
/// 于是完整的 `detail_page.dart`（4152 行）不会进 TV 构建的依赖闭包。
void installFullDetailOpener() {
  installDetailOpener((
    context,
    item, {
    required autoPlay,
    required fromStart,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            DetailPage(item: item, autoPlay: autoPlay, fromStart: fromStart),
      ),
    );
  });
}
