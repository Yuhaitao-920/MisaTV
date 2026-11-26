import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../models/vod.dart';
import '../../state/app_state.dart';
import '../services/mpv_extension.dart';
import '../services/player/external_players.dart';

/// 把播放地址交给「默认播放器」的统一入口。
///
/// 之前这段逻辑只写在详情页（`_tryDefaultExternalPlayer`），于是**从历史页、
/// 收藏页、raw_play 进入播放时完全绕过它** —— 无论设置里选了 PotPlayer 还是
/// MPV，那些入口一律开内置播放器。用户看到的就是「设置不生效」。
///
/// 现在抽出来放在 `openVodPlayer` 里统一调用，所有入口行为一致。
///
/// 约定：返回 true 表示已经交给外部播放器（调用方不要再开内置），
/// false 表示应该继续走内置播放器。
class DefaultExternalPlayer {
  const DefaultExternalPlayer._();

  /// 尝试用设置里的默认播放器打开 [play]。
  ///
  /// [onMessage] 用于向用户提示进度 / 失败原因（可空，例如无 UI 的批处理场景）。
  /// [isAlive] 让调用方能在异步等待后判断界面是否还在（避免 setState 到已销毁的页面）。
  static Future<bool> tryOpen({
    required AppState app,
    required SourceBean site,
    required VodDetail detail,
    required String flag,
    required int index,
    required List<Episode> episodes,
    required PlayResult play,
    required int startMs,
    void Function(String message)? onMessage,
    bool Function()? isAlive,
  }) async {
    final setting = app.playerSettings.defaultPlayer;
    // 外部播放器「点了没反应」时日志是唯一排查依据：把每一步决策都记下来，
    // 排查时直接搜 `[external]`。
    final normalized = normalizeDefaultPlayer(setting);
    AppLog.i(
      'external',
      '默认播放器设置=$setting 归一化=$normalized '
          '自定义路径=${app.playerSettings.defaultCustomPlayerPathValue}',
    );
    if (normalized == kDefaultPlayerBuiltin) {
      AppLog.i('external', '设置为内置播放器，跳过外部播放器');
      return false;
    }

    final resource = '${detail.sourceKey}|${detail.id}';
    final rawName = index >= 0 && index < episodes.length
        ? episodes[index].name.trim()
        : '';
    final episodeKey = rawName.isEmpty ? '第${index + 1}集' : rawName;
    // 全局无痕模式与内置播放器的临时会话一致：不套用跳过片头片尾。
    final skip = app.playerSettings.incognito
        ? null
        : app.skipFor(resource, episodeKey);
    final effectiveStart = startMs > 0 ? startMs : (skip?.intro ?? 0) * 1000;
    final seconds = effectiveStart ~/ 1000;
    final source = app.preparePlay(play, forceRelay: true);
    AppLog.i(
      'external',
      '准备交给外部播放器 playable=${play.playable} '
          'url=${redactUrl(play.url)} → 中继后=${redactUrl(source.url)} '
          'headers=${source.headers.keys.join(',')}',
    );

    // PotPlayer 等外部播放器打开 `/chunk` 会并发多条探针，先做一次预热，
    // 避免壳内取流服务在会话登记前后互相覆盖，最终一直加载。
    if (play.url.contains('/chunk') && play.url.contains('127.0.0.1')) {
      onMessage?.call('正在准备取流地址…');
    }
    final warmed = await app.sourceService.jar.warmUpLocalPlayUrl(play.url);
    AppLog.i('external', '壳内取流预热=${warmed ? '成功/不需要' : '失败'}');
    if (!warmed) {
      onMessage?.call('取流地址准备失败，已改用内置播放器');
      return false;
    }

    final isMpv = setting == kDefaultPlayerYaozhiMpv;
    final customPath = app.playerSettings.defaultCustomPlayerPathValue;
    var playerName = isMpv
        ? 'Yaozhi MPV'
        : externalPlayerDisplayName(customPath);

    // 多集时把整份选集列表交给外部播放器（M3U 每项回指本机中继）。
    final service = app.externalPlaylist;
    final playlist = service == null || episodes.length < 2
        ? null
        : await service.createPlaylist(
            site: site,
            flag: flag,
            episodes: episodes,
            currentIndex: index,
            currentUrl: source.url,
          );
    final playlistLabel = playlist ?? '未生成（单集或中继未就绪）';
    AppLog.i(
      'external',
      '选集列表=$playlistLabel 集数=${episodes.length} 起播秒=$seconds',
    );

    try {
      if (isMpv) {
        final exe = await MpvExtension.instance.executablePath;
        AppLog.i('external', 'MPV 可执行文件=$exe');
        if (exe.isEmpty) {
          AppLog.w('external', 'MPV 未安装（executablePath 为空），回退内置播放器');
          onMessage?.call('Yaozhi MPV 未安装，已改用内置播放器');
          return false;
        }
        await MpvExtension.instance.open(
          playlist ?? source.url,
          headers: playlist == null ? source.headers : const {},
          startSeconds: playlist == null ? seconds : 0,
        );
        AppLog.i('external', 'MPV 已拉起');
      } else {
        if (customPath.isEmpty) {
          AppLog.w('external', '自定义播放器路径为空，回退内置播放器');
          return false;
        }
        if (!externalPlayerExists(customPath)) {
          AppLog.w('external', '自定义播放器文件不存在：$customPath，回退内置播放器');
          onMessage?.call('默认第三方播放器文件不存在，已改用内置播放器');
          return false;
        }
        for (final entry in app.playerSettings.externalPlayers) {
          if (entry.path.trim().toLowerCase() == customPath.toLowerCase()) {
            final name = entry.name.trim();
            playerName = name.isEmpty
                ? externalPlayerDisplayName(entry.path)
                : name;
            break;
          }
        }
        final ok = launchExternalPlayer(
          customPath,
          playlist ?? source.url,
          extraArgs: playlist == null
              ? externalSeekArgs(externalPlayerKind(customPath), seconds)
              : const [],
          // 进程起不来时（权限 / 杀软拦截 / 路径含特殊字符）以前完全静默，
          // 现在至少能在界面上看到原因，日志里有完整堆栈。
          onLaunchError: (e) => onMessage?.call('$playerName 启动失败：$e'),
        );
        if (!ok) {
          AppLog.w(
            'external',
            'launchExternalPlayer 返回 false（$playerName），回退内置播放器',
          );
          onMessage?.call('启动 $playerName 失败，已改用内置播放器');
          return false;
        }
        AppLog.i('external', '$playerName 启动指令已发出');
      }
    } catch (e) {
      AppLog.e('external', '启动 $playerName 抛异常', e);
      onMessage?.call('启动 $playerName 失败：$e');
      return false;
    }

    // 播放器已经拉起，历史记录失败不能再回退内置（否则会同时出现两个播放器）。
    app.sourceService.jar.holdPlaybackForExternal();
    AppLog.i('external', '外部播放器流程完成 player=$playerName，不再进入内置播放器');
    if (app.playerSettings.incognito) {
      // 全局无痕模式：外部播放器同样不写观看历史。
      onMessage?.call('已在 $playerName 中打开（无痕模式，未记录历史）');
      return true;
    }
    try {
      await app.recordHistory(
        detail: detail,
        site: site,
        flag: flag,
        episodeName: episodeKey,
        episodeIndex: index,
        url: play.url,
        rawUrl: index >= 0 && index < episodes.length
            ? episodes[index].url
            : play.url,
        headers: play.headers,
        positionMs: effectiveStart,
      );
    } catch (_) {
      // 历史写入失败不影响本次外部播放
    }
    onMessage?.call('已在 $playerName 中打开');
    return true;
  }
}
