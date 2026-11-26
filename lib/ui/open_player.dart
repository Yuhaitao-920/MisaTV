import 'package:flutter/material.dart';

import '../core/platform/player_window.dart';
import '../models/live.dart';
import '../models/site_config.dart';
import '../services/live/epg.dart';
import '../services/player/player_window_session.dart';
import '../state/app_state.dart';
import 'default_external_player.dart';
import 'pages/live_player_page.dart';
import 'pages/player_page.dart';

/// 内置播放器是否应该开在独立窗口里。
///
/// 沉浸观影模式始终用主窗口内嵌播放器；Web / 移动端没有多窗口能力。
bool shouldUseStandalonePlayer(AppState app) =>
    supportsStandalonePlayerWindow && app.playerSettings.effectivePopOutPlayer;

/// 统一的点播播放入口。
///
/// **顺序很重要**：先尝试「设置里的默认播放器」（外部播放器 / MPV），
/// 只有它明确拒绝时才开内置播放器。
///
/// 以前这段判断只写在详情页，历史页 / 收藏页 / raw_play 这些入口直接调
/// 本函数，于是无论设置选了什么都会开内置播放器 —— 用户感受就是
/// 「外部播放器设置不生效」。现在所有入口共用同一条判断。
Future<void> openVodPlayer(
  BuildContext context,
  AppState app,
  PlayerSession session, {
  bool rootNavigator = false,
}) async {
  // 沉浸观影 / 独立窗口模式不接管外部播放器：那条路径本身就是「用内置内核
  // 开子窗口」，再跳外部播放器会让人失去窗口内的一切控制。
  if (!shouldUseStandalonePlayer(app) && session.initialPlay != null) {
    final opened = await DefaultExternalPlayer.tryOpen(
      app: app,
      site: session.site,
      detail: session.detail,
      flag: session.flag,
      index: session.episodeIndex,
      episodes: session.episodes,
      play: session.initialPlay!,
      startMs: session.startPositionMs,
      onMessage: context.mounted ? (m) => _showPlayerMessage(context, m) : null,
      isAlive: () => context.mounted,
    );
    if (opened) return;
  }
  if (shouldUseStandalonePlayer(app)) {
    // 首播地址可能已经指向主窗口 JVM 的本机 /chunk：子窗口播放期间不能回收。
    app.sourceService.jar.holdPlaybackForExternal();
    final opened = await openStandalonePlayerWindow(
      payload: PlayerWindowPayload.vod(
        VodWindowSession(
          detail: session.detail,
          site: session.site,
          flag: session.flag,
          episodeIndex: session.episodeIndex,
          episodes: session.episodes,
          initialPlay: session.initialPlay,
          startPositionMs: session.startPositionMs,
          ephemeral: session.ephemeral,
        ),
      ),
    );
    if (opened) return;
    // 窗口创建失败时退回原来的内嵌播放器，不能让点击没有反应。
  }
  if (!context.mounted) return;
  await Navigator.of(
    context,
    rootNavigator: rootNavigator,
  ).push(MaterialPageRoute(builder: (_) => PlayerPage(session: session)));
}

/// 播放器提示：优先用 ScaffoldMessenger，没有 Scaffold 时静默忽略。
void _showPlayerMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

Future<void> openLivePlayer(
  BuildContext context,
  AppState app, {
  required LiveBean bean,
  required LiveChannel channel,
  required LiveLine initialLine,
  EpgEntry? epg,
  List<LiveGroup> groups = const [],
  Map<String, EpgEntry> epgEntries = const {},
  String initialGroup = '',
}) async {
  if (shouldUseStandalonePlayer(app)) {
    final opened = await openStandalonePlayerWindow(
      payload: PlayerWindowPayload.live(
        LiveWindowSession(
          bean: bean,
          channel: channel,
          initialLine: initialLine,
          epg: epg,
          groups: groups,
          epgEntries: epgEntries,
          initialGroup: initialGroup,
        ),
      ),
    );
    if (opened) return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => LivePlayerPage(
        bean: bean,
        channel: channel,
        initialLine: initialLine,
        epg: epg,
        groups: groups,
        epgEntries: epgEntries,
        initialGroup: initialGroup,
      ),
    ),
  );
}
