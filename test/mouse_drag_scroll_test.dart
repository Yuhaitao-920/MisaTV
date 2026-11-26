import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/ui/widgets/mouse_drag_scroll.dart';

/// 单行横向列表：桌面端默认不让鼠标拖动，套上 MouseDragScrollBehavior 才可以。
Widget harness({required bool draggable}) {
  final list = SizedBox(
    height: 44,
    child: ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: 40,
      itemBuilder: (_, index) => SizedBox(width: 60, child: Text('item$index')),
    ),
  );
  return MaterialApp(
    home: Scaffold(
      body: draggable
          ? ScrollConfiguration(
              behavior: const MouseDragScrollBehavior(),
              child: list,
            )
          : list,
    ),
  );
}

Future<double> dragWithMouse(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(ListView)),
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  );
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
  final state = tester.state<ScrollableState>(
    find.byWidgetPredicate((w) => w is Scrollable),
  );
  return state.position.pixels;
}

void main() {
  testWidgets('默认行为：鼠标按住拖不动横向列表', (tester) async {
    await tester.pumpWidget(harness(draggable: false));
    await tester.pumpAndSettle();
    expect(await dragWithMouse(tester), 0);
  });

  testWidgets('MouseDragScrollBehavior：鼠标按住可以拖动横向列表', (tester) async {
    await tester.pumpWidget(harness(draggable: true));
    await tester.pumpAndSettle();
    expect(await dragWithMouse(tester), greaterThan(0));
  });
}
