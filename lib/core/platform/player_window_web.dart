import '../../services/player/player_window_session.dart';

/// Web 版不能创建独立播放器窗口。
bool get supportsStandalonePlayerWindow => false;

Future<String?> standalonePlayerWindowArgument() async => null;

Future<bool> openStandalonePlayerWindow({
  required PlayerWindowPayload payload,
}) async => false;

Future<void> setupStandalonePlayerWindow({required String title}) async {}

Future<void> registerMainPlayerWindowBridge({
  required Future<void> Function() onSync,
  required Future<void> Function(String keyword) onSearch,
  required Future<void> Function() onClosed,
}) async {}

Future<void> notifyMainPlayerWindow(String method, {Object? arguments}) async {}

Future<void> registerPlayerWindowControls({
  required Future<void> Function() onClose,
}) async {}

Future<void> closeStandalonePlayerWindowNow() async {}

Future<void> closeAllStandalonePlayerWindows() async {}

Future<void> deletePlayerWindowPayload(String path) async {}
