import 'dart:io';

import '../../core/logging/app_log.dart';

/// 桌面端可用的第三方播放器（自动探测或用户手动选择）。
class ExternalPlayer {
  const ExternalPlayer({
    required this.id,
    required this.name,
    required this.path,
    this.isCustom = false,
  });

  final String id;
  final String name;
  final String path;

  /// 用户在设置里手动添加（不依赖安装探测）。
  final bool isCustom;
}

/// 从可执行文件名推断播放器类型，用于决定起播参数；未知类型返回 `custom`。
String externalPlayerKind(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final base = name.endsWith('.exe')
      ? name.substring(0, name.length - 4)
      : name;
  if (base.startsWith('potplayer')) return 'potplayer';
  if (base == 'vlc') return 'vlc';
  if (base.startsWith('mpv')) return 'mpv';
  if (base.startsWith('mpc-hc') || base.startsWith('mpc_hc')) return 'mpc-hc';
  return 'custom';
}

/// 播放器显示名：可执行文件名去掉 `.exe`。
String externalPlayerDisplayName(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.trim();
  if (name.isEmpty) return '播放器';
  return name.toLowerCase().endsWith('.exe')
      ? name.substring(0, name.length - 4)
      : name;
}

/// 路径当前是否存在（避免把已删除的播放器当成可用）。
bool externalPlayerExists(String path) {
  if (path.trim().isEmpty) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

/// 候选路径（顺序 = 优先级）。注入环境变量便于单测。
List<ExternalPlayer> playerCandidates(Map<String, String> env) {
  final pf = env['ProgramFiles'] ?? r'C:\Program Files';
  final pf86 = env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
  final la = env['LOCALAPPDATA'] ?? '';
  final out = <ExternalPlayer>[];
  void add(String id, String name, String path) {
    if (path.trim().isEmpty) return;
    out.add(ExternalPlayer(id: id, name: name, path: path));
  }

  add('potplayer', 'PotPlayer', '$pf\\DAUM\\PotPlayer\\PotPlayerMini64.exe');
  add('potplayer', 'PotPlayer', '$pf\\PotPlayer\\PotPlayerMini64.exe');
  if (la.isNotEmpty) {
    add(
      'potplayer',
      'PotPlayer',
      '$la\\Programs\\PotPlayer\\PotPlayerMini64.exe',
    );
  }
  add('potplayer', 'PotPlayer', '$pf\\DAUM\\PotPlayer\\PotPlayerMini.exe');
  add('vlc', 'VLC', '$pf\\VideoLAN\\VLC\\vlc.exe');
  add('vlc', 'VLC', '$pf86\\VideoLAN\\VLC\\vlc.exe');
  if (la.isNotEmpty) add('vlc', 'VLC', '$la\\Programs\\VideoLAN\\VLC\\vlc.exe');
  add('mpv', 'mpv', '$pf\\mpv\\mpv.exe');
  add('mpv', 'mpv.net', '$pf\\mpv.net\\mpvnet.exe');
  if (la.isNotEmpty) add('mpv', 'mpv', '$la\\Programs\\mpv\\mpv.exe');
  add('mpc-hc', 'MPC-HC', '$pf\\K-Lite Codec Pack\\MPC-HC64\\mpc-hc64.exe');
  add('mpc-hc', 'MPC-HC', '$pf\\MPC-HC\\mpc-hc64.exe');
  add('mpc-hc', 'MPC-HC', '$pf86\\K-Lite Codec Pack\\MPC-HC64\\mpc-hc64.exe');
  return out;
}

/// 过滤真实存在的路径（同路径只留第一个）。
List<ExternalPlayer> pickPlayers(
  List<ExternalPlayer> candidates,
  bool Function(String path) exists,
) {
  final out = <ExternalPlayer>[];
  final seen = <String>{};
  for (final candidate in candidates) {
    final key = candidate.path.toLowerCase();
    if (!seen.add(key)) continue;
    try {
      if (exists(candidate.path)) out.add(candidate);
    } catch (_) {
      // 路径非法 → 跳过
    }
  }
  return out;
}

/// 运行时探测；用户手动添加的播放器排在自动探测结果前面。
///
/// [custom] 只要求可执行文件路径（无需注册或安装记录）；同路径只保留第一个。
/// 非 Windows 返回空。
List<ExternalPlayer> detectExternalPlayers({
  List<ExternalPlayer> custom = const [],
}) {
  if (!Platform.isWindows) return const [];
  final merged = <ExternalPlayer>[];
  final seen = <String>{};
  for (final player in custom) {
    final path = player.path.trim();
    if (path.isEmpty || !seen.add(path.toLowerCase())) continue;
    final kind = player.id.trim().isEmpty || player.id == 'custom'
        ? externalPlayerKind(path)
        : player.id;
    final name = player.name.trim();
    merged.add(
      ExternalPlayer(
        id: kind,
        name: name.isEmpty ? externalPlayerDisplayName(path) : name,
        path: path,
        isCustom: true,
      ),
    );
  }
  final installed = pickPlayers(playerCandidates(Platform.environment), (path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  });
  for (final player in installed) {
    if (!seen.add(player.path.toLowerCase())) continue;
    merged.add(player);
  }
  return merged;
}

/// 「从第 N 秒起播」的命令行参数（各播放器语法不兼容，未知播放器不传）。
List<String> externalSeekArgs(String playerId, int seconds) {
  final s = seconds <= 0 ? 0 : seconds;
  if (s <= 0) return const [];
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final hhmmss =
      '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  switch (playerId) {
    case 'potplayer':
      return ['/seek=$hhmmss'];
    case 'vlc':
      return ['--start-time=$s'];
    case 'mpv':
      return ['--start=$s'];
  }
  return const [];
}

/// 拉起外部播放器（分离进程：应用退出不带走播放器）。
///
/// 返回 false 只代表「参数层面就没法启动」（非 Windows / 文件不存在 / 同步抛错）。
/// 进程真正能否起来是异步的，这里通过 [onLaunchError] 回调把失败原因交出去，
/// 调用方可以据此提示用户并写日志——见 `_tryDefaultExternalPlayer`。
bool launchExternalPlayer(
  String path,
  String url, {
  List<String> extraArgs = const [],
  void Function(Object error)? onLaunchError,
}) {
  // 每次启动都记一行：外部播放器最容易「点了没反应」，没有这条日志就完全
  // 无法判断是没发起、发起失败、还是播放器自己起来了但不显示窗口。
  AppLog.i(
    'external',
    '启动外部播放器 path=$path args=${[...extraArgs, url].join(' ')}',
  );
  if (!Platform.isWindows) {
    AppLog.w('external', '非 Windows 平台，不支持外部播放器');
    return false;
  }
  if (!externalPlayerExists(path)) {
    AppLog.w('external', '播放器文件不存在：$path');
    return false;
  }
  try {
    Process.start(path, [
      ...extraArgs,
      url,
    ], mode: ProcessStartMode.detached).then(
      (_) {},
      onError: (Object e) {
        // 以前这里把错误整个吞掉，函数还会返回 true —— UI 认为成功、不回退、
        // 也不提示，用户看到的就是「点了没反应」。现在交回调用方处理。
        AppLog.e('external', '外部播放器启动失败 path=$path', e);
        onLaunchError?.call(e);
      },
    );
    return true;
  } catch (e) {
    AppLog.e('external', '外部播放器启动抛错 path=$path', e);
    return false;
  }
}
