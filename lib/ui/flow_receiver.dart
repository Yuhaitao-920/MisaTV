import 'package:flutter/material.dart';

import '../core/logging/app_log.dart';
import '../models/site_config.dart';
import '../models/vod.dart';
import '../services/lan/flow_payload.dart';
import '../state/app_state.dart';
import 'open_player.dart';
import 'pages/player_page.dart';

/// 接收端：把别的设备推来的流转接住并播放。
///
/// 设计要点：
///   1. **用合成的站点 / 详情**，不依赖本机有没有相同订阅 —— 流转只传地址，
///      所以接收方不需要装同样的源。
///   2. 会话标记为 `ephemeral`：不写观看历史（历史由推送方在退出时同步过来），
///      避免两端各写一份、合并时出现重复。
///   3. 播完 / 退出播放后触发一次 WebDAV 同步（[AppState.syncHistoryAfterFlow]），
///      这样推送方的历史才能合并到远端、其它设备也能续播。
///
/// [navigatorKey] 用于在没有页面 context 的地方打开播放器（服务端回调没有 context）。
class FlowReceiver {
  const FlowReceiver._();

  /// 安装接收处理器。返回上一次安装的处理器，便于测试或多实例场景还原。
  static Future<String?> Function(FlowPayload)? install(
    AppState app, {
    required GlobalKey<NavigatorState> navigatorKey,
    Future<void> Function(FlowPayload payload)? onAfterClose,
  }) {
    final previous = app.onFlowRequest;
    app.onFlowRequest = (payload) async {
      final context = navigatorKey.currentContext;
      if (context == null) return '本机界面尚未就绪，请稍后重试';
      // 正在播放时先让用户确认：直接打断当前播放会很唐突。
      if (app.isPlayingSomething &&
          !await _confirmInterrupt(context, payload)) {
        return '对方已取消';
      }
      if (!context.mounted) return '本机界面已关闭';
      await _openFlow(context, app, payload);
      // 播放结束（用户退出播放器）后同步一次历史。
      if (!payload.sentAtMs.isNegative) {
        try {
          await app.syncHistoryAfterFlow();
        } catch (_) {
          // 已在内部记日志，这里不再打扰用户
        }
        await onAfterClose?.call(payload);
      }
      return null;
    };
    AppLog.i('lan', '设备流转接收器已安装');
    return previous;
  }

  static Future<bool> _confirmInterrupt(
    BuildContext context,
    FlowPayload payload,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('收到设备流转'),
        content: Text(
          '${payload.fromDevice} 想把《${payload.vodName}》'
          '${payload.episodeName.isEmpty ? '' : '· ${payload.episodeName}'}'
          '推送到本机播放。\n\n'
          '本机正在播放，继续会中断当前播放。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('开始播放'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  static Future<void> _openFlow(
    BuildContext context,
    AppState app,
    FlowPayload payload,
  ) async {
    final episodes = <Episode>[
      Episode(
        name: payload.episodeName.isEmpty ? '流转' : payload.episodeName,
        url: payload.url,
      ),
    ];
    // 合成一个临时站点：key 用流转来源，避免与真实站点冲突；
    // api 为空 => 不会触发任何网络取链。
    final site = SourceBean(
      key: payload.sourceKey.isEmpty
          ? '__flow__'
          : '__flow_${payload.sourceKey}',
      name: payload.sourceName.isEmpty ? '设备流转' : payload.sourceName,
      type: 0,
      api: '',
    );
    final session = PlayerSession(
      detail: payload.toSyntheticDetail(episodes),
      site: site,
      flag: payload.flowFlag,
      episodeIndex: 0,
      episodes: episodes,
      initialPlay: payload.toPlayResult(),
      startPositionMs: payload.positionMs,
      // 不写历史：避免两端各写一份。
      ephemeral: true,
    );
    await openVodPlayer(context, app, session, rootNavigator: true);
  }
}
