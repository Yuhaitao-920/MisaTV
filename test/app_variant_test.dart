import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/app_variant.dart';

/// TV 精简版的编译期开关。
///
/// 这套开关决定「哪些界面与资源会被打进包」，是 TV 版本的核心开关，
/// 所以行为要明确定义并守住，避免以后有人把两边写反。
///
/// 注意：这两个常量是 `bool.fromEnvironment`，值由 `--dart-define` 决定，
/// 无法在运行时改变。所以断言要写成「两者互斥且取值合法」，而不是硬编码
/// 某个具体值 —— 否则 CI 用 `--dart-define=MISA_TV=true` 跑测试时会挂。
void main() {
  test('全功能与 TV 两个开关互斥', () {
    expect(
      kMisaTv != kMisaFull,
      isTrue,
      reason: '必须一真一假：要么全功能，要么 TV，不能同时为真或同假',
    );
  });

  test('由 --dart-define=MISA_TV 控制，默认是全功能', () {
    // 本进程没传 MISA_TV 时应当是全功能版。
    // 传了的话 ctv 为 true —— 两种情况都只断言「一致」，不做硬编码。
    const declaredTv = bool.fromEnvironment('MISA_TV');
    expect(kMisaTv, declaredTv);
    expect(kMisaFull, !declaredTv);
  });
}
