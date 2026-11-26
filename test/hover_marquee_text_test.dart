import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/ui/widgets/hover_marquee_text.dart';

void main() {
  testWidgets('长标题悬停后循环滚动，移出后恢复省略号', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 110,
              child: HoverMarqueeText(
                '这是一个特别长的体育比赛直播标题',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('这是一个特别长的体育比赛直播标题'), findsOneWidget);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(HoverMarqueeText)),
    );
    await tester.pump();

    // 悬停后渲染首尾两份文本，配合横向位移动画形成无缝循环。
    expect(find.text('这是一个特别长的体育比赛直播标题'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 2));

    await gesture.moveTo(Offset.zero);
    await tester.pump();
    await gesture.removePointer();

    expect(find.text('这是一个特别长的体育比赛直播标题'), findsOneWidget);
  });

  testWidgets('外层卡片悬停也能触发标题滚动', (tester) async {
    var hover = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: StatefulBuilder(
              builder: (context, setState) {
                return MouseRegion(
                  onEnter: (_) => setState(() => hover = true),
                  onExit: (_) => setState(() => hover = false),
                  child: SizedBox(
                    width: 110,
                    child: HoverMarqueeText(
                      '另一个特别长的体育比赛直播标题',
                      externalHover: hover,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('另一个特别长的体育比赛直播标题'), findsOneWidget);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(HoverMarqueeText)),
    );
    await tester.pump();

    expect(find.text('另一个特别长的体育比赛直播标题'), findsNWidgets(2));

    await gesture.moveTo(const Offset(400, 400));
    await tester.pump();
    await gesture.removePointer();

    expect(find.text('另一个特别长的体育比赛直播标题'), findsOneWidget);
  });

  testWidgets('短标题悬停不启动滚动', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: HoverMarqueeText('短标题', style: TextStyle(fontSize: 16)),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(HoverMarqueeText)),
    );
    await tester.pump();

    expect(find.text('短标题'), findsOneWidget);
    await gesture.removePointer();
  });

  // 回归：曾经用 `TextPainter.height` 撑外层 SizedBox，而 painter 只算字体的
  // em 高度（字号 13 → 13px），`Text` 实际要 19px。差值那 6px 没有位置，
  // 文字的 descender 被裁掉，表现为「按钮 / 分类名文字下半截看不见」。
  group('高度不能小于 Text 的自然高度', () {
    for (final fontSize in <double>[12, 13, 14, 16]) {
      testWidgets('字号 $fontSize', (tester) async {
        // 用「中文字符 + 贴底渲染」的场景，descender 一旦被裁最明显。
        const sample = '央视频道';
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 138,
                  child: HoverMarqueeText(
                    sample,
                    style: TextStyle(fontSize: fontSize),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final marqueeHeight = tester
            .getSize(find.byType(HoverMarqueeText))
            .height;

        // 基准：同样宽度 / 字号 / 单行约束下的原生 Text。
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 138,
                  child: Text(
                    sample,
                    maxLines: 1,
                    style: TextStyle(fontSize: fontSize),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final textHeight = tester.getSize(find.byType(Text)).height;

        expect(
          marqueeHeight,
          textHeight,
          reason: 'HoverMarqueeText 必须与原生 Text 等高，否则文字缺一截',
        );
      });
    }

    testWidgets('被截断而显示省略号时也保持自然高度', (tester) async {
      // 宽度只够显示两三个字，会走 ellipsis 分支。
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 40,
                child: HoverMarqueeText(
                  '一个很长很长会被截断的频道名称',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final marqueeHeight = tester
          .getSize(find.byType(HoverMarqueeText))
          .height;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 40,
                child: Text(
                  '一个很长很长会被截断的频道名称',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(marqueeHeight, tester.getSize(find.byType(Text)).height);
    });
  });
}
