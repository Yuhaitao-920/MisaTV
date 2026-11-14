import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../core/app_version.dart';
import '../../core/logging/app_log.dart';
import '../../core/net/proxy_config.dart';
import '../../core/net/proxy_runtime.dart';
import '../../core/platform/player_window.dart';
import '../../core/platform/window_service.dart';
import '../../models/dav.dart';
import '../../models/player_fit.dart';
import '../../models/site_config.dart';
import '../../models/source_health.dart';
import '../../models/user_data.dart';
import '../../services/artwork/artwork_service.dart';
import '../../services/artwork/tmdb_auth.dart';
import '../../services/backup_data.dart';
import '../../services/boss_key/boss_key_service.dart';
import '../../services/content_filter.dart';
import '../../services/update/update_service.dart';
import '../../services/danmaku/danmaku_endpoints.dart';
import '../../services/danmaku/danmaku_models.dart';
import '../../services/danmaku/danmaku_settings.dart';
import '../../services/drive_login_service.dart';
import '../../services/file_dialog_service.dart';
import '../../services/jvm/arm_bridge_runtime.dart';
import '../../services/kazumi/kazumi_rule.dart';
import '../../services/local_import_service.dart';
import '../../services/local_live_service.dart';
import '../../services/jvm/jvm_runtime.dart';
import '../../services/mpv_extension.dart';
import '../../services/player/external_players.dart';
import '../../services/py_runtime_service.dart';
import '../../services/relay/local_relay.dart';
import '../../services/runtime_extension.dart';
import '../../state/app_state.dart';
import '../widgets/drive_cookie_dialog.dart';
import '../widgets/drive_web_login_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/import_sheet.dart';
import '../widgets/name_input_dialog.dart';
import '../widgets/proxy_pool_sheet.dart';
import '../widgets/uc_tv_login_dialog.dart';
import '../widgets/update_dialog.dart';
import '../widgets/xunlei_login_dialog.dart';
import 'dav_browse_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey<_SectionState> _playSectionKey = GlobalKey<_SectionState>();
  final GlobalKey<_JvmRuntimeTileState> _jvmTileKey =
      GlobalKey<_JvmRuntimeTileState>();
  final GlobalKey<_ArmBridgeTileState> _guardTileKey =
      GlobalKey<_ArmBridgeTileState>();
  final GlobalKey<_PythonRuntimeTileState> _pythonTileKey =
      GlobalKey<_PythonRuntimeTileState>();

  /// 当前父分类（分页）。原有分类都挂在下面四个父分类里。
  int _pageIndex = 0;

  static const int _contentPage = 0;
  static const int _playPage = 1;
  static const int _accountPage = 2;
  static const int _safetyPage = 3;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _selectPage(int index) {
    if (index == _pageIndex) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _pageIndex = index);
  }

  /// 展开「播放」并滚动到对应扩展卡片，然后开始下载。
  Future<void> revealRuntime(RuntimeExtension kind) async {
    if (_pageIndex != _playPage) {
      _selectPage(_playPage);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    _playSectionKey.currentState?.expand();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final target = switch (kind) {
      RuntimeExtension.jvm => _jvmTileKey.currentContext,
      RuntimeExtension.guard => _guardTileKey.currentContext,
      RuntimeExtension.python => _pythonTileKey.currentContext,
    };
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        alignment: 0.08,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    switch (kind) {
      case RuntimeExtension.jvm:
        await _jvmTileKey.currentState?.startInstall();
      case RuntimeExtension.guard:
        await _guardTileKey.currentState?.startInstall();
      case RuntimeExtension.python:
        await _pythonTileKey.currentState?.startInstall();
    }
  }

  /// 网盘登录/凭据集中弹窗：设置页只保留入口，避免主页区块被 Cookie 配置挤满。
  Future<void> _openDriveAccounts(BuildContext context) async {
    final app = AppScope.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('网盘账户'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: app,
              builder: (ctx, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final provider in driveProviderNames.keys)
                    _DriveAccountRow(provider: provider, app: app),
                  const SizedBox(height: 6),
                  Text(
                    '凭据以明文保存在本机，仅用于蜘蛛源取流；换机备份时请勿泄露。',
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurface
                          .withValues(alpha: 0.72),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// WebDAV 服务器管理弹窗（同样从设置页独立出来）。
  Future<void> _openDavServers(BuildContext context) async {
    final app = AppScope.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('WebDAV'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: app,
              builder: (ctx, _) => _DavServerList(app: app),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                narrow ? 18 : 28,
                8,
                narrow ? 18 : 28,
                120,
              ),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '设置',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: 26,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '所有数据都只保存在这台设备上',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_pageIndex == _contentPage)
                      FilledButton.tonalIcon(
                        onPressed: () => showImportConfigSheet(context),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('导入源'),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                _SettingsPager(index: _pageIndex, onChanged: _selectPage),
                const SizedBox(height: 16),
                if (_pageIndex == _contentPage) ...[
                  _Section(
                    title: '订阅配置',
                    icon: Icons.playlist_add_check_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.vodProfiles.length} 个',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _ProfileSummary(app: app),
                    child: app.vodProfiles.isEmpty
                        ? EmptyState(
                            icon: Icons.inbox_outlined,
                            title: '还没有配置',
                            message: '导入 TVBox JSON 订阅开始使用',
                            compact: true,
                            action: FilledButton.tonalIcon(
                              onPressed: () => showImportConfigSheet(context),
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('导入订阅'),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  if (!kIsWeb) ...[
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importLocalJsonFile(context),
                                      icon: const Icon(
                                        Icons.file_open_outlined,
                                        size: 17,
                                      ),
                                      label: const Text('本地 JSON'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importLocalPyFiles(context),
                                      icon: const Icon(
                                        Icons.code_rounded,
                                        size: 17,
                                      ),
                                      label: const Text('本地 PY（可多选）'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importLocalPackage(context),
                                      icon: const Icon(
                                        Icons.folder_open_rounded,
                                        size: 17,
                                      ),
                                      label: const Text('本地包'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _importLocalPackage(
                                        context,
                                        zip: true,
                                      ),
                                      icon: const Icon(
                                        Icons.archive_outlined,
                                        size: 17,
                                      ),
                                      label: const Text('本地包 ZIP'),
                                    ),
                                    TextButton.icon(
                                      onPressed: app.vodProfiles.length < 2
                                          ? null
                                          : () => _exportMerged(context),
                                      icon: const Icon(
                                        Icons.merge_rounded,
                                        size: 17,
                                      ),
                                      label: const Text('合并导出'),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              for (final profile in app.vodProfiles) ...[
                                _ProfileTile(profile: profile, app: app),
                                if (profile != app.vodProfiles.last)
                                  const SizedBox(height: 8),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '站点',
                    icon: Icons.dns_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.usableSites.length} / ${app.config?.sites.length ?? 0} 可用',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _SiteSummary(app: app),
                    child: (app.config?.sites.isEmpty ?? true)
                        ? const EmptyState(
                            icon: Icons.source_outlined,
                            title: '没有站点',
                            message: '导入配置后在这里切换站点',
                            compact: true,
                          )
                        : _SiteList(sites: app.config!.sites, app: app),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Kazumi 规则',
                    icon: Icons.auto_awesome_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.kazumiRules.length} 条',
                      style: theme.textTheme.labelSmall,
                    ),
                    child: app.kazumiRules.isEmpty
                        ? EmptyState(
                            icon: Icons.auto_awesome_outlined,
                            title: '还没有 Kazumi 规则',
                            message: '从官方仓库导入动漫源规则；首页显示每日新番，点开可按片名搜索',
                            compact: true,
                            action: FilledButton.tonalIcon(
                              onPressed: () =>
                                  _importKazumiFromRepo(context, app),
                              icon: const Icon(Icons.cloud_download_outlined),
                              label: const Text('导入官方规则'),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  TextButton.icon(
                                    onPressed: () =>
                                        _importKazumiFromRepo(context, app),
                                    icon: const Icon(
                                      Icons.cloud_download_outlined,
                                      size: 17,
                                    ),
                                    label: const Text('导入官方规则'),
                                  ),
                                  if (!kIsWeb)
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importKazumiFile(context, app),
                                      icon: const Icon(
                                        Icons.file_open_outlined,
                                        size: 17,
                                      ),
                                      label: const Text('本地 JSON'),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              for (final rule in app.kazumiRules)
                                _KazumiRuleRow(
                                  rule: rule,
                                  onDelete: () =>
                                      _deleteKazumiRule(context, app, rule),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '直播源',
                    icon: Icons.live_tv_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.lives.length} 条',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _LiveSummary(app: app),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (app.liveProfiles.isNotEmpty) ...[
                          Text(
                            '直播订阅',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final profile in app.liveProfiles) ...[
                            _ProfileTile(
                              profile: profile,
                              app: app,
                              asLive: true,
                            ),
                            const SizedBox(height: 8),
                          ],
                          const SizedBox(height: 2),
                        ],
                        if (!kIsWeb) ...[
                          TextButton.icon(
                            onPressed: () => showImportConfigSheet(context),
                            icon: const Icon(Icons.link_rounded, size: 17),
                            label: const Text('导入直播订阅（M3U / TXT 地址）'),
                          ),
                          TextButton.icon(
                            onPressed: () => _importLocalLive(context),
                            icon: const Icon(
                              Icons.playlist_add_rounded,
                              size: 17,
                            ),
                            label: const Text('导入本地直播源（TXT / M3U）'),
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (app.lives.isEmpty)
                          EmptyState(
                            icon: Icons.live_tv_outlined,
                            title: '当前没有直播源',
                            message: '导入 M3U / TXT 直播订阅，或使用含 lives 的 JSON 订阅',
                            compact: true,
                            action: kIsWeb
                                ? null
                                : TextButton.icon(
                                    onPressed: () => _importLocalLive(context),
                                    icon: const Icon(
                                      Icons.playlist_add_rounded,
                                    ),
                                    label: const Text('导入本地直播源'),
                                  ),
                          )
                        else
                          _LiveSourceList(lives: app.lives, app: app),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _accountPage && !kIsWeb) ...[
                  // 这两项只弹窗、没有可展开的子内容，但也必须像其他设置分类
                  // 一样落在玻璃卡片里；直接放 ListTile 会变成一条裸露在页面
                  // 背景上的深色长条，和上下卡片之间像被切开。
                  GlassPanel(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                    borderRadius: 24,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ActionRow(
                          icon: Icons.cloud_outlined,
                          title: '网盘账户',
                          subtitle: _driveAccountsSubtitle(app),
                          onTap: () => _openDriveAccounts(context),
                        ),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.35,
                          ),
                        ),
                        _ActionRow(
                          icon: Icons.folder_shared_outlined,
                          title: 'WebDAV',
                          subtitle: '${app.davService.servers.length} 个服务器',
                          onTap: () => _openDavServers(context),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _contentPage &&
                    app.activeReport.items.any((e) => e.status != 'OK')) ...[
                  const SizedBox(height: 16),
                  _Section(
                    title: '导入诊断',
                    icon: Icons.healing_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.activeReport.items.where((e) => e.status != 'OK').length} 条',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '有源被降级或跳过（JAR / PUSH 等），点击展开查看原因',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        for (final item in app.activeReport.items.where(
                          (e) => e.status != 'OK',
                        ))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  item.status == 'SKIP'
                                      ? Icons.remove_circle_outline
                                      : Icons.warning_amber_rounded,
                                  size: 18,
                                  color: item.status == 'SKIP'
                                      ? theme.disabledColor
                                      : theme.colorScheme.error,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${item.name} · ${item.reason ?? item.status}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      Text(
                                        item.message,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.70),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _playPage) ...[
                  _Section(
                    title: '外观',
                    icon: Icons.palette_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      _themeModeLabel(app.themeMode),
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _AppearanceSummary(app: app),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ThemeModeTabs(
                          value: app.themeMode,
                          onChanged: (mode) => app.setThemeMode(mode),
                        ),
                        const SizedBox(height: 18),
                        Text('主题色', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          children: [
                            for (
                              var i = 0;
                              i < AppState.accentPalette.length;
                              i++
                            )
                              _AccentDot(
                                color: AppState.accentPalette[i],
                                selected: app.accentIndex == i,
                                onTap: () => app.setAccentIndex(i),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text('底部横条', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          '常驻时固定在底部；自动隐藏时只在鼠标靠近窗口底部时滑出，并可遮住上方封面',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [
                              (false, '常驻'),
                              (true, '自动隐藏'),
                            ])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.navBarAutoHide == item.$1,
                                onSelected: (_) =>
                                    app.setNavBarAutoHide(item.$1),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('横条大小', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [
                              (0, '紧凑'),
                              (1, '标准'),
                              (2, '较大'),
                              (3, '超大'),
                            ])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.navBarSize == item.$1,
                                onSelected: (_) => app.setNavBarSize(item.$1),
                              ),
                          ],
                        ),
                        const Divider(height: 24),
                        const SizedBox(height: 4),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('沉浸观影模式'),
                          subtitle: const Text(
                            '大屏 TV 布局：首页海报轮播、横图卡片、沉浸式详情页（选集自动匹配 B 站/TMDB 剧照）；播放器保持不变',
                          ),
                          value: app.playerSettings.immersiveMode,
                          onChanged: (value) async {
                            await app.setPlayerSettings(
                              app.playerSettings.copyWith(immersiveMode: value),
                            );
                            if (context.mounted) {
                              _settingsSnack(
                                context,
                                value ? '已开启沉浸观影模式' : '已退出沉浸观影模式',
                              );
                            }
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('首页台词轮换'),
                          subtitle: const Text(
                            '首页顶部每 30 秒轮换一句影视台词，点击可按片名搜索；关闭后连 LOGO 与档案名一起收起，导入按钮下移到「N 个可用站点」那一行',
                          ),
                          value: app.showMovieQuotes,
                          onChanged: (value) => app.setShowMovieQuotes(value),
                        ),
                        // 只有 Windows 能另开窗口；其余平台不给一个按了没反应的开关。
                        if (supportsStandalonePlayerWindow)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('内置播放器独立窗口'),
                            subtitle: Text(
                              '在软件主界面之外打开独立播放器窗口，主界面保持可见；'
                              '关闭则像现在一样在软件主界面内播放'
                              '${app.playerSettings.immersiveMode && app.playerSettings.popOutPlayer ? '（沉浸观影模式下暂停生效，退出后自动恢复）' : ''}',
                            ),
                            value: app.playerSettings.popOutPlayer,
                            onChanged: (value) async {
                              await app.setPlayerSettings(
                                app.playerSettings.copyWith(
                                  popOutPlayer: value,
                                ),
                              );
                              if (!context.mounted) return;
                              final paused =
                                  value && app.playerSettings.immersiveMode;
                              _settingsSnack(
                                context,
                                !value
                                    ? '内置播放器已改为嵌入主界面'
                                    : paused
                                    ? '已开启：沉浸观影模式下暂停生效，退出后自动恢复'
                                    : '内置播放器将以独立窗口打开',
                              );
                            },
                          ),
                        _ActionRow(
                          icon: Icons.image_outlined,
                          title: '横图封面来源',
                          subtitle:
                              '${_artworkSourceLabel(app.playerSettings.artworkPriority)}'
                              '${_tmdbCredentialLabel(app.playerSettings.tmdbApiKey, app.playerSettings.tmdbReadToken)}',
                          onTap: () => _openArtworkSettings(context, app),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '界面与首页',
                    icon: Icons.dashboard_customize_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.playerSettings.immersiveMode ? '沉浸观影' : '标准布局',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '沉浸观影：${app.playerSettings.immersiveMode ? '开' : '关'}'
                      ' · 台词轮换：${app.showMovieQuotes ? '开' : '关'}'
                      ' · 每行 ${app.homeColumns == 0 ? '自动' : '${app.homeColumns} 个'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text('分类浏览方式', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          '换页：底部上一页 / 下一页；瀑布：滑到底自动加载下一页',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [(0, '换页'), (1, '瀑布')])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.homeBrowseMode == item.$1,
                                onSelected: (_) =>
                                    app.setHomeBrowseMode(item.$1),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text('首页每行封面', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          '默认窗口大小下一行显示几个封面；自动 = 随窗口宽度排列',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [
                              (0, '自动'),
                              (4, '4 个'),
                              (5, '5 个'),
                              (6, '6 个'),
                              (7, '7 个'),
                              (8, '8 个'),
                            ])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.homeColumns == item.$1,
                                onSelected: (_) => app.setHomeColumns(item.$1),
                              ),
                          ],
                        ),
                        if (supportsAppWindowSize) ...[
                          const SizedBox(height: 18),
                          Text('窗口尺寸', style: theme.textTheme.labelMedium),
                          const SizedBox(height: 4),
                          Text(
                            app.rememberedWindowSize == null
                                ? '未记忆：启动时按显示器比例自动计算'
                                : '已记忆 ${app.rememberedWindowSize!.width.round()} × '
                                      '${app.rememberedWindowSize!.height.round()}，'
                                      '下次启动使用',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  final size = await currentAppWindowSize();
                                  if (size == null) return;
                                  await app.setRememberedWindowSize(size);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '已记住窗口尺寸 '
                                        '${size.width.round()} × '
                                        '${size.height.round()}',
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.aspect_ratio_rounded),
                                label: const Text('记住当前窗口尺寸'),
                              ),
                              if (app.rememberedWindowSize != null)
                                TextButton(
                                  onPressed: () =>
                                      app.setRememberedWindowSize(null),
                                  child: const Text('恢复默认'),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    key: _playSectionKey,
                    title: '播放行为',
                    icon: Icons.play_circle_outline_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '连播 ${app.playerSettings.autoPlayNext ? '开' : '关'}'
                      ' · 换线 ${app.playerSettings.autoSwitchLine ? '开' : '关'}',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _PlaySummary(app: app),
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          value: app.playerSettings.autoPlayNext,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(autoPlayNext: v),
                          ),
                          title: const Text('自动连播下一集'),
                          subtitle: const Text('当前集播放结束后自动切换'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.autoSwitchLine,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(autoSwitchLine: v),
                          ),
                          title: const Text('自动换线路'),
                          subtitle: const Text(
                            '当前线路播放失败时自动尝试下一条线路；'
                            '本源线路都失败后再搜索其他源的相同片名',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.rememberProgress,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(rememberProgress: v),
                          ),
                          title: const Text('记住播放进度'),
                          subtitle: const Text('退出播放器时保存进度，下次继续'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.autoLandscape,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(autoLandscape: v),
                          ),
                          title: const Text('播放时自动横屏'),
                          subtitle: const Text(
                            '打开播放器自动切横屏（仅手机/平板生效），退出后恢复系统方向',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.m3u8Purify,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(m3u8Purify: v),
                          ),
                          title: const Text('m3u8 去广告'),
                          subtitle: const Text('点播清单播放前清洗广告分段（启发式，默认关）'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '缓冲与缓存',
                    icon: Icons.speed_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.playerSettings.streamCache ? '边播边缓存' : '不缓存',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '预缓冲 ${app.playerSettings.bufferMinSec.toStringAsFixed(1)}s'
                      ' · 最大 ${app.playerSettings.bufferMaxSec.toStringAsFixed(0)}s'
                      ' · 缓存 ${app.playerSettings.streamCache ? '${app.playerSettings.streamCacheMb}MB' : '关'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.memory_rounded,
                          title: '播放缓冲',
                          subtitle:
                              '起播预缓冲 '
                              '${app.playerSettings.bufferMinSec.toStringAsFixed(1)}s · '
                              '最大缓冲 '
                              '${app.playerSettings.bufferMaxSec.toStringAsFixed(0)}s',
                          onTap: () => _editBufferSettings(context, app),
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.streamCache,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(streamCache: v),
                          ),
                          title: const Text('边播边缓存'),
                          subtitle: const Text(
                            '把已下行的分片存到本地：重看、拖回看过的位置直接读盘，不再回源',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.sd_storage_outlined,
                          title: '缓存容量上限',
                          subtitle:
                              '${app.playerSettings.streamCacheMb} MB'
                              '（超出后按最久未使用淘汰）',
                          onTap: () => _pickStreamCacheSize(context, app),
                        ),
                        _ActionRow(
                          icon: Icons.cleaning_services_outlined,
                          title: '清空播放缓存',
                          subtitle: '只清理边播缓存目录，不影响收藏 / 历史 / 订阅',
                          onTap: () => _clearStreamCache(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '画面与播放器',
                    icon: Icons.aspect_ratio_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      playerFitLabel(app.playerSettings.fit),
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '${playerFitLabel(app.playerSettings.fit)}'
                      ' · ${_defaultPlayerLabel(app)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.aspect_ratio_rounded,
                          title: '画面比例',
                          subtitle: playerFitLabel(app.playerSettings.fit),
                          onTap: () => _pickPlayerFit(context, app),
                        ),
                        if (!kIsWeb &&
                            defaultTargetPlatform ==
                                TargetPlatform.windows) ...[
                          _ActionRow(
                            icon: Icons.play_circle_outline_rounded,
                            title: '默认播放器',
                            subtitle: _defaultPlayerLabel(app),
                            onTap: () => _pickDefaultPlayer(context, app),
                          ),
                          _ActionRow(
                            icon: Icons.open_in_new_rounded,
                            title: '自定义第三方播放器',
                            subtitle: app.playerSettings.externalPlayers.isEmpty
                                ? '未添加；可直接选择播放器 exe，无需安装识别'
                                : '已添加 ${app.playerSettings.externalPlayers.length} 个播放器',
                            onTap: () => _editExternalPlayers(context),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '下载与网盘',
                    icon: Icons.cloud_download_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.xunleiAccount.loggedIn ? '迅雷已登录' : '只用 aria2',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '迅雷云盘：${app.xunleiAccount.loggedIn ? app.xunleiAccount.displayName : '未登录'}'
                      ' · 磁力目录：${app.playerSettings.magnetDownloadDir.isEmpty ? '默认' : '自定义'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.cloud_download_outlined,
                          title: '迅雷云盘',
                          subtitle: app.xunleiAccount.loggedIn
                              ? '${app.xunleiAccount.displayName} · '
                                    '磁力优先走云端离线下载'
                              : '未登录；支持账号密码（含短信验证）或刷新令牌',
                          onTap: () => _editXunlei(context, app),
                        ),
                        SwitchListTile.adaptive(
                          value: app.xunleiAccount.enabled,
                          onChanged: app.xunleiAccount.loggedIn
                              ? (v) => app.setXunleiEnabled(v)
                              : null,
                          title: const Text('磁力优先使用迅雷云盘'),
                          subtitle: const Text(
                            '先提交到迅雷云盘离线下载，云端完成后播放；'
                            '未登录、关闭或失败时自动回退 aria2',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.folder_open_rounded,
                          title: '磁力下载位置',
                          subtitle: app.playerSettings.magnetDownloadDir.isEmpty
                              ? '默认：应用数据目录/bt（点击自定义）'
                              : app.playerSettings.magnetDownloadDir,
                          onTap: () => _pickMagnetDownloadDir(context, app),
                        ),
                        _ActionRow(
                          icon: Icons.extension_outlined,
                          title: '网盘下载支持库',
                          subtitle: '在浏览器中打开 123 云盘分享页（提取码 Misa）',
                          onTap: () => launchUrl(
                            Uri.parse(
                              'https://1824896562.share.123pan.cn/123pan/syh2jv-j1p6h?pwd=Misa#',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '网络',
                    icon: Icons.vpn_lock_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.proxy.enabled ? '手动代理' : '跟随系统',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      ProxyRuntime.instance.summary,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.vpn_lock_outlined,
                          title: '网络代理',
                          // 显示实际生效的上游：跟随系统代理时能看到解析到的地址。
                          subtitle: ProxyRuntime.instance.summary,
                          onTap: () => _editProxy(context),
                        ),
                        // 隐藏项：在底部导航「设置」上连点 5 次才出现。
                        if (app.proxyPoolUnlocked)
                          _ActionRow(
                            icon: Icons.lan_rounded,
                            title: '代理池',
                            subtitle: app.proxyPool.enabled
                                ? '已启用：${app.proxyPool.selectedLabel}'
                                : '直连 · ${app.proxyPool.nodes.length} 个节点',
                            onTap: () => showProxyPoolSheet(context, app),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  _Section(
                    title: '字幕与弹幕',
                    icon: Icons.subtitles_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.danmakuSettings.enabled ? '弹幕默认开' : '弹幕默认关',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '弹幕：${app.danmakuSettings.enabled ? '开' : '关'}'
                      ' · 字号 ${app.danmakuSettings.fontSize.toStringAsFixed(0)}'
                      ' · assrt：${app.assrtToken.isEmpty ? '未配置' : '已配置'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.subtitles_outlined,
                          title: 'assrt 字幕 token',
                          subtitle: app.assrtToken.isEmpty
                              ? '未配置（SubtitleCat 免 token，仍可在线搜字幕）'
                              : '已配置（在线字幕会同时查 assrt 与 SubtitleCat）',
                          onTap: () => _editAssrtToken(context),
                        ),
                        _ActionRow(
                          icon: Icons.link_rounded,
                          title: '自定义字幕 API',
                          subtitle: app.customSubtitleApis.trim().isEmpty
                              ? '未配置；支持返回 JSON 列表或字幕文件的 URL 模板'
                              : '已配置 ${_customLineCount(app.customSubtitleApis)} 个接口',
                          onTap: () => _editSubtitleApis(context),
                        ),
                        SwitchListTile.adaptive(
                          value: app.danmakuSettings.enabled,
                          onChanged: (v) => app.setDanmakuSettings(
                            app.danmakuSettings.copyWith(enabled: v),
                          ),
                          title: const Text('默认开启弹幕'),
                          subtitle: const Text('优先使用已启用接口；未命中会自动扩大搜索'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.chat_bubble_outline_rounded,
                          title: '弹幕样式',
                          subtitle:
                              '字号 ${app.danmakuSettings.fontSize.toStringAsFixed(0)} · '
                              '${(app.danmakuSettings.regionRatio * 100).round()}% 屏 · '
                              '透明度 ${(app.danmakuSettings.opacity * 100).round()}% · '
                              '速度 ${app.danmakuSettings.speed.round()} · '
                              '偏移 ${app.danmakuSettings.offset.toStringAsFixed(1)}s'
                              '${app.danmakuSettings.blockWords.isEmpty ? '' : ' · 屏蔽 ${app.danmakuSettings.blockWords.length} 词'}',
                          onTap: () => _editDanmakuStyle(context),
                        ),
                        _ActionRow(
                          icon: Icons.travel_explore_rounded,
                          title: '弹幕接口',
                          subtitle: _danmakuEndpointsSubtitle(
                            app.danmakuSettings,
                          ),
                          onTap: () => _editDanmakuEndpoints(context),
                        ),
                      ],
                    ),
                  ),
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.windows) ...[
                    const SizedBox(height: 16),
                    _Section(
                      title: '运行时组件',
                      icon: Icons.memory_rounded,
                      collapsible: true,
                      initiallyExpanded: false,
                      trailing: Text(
                        'MPV / Python / JVM / 加固壳',
                        style: theme.textTheme.labelSmall,
                      ),
                      summary: Text(
                        '第三方播放器、蜘蛛运行时与加固壳解包组件按需下载',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          const _MpvExtensionTile(),
                          const Divider(height: 24),
                          _PythonRuntimeTile(key: _pythonTileKey),
                          const Divider(height: 24),
                          _JvmRuntimeTile(key: _jvmTileKey),
                          const Divider(height: 24),
                          _ArmBridgeTile(key: _guardTileKey),
                        ],
                      ),
                    ),
                  ],
                  if (!kIsWeb) ...[
                    const SizedBox(height: 16),
                    _Section(
                      title: '性能',
                      icon: Icons.speed_rounded,
                      collapsible: true,
                      initiallyExpanded: false,
                      trailing: Text(
                        app.playerSettings.jsWorkerPool ||
                                app.playerSettings.keepSpiderHosts
                            ? '已开启'
                            : '默认',
                        style: theme.textTheme.labelSmall,
                      ),
                      summary: Text(
                        'JS 并行：${app.playerSettings.jsWorkerPool ? '开' : '关'}'
                        ' · JVM 保温：${app.playerSettings.keepSpiderHosts ? '开' : '关'}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile.adaptive(
                            value: app.playerSettings.jsWorkerPool,
                            onChanged: (v) => app.setPlayerSettings(
                              app.playerSettings.copyWith(jsWorkerPool: v),
                            ),
                            title: const Text('JS 蜘蛛并行（实验）'),
                            subtitle: const Text(
                              '多 JS 源同时搜索 / 浏览时最多使用 3 个 QuickJS 执行器，'
                              '避免所有请求排在一个 isolate 里；更占内存，默认关闭',
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                          Text(
                            '开启后每个执行器使用独立的脚本本地存储文件。'
                            '如果某个 JS 源依赖 local 里的长期状态，切换开关后可能需要重新初始化一次。',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                              height: 1.5,
                            ),
                          ),
                          const Divider(height: 24),
                          SwitchListTile.adaptive(
                            value: app.playerSettings.keepSpiderHosts,
                            onChanged: (v) => app.setPlayerSettings(
                              app.playerSettings.copyWith(keepSpiderHosts: v),
                            ),
                            title: const Text('常驻 JVM 保温（实验）'),
                            subtitle: const Text(
                              '搜索 / 浏览结束后保留 JVM 取数进程 2 分钟，减少再次冷启动；'
                              '更占内存，默认关闭',
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
                if (_pageIndex == _safetyPage) ...[
                  _Section(
                    title: '内容过滤',
                    icon: Icons.shield_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.contentFilter.enabled ? '已开启' : '已关闭',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _ContentFilterSummary(app: app),
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          value: app.contentFilter.enabled,
                          onChanged: (v) =>
                              _toggleContentFilter(context, app, v),
                          title: const Text('屏蔽 R18 / 成人内容'),
                          subtitle: const Text(
                            '开启时设置关闭密码，关闭过滤必须输入该密码，防止儿童误关；命中关键词的条目与分类会从首页、分类与搜索结果里隐藏',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.rule_rounded,
                          title: '屏蔽关键词',
                          subtitle: app.contentFilter.keywords.isEmpty
                              ? '未设置关键词（当前不会过滤任何内容）'
                              : '${app.contentFilter.keywords.join(' · ')}'
                                    '${app.contentFilter.enabled ? '' : '（过滤已关闭，暂不生效）'}',
                          onTap: () => _editContentFilterKeywords(context),
                        ),
                        const Divider(height: 24),
                        Text(
                          '关键词不区分大小写，会匹配片名、备注、类型、地区、标签与来源名称；'
                          '分类名（如「伦理片」）命中时会从分类栏隐藏，其内容也不会出现在搜索结果里。'
                          '过滤只影响浏览与搜索，收藏和历史记录不会被删除；'
                          '关闭过滤需要输入开启时设置的密码。',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.5,
                            ),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '隐私与快捷键',
                    icon: Icons.keyboard_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      bossKeyLabel(app.playerSettings.bossKey),
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '老板键 ${bossKeyLabel(app.playerSettings.bossKey)}：暂停并收进托盘',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.keyboard_outlined,
                          title: '老板键',
                          subtitle:
                              '${bossKeyLabel(app.playerSettings.bossKey)}'
                              ' · 暂停视频并收进托盘；沉浸观影模式下不生效',
                          onTap: () => _openBossKeySettings(context, app),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _accountPage) ...[
                  if (!kIsWeb) const SizedBox(height: 16),
                  _Section(
                    title: '数据',
                    icon: Icons.storage_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    summary: _DataSummary(app: app),
                    child: Column(
                      children: [
                        if (!kIsWeb) ...[
                          _ActionRow(
                            icon: Icons.backup_outlined,
                            title: '导出设置备份',
                            subtitle: '订阅、收藏、历史、播放设置与网盘 Cookie（明文）',
                            onTap: () => _exportBackup(context),
                          ),
                          _ActionRow(
                            icon: Icons.settings_backup_restore_rounded,
                            title: '导入设置备份',
                            subtitle: '支持 MisaTV 备份与旧版 Win-Box 备份',
                            onTap: () => _restoreBackup(context),
                          ),
                          const Divider(height: 24),
                        ],
                        _ActionRow(
                          icon: Icons.history_rounded,
                          title: '清空观看历史',
                          subtitle: '${app.history.length} 条记录',
                          onTap: app.history.isEmpty
                              ? null
                              : () async {
                                  final ok = await _confirm(
                                    context,
                                    '清空全部观看历史？',
                                    '此操作不可恢复',
                                  );
                                  if (ok == true) await app.clearHistory();
                                },
                        ),
                        _ActionRow(
                          icon: Icons.favorite_border_rounded,
                          title: '清空收藏',
                          subtitle: '${app.favorites.length} 条收藏',
                          onTap: app.favorites.isEmpty
                              ? null
                              : () async {
                                  final ok = await _confirm(
                                    context,
                                    '清空全部收藏？',
                                    '此操作不可恢复',
                                  );
                                  if (ok == true) {
                                    for (final item in List.of(app.favorites)) {
                                      await app.removeFavorite(item.key);
                                    }
                                  }
                                },
                        ),
                        _ActionRow(
                          icon: Icons.search_off_rounded,
                          title: '清空搜索历史',
                          subtitle: '${app.searchHistory.length} 条关键词',
                          onTap: app.searchHistory.isEmpty
                              ? null
                              : app.clearSearchHistory,
                        ),
                        const Divider(height: 24),
                        _ActionRow(
                          icon: Icons.folder_open_rounded,
                          title: '运行日志',
                          subtitle: AppLog.directory.isEmpty
                              ? 'Web 版不写本地日志'
                              : '${AppLog.directory}（按天分文件，保留 14 天）',
                          onTap: AppLog.directory.isEmpty
                              ? null
                              : () => AppLog.openDirectory(),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _safetyPage) ...[
                  const SizedBox(height: 16),
                  _Section(
                    title: '关于',
                    icon: Icons.info_outline_rounded,
                    // 关于是设置页唯一常驻展开的父分类（其余分类都必须可折叠）。
                    collapsible: false,
                    trailing: Text(
                      'v$kAppVersion',
                      style: theme.textTheme.labelSmall,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Image.asset(
                                'assets/images/app_icon.png',
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'MisaTV',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                                Text(
                                  'v$kAppVersion · Flutter 轻量重构',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.70),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '基于 TVBox / CatVod 生态的本地优先客户端。不提供、不分发任何影视内容，所有源由用户自行配置。'
                          '请遵守所在地法律法规，仅用于个人学习与研究。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _ActionRow(
                          icon: Icons.system_update_alt_rounded,
                          title: '检查更新',
                          subtitle: '当前 v$kAppVersion · 有新版本会显示更新内容',
                          onTap: () => _checkUpdates(context),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => launchUrl(
                                Uri.parse(
                                  'https://github.com/yagami-hue/MisaTV',
                                ),
                              ),
                              icon: const Icon(
                                Icons.open_in_new_rounded,
                                size: 16,
                              ),
                              label: const Text('官方网站'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  launchUrl(Uri.parse('https://t.me/MisaTV1')),
                              icon: const Icon(Icons.groups_rounded, size: 16),
                              label: const Text('官方群组'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 手动检查更新：没有新版本就给一条提示，有就直接弹更新框。
  Future<void> _checkUpdates(BuildContext context) async {
    _settingsSnack(context, '正在检查更新…');
    final release = await UpdateService().check();
    if (!context.mounted) return;
    if (release == null) {
      _settingsSnack(context, '已经是最新版本（v$kAppVersion）');
      return;
    }
    await showUpdateDialog(context, release);
  }

  Future<bool?> _confirm(BuildContext context, String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }
}

/// 设置页的父分类（分页）。原有的可折叠分类分别挂在这四页下面。
const _settingsPages = <(IconData, String)>[
  (Icons.video_library_outlined, '内容与订阅'),
  (Icons.play_circle_outline_rounded, '播放与外观'),
  (Icons.cloud_outlined, '网盘与数据'),
  (Icons.shield_outlined, '安全与关于'),
];

class _SettingsPager extends StatelessWidget {
  const _SettingsPager({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      padding: const EdgeInsets.all(6),
      borderRadius: 20,
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _settingsPages.length; i++)
            InkWell(
              onTap: () => onChanged(i),
              borderRadius: BorderRadius.circular(14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: index == i
                      ? theme.colorScheme.primary.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: index == i
                        ? theme.colorScheme.primary.withValues(alpha: 0.35)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _settingsPages[i].$1,
                      size: 16,
                      color: index == i
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.76),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _settingsPages[i].$2,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: index == i
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.75,
                              ),
                        fontWeight: index == i
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatefulWidget {
  const _Section({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.collapsible = true,
    this.initiallyExpanded = false,
    this.summary,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  /// 设置页的每个父分类都必须可折叠（默认收起），点标题栏切换。
  final bool collapsible;
  final bool initiallyExpanded;

  /// 折叠时替代内容显示的一行摘要。
  final Widget? summary;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  late bool _expanded = widget.initiallyExpanded;

  /// 供设置页跳转展开使用（折叠态下的 child 不在树里）。
  void expand() {
    if (!widget.collapsible || _expanded) return;
    setState(() => _expanded = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Row(
      children: [
        Icon(widget.icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(widget.title, style: theme.textTheme.titleMedium)),
        ?widget.trailing,
        if (widget.collapsible) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.expand_more_rounded,
              size: 20,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ],
    );
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      borderRadius: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.collapsible)
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(12),
              child: header,
            )
          else
            header,
          if (!widget.collapsible || _expanded) ...[
            const SizedBox(height: 12),
            widget.child,
          ] else if (widget.summary != null) ...[
            const SizedBox(height: 10),
            widget.summary!,
          ],
        ],
      ),
    );
  }
}

/// 站点可能有上百个：展开后限制高度，在卡片内滚动，避免整页被拉得很长。
class _SiteList extends StatefulWidget {
  const _SiteList({required this.sites, required this.app});
  final List<SourceBean> sites;
  final AppState app;

  @override
  State<_SiteList> createState() => _SiteListState();
}

class _SiteListState extends State<_SiteList> {
  final ScrollController _controller = ScrollController();

  /// 最近一次体检结果（仅本次会话，用来在行尾显示状态点）。
  final Map<String, SourceHealth> _health = {};
  final Set<String> _picked = {};
  bool _selecting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _failedCount => _health.values
      .where((h) => h.status == 'error')
      .where((h) => widget.sites.any((s) => s.key == h.key))
      .length;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final theme = Theme.of(context);
    _picked.removeWhere((key) => !widget.sites.any((s) => s.key == key));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '按主页真实返回判定可用性（并发 4）',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                Wrap(
                  spacing: 2,
                  children: [
                    TextButton.icon(
                      onPressed: () => _checkSites(context, widget.sites),
                      icon: const Icon(Icons.monitor_heart_outlined, size: 16),
                      label: const Text('一键体检'),
                    ),
                    if (_failedCount > 0)
                      TextButton.icon(
                        onPressed: () => _deleteFailed(context),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: Text('删除失败源（$_failedCount）'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _selecting = !_selecting;
                        if (!_selecting) _picked.clear();
                      }),
                      icon: Icon(
                        _selecting
                            ? Icons.done_rounded
                            : Icons.checklist_rounded,
                        size: 16,
                      ),
                      label: Text(_selecting ? '完成' : '多选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Flexible(
            child: Scrollbar(
              controller: _controller,
              thumbVisibility: true,
              child: ListView.builder(
                controller: _controller,
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: widget.sites.length,
                itemBuilder: (context, index) {
                  final site = widget.sites[index];
                  final usable = app.isSiteUsable(site);
                  return _SiteRow(
                    site: site,
                    active: app.activeSite?.key == site.key,
                    usable: usable,
                    health: _health[site.key],
                    selecting: _selecting,
                    selected: _picked.contains(site.key),
                    onSelect: () => setState(() {
                      if (!_picked.add(site.key)) _picked.remove(site.key);
                    }),
                    onTap: _selecting
                        ? () => setState(() {
                            if (!_picked.add(site.key)) {
                              _picked.remove(site.key);
                            }
                          })
                        : usable
                        ? () async {
                            await app.setActiveSite(site.key);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已切换到 ${site.displayName}'),
                              ),
                            );
                          }
                        : site.isJarSpider
                        ? () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'JAR / DEX 源需要 JVM 运行时（设置 → 播放 → JVM 运行时）',
                              ),
                            ),
                          )
                        : null,
                    onDiagnose: () => _checkSites(context, [site]),
                    onToggleSearch: () => _toggleSearch(context, site),
                    onEdit: () => _editSite(context, site),
                    onDelete: () => _deleteSite(context, site),
                  );
                },
              ),
            ),
          ),
          if (_selecting) ...[
            const Divider(height: 12),
            Row(
              children: [
                Text(
                  '已选 ${_picked.length} / ${widget.sites.length}',
                  style: theme.textTheme.labelSmall,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    if (_picked.length == widget.sites.length) {
                      _picked.clear();
                    } else {
                      _picked.addAll(widget.sites.map((s) => s.key));
                    }
                  }),
                  child: Text(
                    _picked.length == widget.sites.length ? '取消全选' : '全选',
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _picked.isEmpty
                      ? null
                      : () => _movePicked(context),
                  icon: const Icon(Icons.drive_file_move_outlined, size: 17),
                  label: const Text('移动到订阅'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _picked.isEmpty
                      ? null
                      : () => _deletePicked(context),
                  icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  label: Text('删除所选（${_picked.length}）'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deletePicked(BuildContext context) async {
    if (_picked.isEmpty) return;
    final ok = await _confirmDelete(context, '删除选中的 ${_picked.length} 个站点？');
    if (ok != true) return;
    final removed = await widget.app.removeSites(_picked);
    if (!context.mounted) return;
    setState(() {
      _picked.clear();
      _selecting = false;
    });
    _settingsSnack(context, '已删除 $removed 个站点；订阅刷新后不会自动恢复');
  }

  Future<void> _movePicked(BuildContext context) async {
    if (_picked.isEmpty) return;
    final targets = [
      for (final profile in widget.app.profiles)
        if (profile.id != widget.app.activeProfileId && !profile.isLiveOnly)
          profile,
    ];
    if (targets.isEmpty) {
      _settingsSnack(context, '没有其他可移动的点播订阅，请先导入或创建订阅');
      return;
    }
    final targetId = await showMoveSitesTargetDialog(
      context,
      profiles: targets,
      count: _picked.length,
    );
    if (targetId == null || !context.mounted) return;
    ConfigProfile? target;
    for (final profile in targets) {
      if (profile.id == targetId) {
        target = profile;
        break;
      }
    }
    if (target == null) return;
    final moved = await widget.app.moveSitesToProfile(_picked, targetId);
    if (!context.mounted) return;
    setState(() {
      _picked.clear();
      _selecting = false;
    });
    _settingsSnack(
      context,
      moved > 0 ? '已移动 $moved 个站点到「${target.name}」' : '移动失败：目标订阅可能不是 JSON 配置',
    );
  }

  Future<void> _deleteFailed(BuildContext context) async {
    final failed = _health.values
        .where((h) => h.status == 'error')
        .map((h) => h.key)
        .where((key) => widget.sites.any((s) => s.key == key))
        .toSet();
    if (failed.isEmpty) return;
    final ok = await _confirmDelete(context, '删除 ${failed.length} 个体检失败的站点？');
    if (ok != true) return;
    final removed = await widget.app.removeSites(failed);
    if (!context.mounted) return;
    setState(() {
      for (final key in failed) {
        _health.remove(key);
        _picked.remove(key);
      }
    });
    _settingsSnack(context, '已删除 $removed 个失败源');
  }

  Future<bool?> _confirmDelete(BuildContext context, String message) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认删除站点'),
          content: Text('$message\n\n只从当前配置里移除，并记录为「已删除」；订阅刷新时不会自动恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );

  Future<void> _checkSites(BuildContext context, List<SourceBean> sites) async {
    final results = await showDialog<Map<String, SourceHealth>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HealthCheckDialog(sites: sites),
    );
    if (results != null && mounted) {
      setState(() => _health.addAll(results));
    }
  }

  /// 站点行上的「参与搜索」开关：只改这一个字段，改动即时生效。
  Future<void> _toggleSearch(BuildContext context, SourceBean site) async {
    final next = site.searchable != 1;
    final ok = await widget.app.setSiteSearchable(site.key, next);
    if (!context.mounted) return;
    if (!ok) {
      _settingsSnack(context, '这份配置不是 JSON 订阅，改不了站点');
      return;
    }
    _settingsSnack(
      context,
      next ? '「${site.displayName}」已参与搜索' : '「${site.displayName}」已退出搜索',
    );
  }

  Future<void> _editSite(BuildContext context, SourceBean site) async {
    final edited = await showDialog<SourceBean>(
      context: context,
      builder: (_) => _SiteEditDialog(site: site),
    );
    if (edited == null) return;
    final ok = await widget.app.updateSite(site.key, edited);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? '已保存 ${edited.displayName}' : '这份配置不是 JSON 订阅，改不了站点',
        ),
      ),
    );
  }

  Future<void> _deleteSite(BuildContext context, SourceBean site) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除站点「${site.displayName}」？'),
        content: const Text('只从当前配置里移除这个站点，不影响其他内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await widget.app.removeSite(site.key);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已删除 ${site.displayName}' : '这份配置不是 JSON 订阅，改不了站点'),
      ),
    );
  }
}

/// 编辑单个站点：名称 / 地址 / 类型等字段，`key` 保持只读。
///
/// 「参与搜索」不在这里改：站点列表行上直接开关，避免为了改一个布尔值
/// 打开整张表再保存。
class _SiteEditDialog extends StatefulWidget {
  const _SiteEditDialog({required this.site});
  final SourceBean site;

  @override
  State<_SiteEditDialog> createState() => _SiteEditDialogState();
}

class _SiteEditDialogState extends State<_SiteEditDialog> {
  static const _siteExtTemplate = '{\n  "siteUrl": "https://example.com"\n}';
  static const _hikerExtTemplate =
      '{\n'
      '  "url": "https://example.com",\n'
      '  "list": ".video-list li",\n'
      '  "name": ".title",\n'
      '  "pic": "img@src",\n'
      '  "urlKey": "a@href"\n'
      '}';

  late final TextEditingController _name = TextEditingController(
    text: widget.site.name,
  );
  late final TextEditingController _api = TextEditingController(
    text: widget.site.api,
  );
  late final TextEditingController _type = TextEditingController(
    text: '${widget.site.type}',
  );
  late final TextEditingController _jar = TextEditingController(
    text: widget.site.jar,
  );
  late final TextEditingController _timeout = TextEditingController(
    text: '${widget.site.timeout}',
  );
  late final TextEditingController _ext = TextEditingController(
    text: widget.site.ext,
  );
  late final TextEditingController _playUrl = TextEditingController(
    text: widget.site.playUrl,
  );
  late final TextEditingController _click = TextEditingController(
    text: widget.site.click,
  );
  late final TextEditingController _style = TextEditingController(
    text: widget.site.style,
  );
  String? _error;
  String? _extError;
  String _extHint = '';

  @override
  void initState() {
    super.initState();
    _validateExt();
  }

  @override
  void dispose() {
    _name.dispose();
    _api.dispose();
    _type.dispose();
    _jar.dispose();
    _timeout.dispose();
    _ext.dispose();
    _playUrl.dispose();
    _click.dispose();
    _style.dispose();
    super.dispose();
  }

  /// ext 以 JSON 形态使用时做实时校验；蜘蛛也可能收原始字符串（如加密 blob），
  /// 所以只有看起来像 JSON 的内容才强制合法。
  void _validateExt() {
    final text = _ext.text.trim();
    if (text.isEmpty) {
      _extError = null;
      _extHint = '';
      return;
    }
    if (!text.startsWith('{') && !text.startsWith('[')) {
      _extError = null;
      _extHint = '非 JSON 内容会原样传给蜘蛛';
      return;
    }
    try {
      jsonDecode(text);
      _extError = null;
      _extHint = 'JSON 合法';
    } catch (e) {
      _extError = 'ext 不是合法 JSON：$e';
      _extHint = '';
    }
  }

  void _applyExtTemplate(String value) {
    _ext.text = value == 'hiker' ? _hikerExtTemplate : _siteExtTemplate;
    _validateExt();
    setState(() {});
  }

  void _save() {
    final api = _api.text.trim();
    if (api.isEmpty) {
      setState(() => _error = '地址不能为空');
      return;
    }
    _validateExt();
    if (_extError != null) {
      setState(() {});
      return;
    }
    final source = widget.site;
    Navigator.of(context).pop(
      SourceBean(
        key: source.key,
        name: _name.text.trim(),
        type: int.tryParse(_type.text.trim()) ?? source.type,
        api: api,
        searchable: source.searchable,
        quickSearch: source.quickSearch,
        changeable: source.changeable,
        filterable: source.filterable,
        playUrl: _playUrl.text.trim(),
        ext: _ext.text.trim(),
        jar: _jar.text.trim(),
        playerType: source.playerType,
        categories: source.categories,
        timeout: (int.tryParse(_timeout.text.trim()) ?? source.timeout).clamp(
          5,
          60,
        ),
        click: _click.text.trim(),
        style: _style.text.trim(),
        homePage: source.homePage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('编辑站点'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'key：${widget.site.key}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _api,
                decoration: const InputDecoration(
                  labelText: '地址',
                  hintText: 'CMS 接口地址，或 csp_ 蜘蛛类名',
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _type,
                      decoration: const InputDecoration(
                        labelText: '类型',
                        hintText: '0 XML / 1 JSON / 3 蜘蛛 / -1 推送',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: _timeout,
                      decoration: const InputDecoration(labelText: '超时(秒)'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '参与搜索：在站点列表点搜索图标切换，改完立即生效',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _jar,
                decoration: const InputDecoration(
                  labelText: 'JAR 地址（可选）',
                  hintText: '留空则用订阅顶层的 spider',
                ),
                minLines: 1,
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _playUrl,
                decoration: const InputDecoration(
                  labelText: 'playUrl（可选）',
                  hintText: '站内解析地址，含 {playUrl} 时会替换剧集地址；一般留空',
                ),
                minLines: 1,
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _click,
                      decoration: const InputDecoration(
                        labelText: 'click（可选）',
                        hintText: 'host;selector',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _style,
                      decoration: const InputDecoration(
                        labelText: 'style（可选）',
                        hintText: '源展示风格',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text('ext（蜘蛛参数）', style: theme.textTheme.bodySmall),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '插入 ext 模板',
                    onSelected: _applyExtTemplate,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'site',
                        child: Text('通用站点 {siteUrl}'),
                      ),
                      PopupMenuItem(
                        value: 'hiker',
                        child: Text('海阔规则 {list/name/pic}'),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.article_outlined, size: 16),
                          const SizedBox(width: 4),
                          Text('插入模板', style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _ext,
                decoration: const InputDecoration(
                  hintText: '多数 csp_ / JS 蜘蛛需要 {"siteUrl": "https://资源站根地址"}',
                ),
                minLines: 3,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                onChanged: (_) => setState(_validateExt),
              ),
              if (_extError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _extError!,
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                )
              else if (_extHint.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _extHint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 站点区块折叠时显示的一行摘要：当前使用的站点。
class _SiteSummary extends StatelessWidget {
  const _SiteSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final site = app.activeSite;
    if (site == null) {
      return Text('点击展开选择站点', style: hint);
    }
    return Row(
      children: [
        Text('当前', style: hint),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            site.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _KindBadge(text: site.kindLabel, ok: app.isSiteUsable(site)),
        const SizedBox(width: 8),
        Text('点击展开切换', style: hint),
      ],
    );
  }
}

/// 直播源区块折叠时的摘要：当前使用的线路。
class _LiveSummary extends StatelessWidget {
  const _LiveSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final live = app.activeLive;
    if (live == null) return Text('点击展开管理直播源', style: hint);
    return Row(
      children: [
        Text('当前', style: hint),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            live.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${app.activeLiveProfile?.name ?? '本地线路'} · ${app.lives.length} 条',
          style: hint,
        ),
        const SizedBox(width: 8),
        Text('点击展开切换', style: hint),
      ],
    );
  }
}

/// 播放区块折叠时的摘要：两个开关的状态。
class _PlaySummary extends StatelessWidget {
  const _PlaySummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final settings = app.playerSettings;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        Text('自动连播${settings.autoPlayNext ? '开启' : '关闭'}', style: hint),
        Text('自动换线${settings.autoSwitchLine ? '开启' : '关闭'}', style: hint),
        Text('进度记忆${settings.rememberProgress ? '开启' : '关闭'}', style: hint),
        Text('去广告${settings.m3u8Purify ? '开启' : '关闭'}', style: hint),
        Text('点击展开', style: hint),
      ],
    );
  }
}

/// 内容过滤区块折叠时的摘要：开关状态与屏蔽词数量。
class _ContentFilterSummary extends StatelessWidget {
  const _ContentFilterSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final filter = app.contentFilter;
    final lock = filter.hasPassword ? ' · 已设置关闭密码' : '';
    return Row(
      children: [
        Text(
          '${filter.enabled ? 'R18 过滤已开启' : 'R18 过滤已关闭'}$lock',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${filter.keywords.length} 个屏蔽词 · 点击展开管理',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: hint,
          ),
        ),
      ],
    );
  }
}

/// 主题模式的中文名，设置页的标题栏与折叠摘要共用。
String _themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.light => '浅色',
  ThemeMode.dark => '深色',
  ThemeMode.system => '跟随系统',
};

/// 订阅配置区块折叠时的摘要：当前档案与数量。
class _ProfileSummary extends StatelessWidget {
  const _ProfileSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final profile = app.activeProfile;
    if (profile == null) return Text('还没有配置，点击展开导入订阅', style: hint);
    return Row(
      children: [
        Text('当前', style: hint),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            profile.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('${app.vodProfiles.length} 个点播', style: hint),
        const SizedBox(width: 8),
        Text('点击展开管理', style: hint),
      ],
    );
  }
}

/// 外观区块折叠时的摘要：主题模式与主题色。
class _AppearanceSummary extends StatelessWidget {
  const _AppearanceSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    return Row(
      children: [
        Text('主题色', style: hint),
        const SizedBox(width: 6),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: app.accentColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '第 ${app.accentIndex + 1} / ${AppState.accentPalette.length} 种',
          style: hint,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            // 首页列数 / 浏览方式已挪到「界面与首页」，这里只描述外观本身。
            '横条${switch (app.navBarSize) {
              0 => '紧凑',
              2 => '较大',
              3 => '超大',
              _ => '标准',
            }}${app.navBarAutoHide ? ' · 自动隐藏' : ' · 常驻'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: hint,
          ),
        ),
        const SizedBox(width: 8),
        Text('点击展开', style: hint),
      ],
    );
  }
}

/// 数据区块折叠时的摘要：历史、收藏与搜索历史的条数。
class _DataSummary extends StatelessWidget {
  const _DataSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    return Row(
      children: [
        Flexible(
          child: Text(
            '历史 ${app.history.length} · 收藏 ${app.favorites.length} · 搜索 ${app.searchHistory.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: hint,
          ),
        ),
        const SizedBox(width: 8),
        Text('点击展开清理', style: hint),
      ],
    );
  }
}

/// 直播源列表：与站点一样限高滚动，点一行即切换当前线路。
class _LiveSourceList extends StatefulWidget {
  const _LiveSourceList({required this.lives, required this.app});
  final List<LiveBean> lives;
  final AppState app;

  @override
  State<_LiveSourceList> createState() => _LiveSourceListState();
}

class _LiveSourceListState extends State<_LiveSourceList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _controller,
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: widget.lives.length,
          itemBuilder: (context, index) {
            final live = widget.lives[index];
            return _LiveSourceRow(
              live: live,
              active: app.activeLiveIndex == index,
              unusableReason: live.supported ? null : '不支持的直播类型：${live.type}',
              onTap: live.supported
                  ? () async {
                      await app.setActiveLive(live);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已切换到 ${live.displayName}')),
                      );
                    }
                  : null,
              onEdit: () => _editLive(context, index, live),
              onDelete: () => _deleteLive(context, index, live),
            );
          },
        ),
      ),
    );
  }

  Future<void> _editLive(BuildContext context, int index, LiveBean live) async {
    final edited = await showDialog<LiveBean>(
      context: context,
      builder: (_) => _LiveEditDialog(live: live),
    );
    if (edited == null) return;
    final ok = await widget.app.updateLiveSource(index, edited);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? '已保存 ${edited.displayName}' : '这份配置不是 JSON 订阅，改不了直播源',
        ),
      ),
    );
  }

  Future<void> _deleteLive(
    BuildContext context,
    int index,
    LiveBean live,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除直播源「${live.displayName}」？'),
        content: const Text('只从当前配置里移除这一条线路，不影响其他内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await widget.app.removeLiveSource(index);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已删除 ${live.displayName}' : '这份配置不是 JSON 订阅，改不了直播源'),
      ),
    );
  }
}

/// 编辑单条直播源的弹窗：名称、地址、类型与 EPG。
class _LiveEditDialog extends StatefulWidget {
  const _LiveEditDialog({required this.live});
  final LiveBean live;

  @override
  State<_LiveEditDialog> createState() => _LiveEditDialogState();
}

class _LiveEditDialogState extends State<_LiveEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.live.name,
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.live.url,
  );
  late final TextEditingController _type = TextEditingController(
    text: widget.live.type,
  );
  late final TextEditingController _epg = TextEditingController(
    text: widget.live.epg,
  );
  late final TextEditingController _timeZone = TextEditingController(
    text: widget.live.timeZone,
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _type.dispose();
    _epg.dispose();
    _timeZone.dispose();
    super.dispose();
  }

  void _save() {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '地址不能为空');
      return;
    }
    final type = _type.text.trim();
    final live = widget.live;
    Navigator.of(context).pop(
      LiveBean(
        name: _name.text.trim(),
        api: live.api,
        type: type.isEmpty ? '0' : type,
        url: url,
        jar: live.jar,
        ext: live.ext,
        epg: _epg.text.trim(),
        playerType: live.playerType,
        timeZone: _timeZone.text.trim(),
        timeout: live.timeout,
        header: live.header,
        ua: live.ua,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑直播源'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: '地址',
                hintText: 'TXT / M3U 订阅地址，或直播接口地址',
              ),
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _type,
                    decoration: const InputDecoration(
                      labelText: '类型',
                      hintText: '0 = TXT / M3U；3 = 蜘蛛',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _epg,
                    decoration: const InputDecoration(
                      labelText: 'EPG（可选）',
                      hintText: '节目单地址',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _timeZone,
              decoration: const InputDecoration(
                labelText: 'EPG 时区（可选）',
                hintText: 'Asia/Shanghai；留空 = 本机时区',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class _LiveSourceRow extends StatelessWidget {
  const _LiveSourceRow({
    required this.live,
    required this.active,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.unusableReason,
  });

  final LiveBean live;
  final bool active;
  final String? unusableReason;
  final VoidCallback? onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usable = unusableReason == null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(
                  alpha: usable ? 0.12 : 0.05,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.live_tv_rounded,
                size: 17,
                color: usable ? theme.colorScheme.primary : theme.disabledColor,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          live.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _KindBadge(
                        text: live.type == '3'
                            ? '蜘蛛'
                            : (live.type == '0' ? 'TXT' : 'TYPE ${live.type}'),
                        ok: usable,
                      ),
                    ],
                  ),
                  Text(
                    unusableReason ?? live.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: usable
                          ? theme.colorScheme.onSurface.withValues(alpha: 0.60)
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Icon(
                Icons.check_circle_rounded,
                color: theme.colorScheme.primary,
                size: 20,
              )
            else if (usable)
              const Icon(Icons.chevron_right_rounded, size: 20)
            else
              Icon(Icons.block_rounded, color: theme.disabledColor, size: 18),
            const SizedBox(width: 4),
            _RowIconButton(
              icon: Icons.edit_outlined,
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            _RowIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表行尾的紧凑图标按钮（编辑 / 删除）。
class _RowIconButton extends StatelessWidget {
  const _RowIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: color ?? theme.colorScheme.onSurface.withValues(alpha: 0.70),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.app,
    this.asLive = false,
  });

  final ConfigProfile profile;
  final AppState app;

  /// true = 直播订阅列表：只切换 lives，不改变点播档案。
  final bool asLive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = asLive
        ? app.activeLiveProfileId == profile.id
        : app.activeProfileId == profile.id;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: asLive
          ? () => app.setActiveLiveProfile(profile.id)
          : () => app.activateProfile(profile.id),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.1)
              : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.4)
                : theme.dividerColor,
          ),
        ),
        child: Row(
          children: [
            Icon(
              active
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: active ? theme.colorScheme.primary : theme.disabledColor,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    asLive
                        ? '${profile.liveCount} 个直播源 · 只切换直播，不影响点播'
                        : '${profile.siteCount} 站点 · ${profile.liveCount} 直播 · '
                              '${profile.report.ok} 可用${profile.report.degraded > 0 ? ' / ${profile.report.degraded} 降级' : ''}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.70,
                      ),
                    ),
                  ),
                  if (profile.url.isNotEmpty)
                    Text(
                      profile.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    ),
                  if (profile.lastRefreshAt != null)
                    Text(
                      '上次刷新 ${_dateLabel(profile.lastRefreshAt!)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (profile.url.startsWith('http'))
              _RowIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新订阅',
                onPressed: () => _refresh(context),
              ),
            _RowIconButton(
              icon: Icons.edit_outlined,
              tooltip: '重命名',
              onPressed: () => _rename(context),
            ),
            IconButton(
              tooltip: '删除配置',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('删除「${profile.name}」？'),
                    content: Text(
                      asLive
                          ? '只删除本机保存的直播订阅，不影响源站，也不影响点播订阅。'
                          : '只删除本机保存的订阅，不影响源站。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await app.removeProfile(profile.id);
              },
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: profile.name),
    );
    if (name == null) return;
    await app.renameProfile(profile.id, name);
  }

  Future<void> _refresh(BuildContext context) async {
    try {
      final outcome = await app.refreshProfile(
        profile.id,
        activate: asLive
            ? app.activeLiveProfileId == profile.id
            : app.activeProfileId == profile.id,
      );
      if (!context.mounted) return;
      _settingsSnack(
        context,
        asLive
            ? '已刷新「${outcome.profile.name}」：${outcome.profile.liveCount} 路直播'
            : '已刷新「${outcome.profile.name}」：${outcome.profile.siteCount} 个站点',
      );
    } catch (e) {
      if (context.mounted) _settingsSnack(context, '刷新失败：$e');
    }
  }
}

String _dateLabel(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final sameDay =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  if (sameDay) {
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month}-${local.day} ${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// 重命名订阅档案。控制器由 State 持有，避免弹窗退场动画还在读它时被提前 dispose。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名订阅配置'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '名称'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _SiteRow extends StatelessWidget {
  const _SiteRow({
    required this.site,
    required this.active,
    required this.usable,
    required this.onEdit,
    required this.onDelete,
    required this.onDiagnose,
    required this.onToggleSearch,
    this.onTap,
    this.health,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
  });
  final SourceBean site;
  final bool active;
  final bool usable;
  final SourceHealth? health;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDiagnose;
  final VoidCallback onToggleSearch;
  final VoidCallback? onTap;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            if (selecting) ...[
              Checkbox(value: selected, onChanged: (_) => onSelect?.call()),
              const SizedBox(width: 2),
            ],
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(
                  alpha: usable ? 0.12 : 0.05,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                site.displayName.characters.first,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: usable
                      ? theme.colorScheme.primary
                      : theme.disabledColor,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          site.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _KindBadge(text: site.kindLabel, ok: usable),
                    ],
                  ),
                  if (!usable)
                    Text(
                      site.unsupportedReason,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    )
                  else
                    Text(
                      site.searchable == 1 ? site.key : '不参与搜索 · ${site.key}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: site.searchable == 1 ? 0.4 : 0.62,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!selecting) ...[
              if (health != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: '${health!.statusLabel} · ${health!.message}',
                  child: _HealthDot(status: health!.status),
                ),
              ],
              if (active)
                Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 20,
                )
              else if (usable)
                const Icon(Icons.chevron_right_rounded, size: 20)
              else
                Icon(Icons.block_rounded, color: theme.disabledColor, size: 18),
              const SizedBox(width: 4),
              _RowIconButton(
                icon: site.searchable == 1
                    ? Icons.search_rounded
                    : Icons.search_off_rounded,
                tooltip: site.searchable == 1
                    ? '参与搜索：已开启（点击关闭）'
                    : '参与搜索：已关闭（点击开启）',
                color: site.searchable == 1
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
                onPressed: onToggleSearch,
              ),
              _RowIconButton(
                icon: Icons.monitor_heart_outlined,
                tooltip: '诊断',
                onPressed: onDiagnose,
              ),
              _RowIconButton(
                icon: Icons.edit_outlined,
                tooltip: '编辑',
                onPressed: onEdit,
              ),
              _RowIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                onPressed: onDelete,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 站点行尾的体检状态点：绿=有内容/分类，黄=需补 ext，红=失败。
class _HealthDot extends StatelessWidget {
  const _HealthDot({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (status) {
      'ok-content' || 'ok-classes' => const Color(0xFF4CAF50),
      'needs-ext' => const Color(0xFFFFB300),
      'empty' => theme.colorScheme.onSurface.withValues(alpha: 0.55),
      _ => theme.colorScheme.error,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 逐个源真实调用主页的体检弹窗；并发 4，边出结果边显示。
class _HealthCheckDialog extends StatefulWidget {
  const _HealthCheckDialog({required this.sites});
  final List<SourceBean> sites;

  @override
  State<_HealthCheckDialog> createState() => _HealthCheckDialogState();
}

class _HealthCheckDialogState extends State<_HealthCheckDialog> {
  final Map<String, SourceHealth> _results = {};
  int _done = 0;
  bool _running = true;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    final app = AppScope.of(context);
    var next = 0;
    Future<void> worker() async {
      while (!_closed && mounted) {
        final index = next++;
        if (index >= widget.sites.length) return;
        final site = widget.sites[index];
        final health = await app.probeSite(site);
        if (!mounted) return;
        setState(() {
          _results[site.key] = health;
          _done++;
        });
      }
    }

    final workers = <Future<void>>[];
    for (var i = 0; i < 4 && i < widget.sites.length; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
    if (!mounted) return;
    setState(() => _running = false);
  }

  void _close() {
    _closed = true;
    Navigator.of(context).pop(_results);
  }

  String get _title {
    if (_running) return '源体检 $_done/${widget.sites.length}';
    final ok = _results.values.where((e) => e.ok).length;
    final need = _results.values.where((e) => e.needsExt).length;
    final bad = _results.length - ok - need;
    return '体检完成：$ok 可用 · $need 需补 ext · $bad 不可用';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: 560,
        height: 400,
        child: ListView.builder(
          itemCount: widget.sites.length,
          itemBuilder: (context, index) {
            final site = widget.sites[index];
            final health = _results[site.key];
            final (icon, color) = switch (health?.status) {
              'ok-content' || 'ok-classes' => (
                Icons.check_circle_rounded,
                const Color(0xFF4CAF50),
              ),
              'needs-ext' => (Icons.info_rounded, const Color(0xFFFFB300)),
              'empty' => (
                Icons.remove_circle_outline,
                theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
              'error' => (Icons.error_rounded, theme.colorScheme.error),
              _ => (Icons.more_horiz_rounded, theme.colorScheme.outline),
            };
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  health == null
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, size: 18, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          site.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (health != null)
                          Text(
                            health.message,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: health.ok
                                  ? theme.colorScheme.onSurface.withValues(
                                      alpha: 0.55,
                                    )
                                  : theme.colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (health != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        health.statusLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: color,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(onPressed: _close, child: Text(_running ? '停止并关闭' : '关闭')),
      ],
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.text, required this.ok});
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: ok
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : theme.colorScheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: ok ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: onTap != null,
      leading: Icon(icon, size: 20),
      title: Text(title, style: theme.textTheme.bodyMedium),
      subtitle: Text(subtitle, style: theme.textTheme.labelSmall),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
    );
  }
}

class _DriveAccountRow extends StatelessWidget {
  const _DriveAccountRow({required this.provider, required this.app});
  final String provider;
  final AppState app;

  IconData get _icon => switch (provider) {
    'quark' => Icons.cloud_circle_outlined,
    'uc' => Icons.cloud_queue_rounded,
    'baidu' => Icons.cloud_done_outlined,
    '115' => Icons.folder_special_outlined,
    'bili' => Icons.smart_display_outlined,
    _ => Icons.cloud_outlined,
  };

  bool get _webLogin => driveSupportsWebLogin(provider);

  Future<void> _login(BuildContext context) async {
    if (!_webLogin) {
      await _manualCookie(context);
      return;
    }
    final ok = await showDriveLoginDialog(context, provider);
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已绑定${driveProviderNames[provider] ?? provider}'),
        ),
      );
    }
  }

  Future<void> _ucTvLogin(BuildContext context) async {
    final ok = await showUcTvLoginDialog(context);
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('UC TV 授权已保存到本机')));
    }
  }

  Future<void> _manualCookie(BuildContext context) async {
    final ok = await showDriveCookieDialog(context, provider);
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已保存${driveProviderNames[provider] ?? provider} Cookie',
          ),
        ),
      );
    }
  }

  Future<void> _logout(BuildContext context) async {
    final name = driveProviderNames[provider] ?? provider;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('退出 $name？'),
        content: const Text('只会删除本机保存的登录凭据，可随时重新扫码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) await app.removeDriveAccount(provider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = app.driveAccounts[provider];
    final hasCookie = (account?.cookie ?? '').trim().isNotEmpty;
    final guest = account?.extra['guest'] == 'true';
    final signedIn = hasCookie && !guest;
    final tvBound = (account?.extra['uctvToken'] ?? '').trim().isNotEmpty;
    final name = driveProviderNames[provider] ?? provider;
    final optional = provider == 'bili';
    final statusLabel = guest
        ? '已失效'
        : signedIn
        ? '已登录'
        : (optional ? '未配置' : '未登录');
    final subtitleText = guest
        ? (optional
              ? 'Cookie 已失效，可重新粘贴（未配置也能播 360P / 480P）'
              : '会话已失效（游客态），请重新扫码登录')
        : (signedIn
              ? (account!.username.isNotEmpty
                    ? account.username
                    : 'Cookie 已保存到本机')
              : optional
              ? '可选：粘贴浏览器 Cookie 后可用高清 / 大会员画质，不配置也能播 360P / 480P'
              : (_webLogin
                    ? '在官方网页中扫码登录，登录后蜘蛛源可读取网盘内的资源'
                    : '粘贴浏览器 Cookie 后，蜘蛛源才能读取该网盘内的资源'));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon, size: 20),
      title: Row(
        children: [
          Text(name, style: theme.textTheme.bodyMedium),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: signedIn
                  ? theme.colorScheme.primary.withValues(alpha: 0.12)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.6,
                    ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: signedIn
                    ? theme.colorScheme.primary
                    : (guest && !optional
                          ? theme.colorScheme.error
                          : theme.disabledColor),
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(subtitleText, style: theme.textTheme.labelSmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (provider == 'uc')
            TextButton(
              onPressed: () => _ucTvLogin(context),
              child: Text(tvBound ? 'TV 已授权' : 'TV 扫码'),
            ),
          if (_webLogin)
            TextButton(
              onPressed: () => _manualCookie(context),
              child: const Text('手动 Cookie'),
            ),
          if (guest && !optional)
            FilledButton.tonal(
              onPressed: () => _login(context),
              child: const Text('重新登录'),
            )
          else if (hasCookie)
            TextButton(
              onPressed: () => _logout(context),
              child: const Text('退出'),
            )
          else
            FilledButton.tonal(
              onPressed: () => _login(context),
              child: Text(_webLogin ? '网页扫码登录' : '粘贴 Cookie'),
            ),
        ],
      ),
    );
  }
}

class _ThemeModeTabs extends StatelessWidget {
  const _ThemeModeTabs({required this.value, required this.onChanged});
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const items = [
      (ThemeMode.system, Icons.brightness_auto_rounded, '跟随系统'),
      (ThemeMode.light, Icons.light_mode_rounded, '浅色'),
      (ThemeMode.dark, Icons.dark_mode_rounded, '深色'),
    ];
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(item.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == item.$1
                        ? theme.colorScheme.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        item.$2,
                        size: 15,
                        color: value == item.$1
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          item.$3,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: value == item.$1
                                ? FontWeight.w800
                                : FontWeight.w500,
                            color: value == item.$1
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.45),
                    blurRadius: 14,
                  ),
                ]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
            : null,
      ),
    );
  }
}

class _MpvExtensionTile extends StatefulWidget {
  const _MpvExtensionTile();

  @override
  State<_MpvExtensionTile> createState() => _MpvExtensionTileState();
}

class _MpvExtensionTileState extends State<_MpvExtensionTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;
  MpvProgress? _progress;
  Map<String, String> _meta = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final installed = await MpvExtension.instance.isInstalled;
    final meta = await MpvExtension.instance.meta;
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _meta = meta;
      _loading = false;
    });
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = const MpvProgress(0, 0, '准备下载');
    });
    try {
      await MpvExtension.instance.install(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Yaozhi MPV 扩展安装完成')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Yaozhi MPV 扩展？'),
        content: const Text('只会删除本机下载的播放器文件，不影响订阅和播放记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MpvExtension.instance.remove();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _progress;
    final tag = _meta['tag'] ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.movie_filter_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Yaozhi MPV 扩展',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? '${tag.isEmpty ? '已下载' : tag} · 播放页可切换外部 MPV 窗口'
                        : '内置播放器已支持 HLS / MP4 / MKV；需要蓝光、HEVC 或 HDR 时可下载整合包（约 320 MB）',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (progress != null && _busy) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.stage}${progress.fraction == null ? '' : ' · ${(progress.fraction! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _JvmRuntimeTile extends StatefulWidget {
  const _JvmRuntimeTile({super.key});

  @override
  State<_JvmRuntimeTile> createState() => _JvmRuntimeTileState();
}

class _JvmRuntimeTileState extends State<_JvmRuntimeTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    JvmRuntime.instance.progress.addListener(_onProgress);
    _refresh();
  }

  @override
  void dispose() {
    JvmRuntime.instance.progress.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final installed = await JvmRuntime.instance.installed();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _loading = false;
    });
  }

  Future<void> startInstall() async {
    if (_busy || _installed) return;
    await _install();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await JvmRuntime.instance.ensureInstalled();
      await _refresh();
      if (!mounted) return;
      await AppScope.of(context).refreshJarReady();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('JVM 运行时安装完成，JAR 蜘蛛源已可用')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 JVM 运行时？'),
        content: const Text('只会删除本机下载的运行时文件，JAR 蜘蛛源下次使用时会重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await JvmRuntime.instance.remove();
      await _refresh();
      if (!mounted) return;
      await AppScope.of(context).refreshJarReady();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = JvmRuntime.instance.progress.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.coffee_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'JVM 运行时',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? 'JAR / DEX 蜘蛛源可运行（JRE 17 + dex2jar）'
                        : '首次使用 .jar 蜘蛛时按需下载（约 85 MB），不占用安装包体积',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (_busy && progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.value,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.message}${progress.value == null ? '' : ' · ${(progress.value! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _ArmBridgeTile extends StatefulWidget {
  const _ArmBridgeTile({super.key});

  @override
  State<_ArmBridgeTile> createState() => _ArmBridgeTileState();
}

class _ArmBridgeTileState extends State<_ArmBridgeTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ArmBridgeRuntime.instance.progress.addListener(_onProgress);
    _refresh();
  }

  @override
  void dispose() {
    ArmBridgeRuntime.instance.progress.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final installed = await ArmBridgeRuntime.instance.installed();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _loading = false;
    });
  }

  Future<void> startInstall() async {
    if (_busy || _installed) return;
    await _install();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ArmBridgeRuntime.instance.ensureInstalled();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加固壳支持已就绪，加固壳源首次调用会自动解包')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除加固壳支持？'),
        content: const Text(
          '只会删除 unidbg ARM 运行时；已解包的 payload 缓存会保留，缓存过的源仍可正常使用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ArmBridgeRuntime.instance.remove();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ArmBridgeRuntime.instance.progress.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.shield_moon_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '加固壳支持',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? '加固壳（Guard / DexNative）源可解包（unidbg 0.9.9 · dynarmic）'
                        : '加固壳源首次调用时解包一次（约 39 MB），之后走纯 Java 快路径',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (_busy && progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.value,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.message}${progress.value == null ? '' : ' · ${(progress.value! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _PythonRuntimeTile extends StatefulWidget {
  const _PythonRuntimeTile({super.key});

  @override
  State<_PythonRuntimeTile> createState() => _PythonRuntimeTileState();
}

class _PythonRuntimeTileState extends State<_PythonRuntimeTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    PyRuntime.instance.progress.addListener(_onProgress);
    _refresh();
  }

  @override
  void dispose() {
    PyRuntime.instance.progress.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final installed = await PyRuntime.instance.installed();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _loading = false;
    });
  }

  Future<void> startInstall() async {
    if (_busy || _installed) return;
    await _install();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PyRuntime.instance.ensureInstalled();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Python 运行时安装完成，PY 蜘蛛源已可用')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Python 运行时？'),
        content: const Text('只会删除本机下载的运行时文件，PY 蜘蛛源下次使用时会重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PyRuntime.instance.remove();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = PyRuntime.instance.progress.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.terminal_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Python 运行时',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? 'PY 蜘蛛源可运行（Python 3.11 + requests/lxml）'
                        : '首次使用 .py 蜘蛛时按需下载（约 20 MB），不占用安装包体积',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (_busy && progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.value,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.message}${progress.value == null ? '' : ' · ${(progress.value! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 订阅与源管理：本地导入 / 合并导出 / 备份恢复
// -----------------------------------------------------------------------------

Future<void> _importLocalJsonFile(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.jsonType],
    );
    if (path == null) return;
    final payload = await LocalImportService.fromJsonFile(path);
    final outcome = await app.importFromLocalText(
      payload.text,
      name: payload.name,
    );
    if (!context.mounted) return;
    _settingsSnack(
      context,
      '已导入「${outcome.profile.name}」：${outcome.siteCount} 个站点',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '本地导入失败：$e');
  }
}

/// 本地 PY：单选 / 多选都会弹窗选择导入到已有订阅，或创建新订阅。
Future<void> _importLocalPyFiles(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final paths = await FileDialogService.pickFiles(
      types: [FileDialogService.pyType],
    );
    if (paths == null || paths.isEmpty) return;
    final sites = await LocalImportService.pySites(paths);
    if (!context.mounted) return;

    final target = await showPyImportTargetDialog(
      context,
      profiles: [
        for (final profile in app.profiles)
          if (!profile.isLiveOnly) profile,
      ],
      initialProfileId: app.activeProfile?.id,
      suggestedName: sites.length == 1
          ? sites.first['name'].toString()
          : '本地 PY 源',
      fileCount: sites.length,
    );
    if (target == null || !context.mounted) return;

    if (target.profileId != null) {
      final ok = await app.addSitesToProfile(target.profileId!, sites);
      if (!context.mounted) return;
      _settingsSnack(
        context,
        ok
            ? '已把 ${sites.length} 个 PY 源加入订阅「${target.name}」'
            : '目标订阅无法添加站点（可能不是 JSON 配置）',
      );
      return;
    }

    final outcome = await app.importFromLocalText(
      jsonEncode({'sites': sites}),
      name: target.name,
    );
    if (!context.mounted) return;
    _settingsSnack(
      context,
      '已创建订阅「${outcome.profile.name}」：${outcome.siteCount} 个站点',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '本地 PY 导入失败：$e');
  }
}

Future<void> _importLocalLive(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.liveType],
    );
    if (path == null) return;
    final imported = await LocalLiveService.importFile(path);
    final url = LocalLiveService.fileUrlOfPath(imported.filePath);
    await app.addLocalLive(
      LiveBean(name: imported.name, api: url, type: '0', url: url, timeout: 15),
    );
    if (!context.mounted) return;
    _settingsSnack(context, '已导入本地直播源「${imported.name}」');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导入本地直播源失败：$e');
  }
}

Future<void> _importLocalPackage(
  BuildContext context, {
  bool zip = false,
}) async {
  final app = AppScope.of(context);
  try {
    final path = zip
        ? await FileDialogService.pickFile(types: [FileDialogService.zipType])
        : await FileDialogService.pickDirectory();
    if (path == null) return;
    final payload = zip
        ? await LocalImportService.fromPackageArchive(path)
        : await LocalImportService.fromPackage(path);
    final outcome = await app.importFromLocalText(
      payload.text,
      name: payload.name,
    );
    if (!context.mounted) return;
    _settingsSnack(
      context,
      '已导入本地包「${outcome.profile.name}」：${outcome.siteCount} 个站点',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '本地包导入失败：$e');
  }
}

Future<void> _importKazumiFromRepo(BuildContext context, AppState app) async {
  _settingsSnack(context, '正在获取 Kazumi 规则仓库…');
  List<Map<String, dynamic>> index;
  try {
    index = await app.sourceService.kazumi.fetchIndex();
  } catch (e) {
    if (context.mounted) {
      _settingsSnack(context, '获取 Kazumi 规则仓库失败：$e');
    }
    return;
  }
  if (!context.mounted) return;
  final installed = {for (final rule in app.kazumiRules) rule.name};
  final picked = await showDialog<Set<String>>(
    context: context,
    builder: (_) => _KazumiRulePickerDialog(rules: index, installed: installed),
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;
  _settingsSnack(context, '正在下载 ${picked.length} 条规则…');
  final results = await Future.wait([
    for (final name in picked) _fetchKazumiRule(app, name),
  ]);
  final rules = <KazumiRule>[];
  var failed = 0;
  for (final rule in results) {
    if (rule == null) {
      failed++;
    } else {
      rules.add(rule);
    }
  }
  if (rules.isEmpty) {
    if (context.mounted) _settingsSnack(context, '规则下载失败，请检查网络后重试');
    return;
  }
  await app.importKazumiRules(rules);
  if (!context.mounted) return;
  _settingsSnack(
    context,
    '已导入 ${rules.length} 条 Kazumi 规则'
    '${failed > 0 ? '（$failed 条下载失败）' : ''}；到搜索页即可检索',
  );
}

Future<KazumiRule?> _fetchKazumiRule(AppState app, String name) async {
  try {
    return KazumiRule.fromJson(await app.sourceService.kazumi.fetchRule(name));
  } catch (e) {
    AppLog.w('kazumi', '规则 $name 下载失败', e);
    return null;
  }
}

Future<void> _importKazumiFile(BuildContext context, AppState app) async {
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.jsonType],
      confirmButtonText: '导入 Kazumi 规则',
    );
    if (path == null) return;
    final text = await FileDialogService.readText(path);
    final decoded = jsonDecode(text);
    final maps = <Map<String, dynamic>>[];
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) maps.add(Map<String, dynamic>.from(item));
      }
    } else if (decoded is Map) {
      maps.add(Map<String, dynamic>.from(decoded));
    }
    final rules = <KazumiRule>[];
    for (final map in maps) {
      final rule = KazumiRule.fromJson(map);
      if (rule.valid) rules.add(rule);
    }
    if (rules.isEmpty) {
      if (context.mounted) _settingsSnack(context, '没有识别到有效的 Kazumi 规则');
      return;
    }
    await app.importKazumiRules(rules);
    if (context.mounted) {
      _settingsSnack(context, '已导入 ${rules.length} 条 Kazumi 规则');
    }
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导入 Kazumi 规则失败：$e');
  }
}

Future<void> _deleteKazumiRule(
  BuildContext context,
  AppState app,
  KazumiRule rule,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除 Kazumi 规则'),
      content: Text('将移除「${rule.name}」这条动漫源；已下载的剧集缓存不受影响。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await app.removeKazumiRule(rule.key);
  if (context.mounted) {
    _settingsSnack(context, '已删除 Kazumi 规则「${rule.name}」');
  }
}

class _KazumiRuleRow extends StatelessWidget {
  const _KazumiRuleRow({required this.rule, required this.onDelete});

  final KazumiRule rule;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final search = rule.searchMode == 'api' ? 'API 搜索' : 'XPath 搜索';
    final chapter = rule.chapterMode == 'api' ? 'API 选集' : 'XPath 选集';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.auto_awesome_rounded, size: 18),
      title: Text(rule.name),
      subtitle: Text(
        'v${rule.version.isEmpty ? '?' : rule.version} · $search / $chapter',
      ),
      trailing: IconButton(
        tooltip: '删除规则',
        icon: const Icon(Icons.delete_outline_rounded, size: 19),
        onPressed: onDelete,
      ),
    );
  }
}

class _KazumiRulePickerDialog extends StatefulWidget {
  const _KazumiRulePickerDialog({required this.rules, required this.installed});

  final List<Map<String, dynamic>> rules;
  final Set<String> installed;

  @override
  State<_KazumiRulePickerDialog> createState() =>
      _KazumiRulePickerDialogState();
}

class _KazumiRulePickerDialogState extends State<_KazumiRulePickerDialog> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = [
      for (final item in widget.rules)
        if (item['name']?.toString().trim().isNotEmpty == true) item,
    ]..sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));
    return AlertDialog(
      title: const Text('导入 Kazumi 规则'),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择要导入的动漫源规则（共 ${items.length} 条，已安装的会覆盖更新）：',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final item in items)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(item['name'].toString()),
                        title: Text(item['name'].toString()),
                        subtitle: Text(
                          'v${item['version'] ?? '?'}'
                          '${widget.installed.contains(item['name']) ? ' · 已安装' : ''}',
                        ),
                        onChanged: (checked) {
                          setState(() {
                            final name = item['name'].toString();
                            if (checked == true) {
                              _selected.add(name);
                            } else {
                              _selected.remove(name);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              if (_selected.length == items.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(items.map((item) => item['name'].toString()));
              }
            });
          },
          child: Text(_selected.length == items.length ? '全不选' : '全选'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop({..._selected}),
          child: Text('导入${_selected.isEmpty ? '' : '（${_selected.length}）'}'),
        ),
      ],
    );
  }
}

/// TMDB 凭据在设置行上的说明：只说当前用的是哪一种，不显示任何密钥内容。
String _tmdbCredentialLabel(String apiKey, String readToken) {
  final credential = TmdbCredential.resolve(
    apiKey: apiKey,
    readToken: readToken,
  );
  if (credential.isConfigured) return ' · TMDB ${credential.label}';
  final filled = apiKey.trim().isNotEmpty || readToken.trim().isNotEmpty;
  return filled ? ' · TMDB 凭据无法识别' : ' · TMDB 未配置';
}

String _artworkSourceLabel(String raw) =>
    switch (normalizeArtworkPriority(raw)) {
      'tmdb' => 'TMDB',
      'imdb' => 'IMDb',
      _ => '豆瓣',
    };

Future<void> _openArtworkSettings(BuildContext context, AppState app) async {
  final result = await showDialog<_ArtworkConfig>(
    context: context,
    builder: (_) => _ArtworkSettingsDialog(
      initialPriority: normalizeArtworkPriority(
        app.playerSettings.artworkPriority,
      ),
      initialKey: app.playerSettings.tmdbApiKey,
      initialToken: app.playerSettings.tmdbReadToken,
    ),
  );
  if (result == null) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(
      artworkPriority: result.priority,
      tmdbApiKey: result.key,
      tmdbReadToken: result.token,
    ),
  );
  if (context.mounted) {
    _settingsSnack(context, '封面来源已保存：${_artworkSourceLabel(result.priority)}');
  }
}

class _ArtworkConfig {
  const _ArtworkConfig(this.priority, this.key, this.token);
  final String priority;

  /// v3 API Key（走 query）与 v4 Read Access Token（走 Authorization 头）。
  final String key;
  final String token;
}

Future<void> _openBossKeySettings(BuildContext context, AppState app) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) =>
        _BossKeyDialog(initial: normalizeBossKey(app.playerSettings.bossKey)),
  );
  if (result == null) return;
  await app.setPlayerSettings(app.playerSettings.copyWith(bossKey: result));
  final ok = await BossKeyService.instance.applyBossKey(result);
  if (!context.mounted) return;
  if (result != 'off' && !ok) {
    _settingsSnack(
      context,
      '老板键注册失败（可能被其它软件占用）：'
      '${BossKeyService.instance.lastHotKeyError}',
    );
    return;
  }
  _settingsSnack(
    context,
    result == 'off' ? '已关闭老板键' : '老板键已设为 ${bossKeyLabel(result)}',
  );
}

class _BossKeyDialog extends StatefulWidget {
  const _BossKeyDialog({required this.initial});
  final String initial;

  @override
  State<_BossKeyDialog> createState() => _BossKeyDialogState();
}

class _BossKeyDialogState extends State<_BossKeyDialog> {
  late String _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
      height: 1.5,
    );
    return AlertDialog(
      title: const Text('老板键'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '按下后自动暂停视频并把软件收进系统托盘；再按一次老板键或点托盘图标，'
                '回到之前的播放状态与窗口形态（全屏回全屏、小窗回小窗）。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
              const SizedBox(height: 8),
              Text('沉浸观影模式下老板键不生效。', style: hint),
              const SizedBox(height: 14),
              for (final item in kBossKeyShortcuts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(item.$2),
                  trailing: _value == item.$1
                      ? const Icon(Icons.check_circle_rounded, size: 20)
                      : null,
                  onTap: () => setState(() => _value = item.$1),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_value),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ArtworkSettingsDialog extends StatefulWidget {
  const _ArtworkSettingsDialog({
    required this.initialPriority,
    required this.initialKey,
    this.initialToken = '',
  });

  final String initialPriority;
  final String initialKey;
  final String initialToken;

  @override
  State<_ArtworkSettingsDialog> createState() => _ArtworkSettingsDialogState();
}

class _ArtworkSettingsDialogState extends State<_ArtworkSettingsDialog> {
  late String _priority = widget.initialPriority;

  /// 旧版本只有一个输入框；把粘在里面的令牌摆回令牌框，用户一眼看得懂。
  late final TmdbCredential _initial = TmdbCredential.resolve(
    apiKey: widget.initialKey,
    readToken: widget.initialToken,
  );
  late final TextEditingController _key = TextEditingController(
    text: _initial.kind == TmdbCredentialKind.apiKey ? _initial.value : '',
  );
  late final TextEditingController _token = TextEditingController(
    text: _initial.kind == TmdbCredentialKind.readToken ? _initial.value : '',
  );
  bool _probing = false;
  List<ArtworkProbeResult> _results = const [];
  String _probeError = '';

  TmdbCredential get _keyCredential => TmdbCredential.parse(_key.text);
  TmdbCredential get _tokenCredential => TmdbCredential.parse(_token.text);

  /// 实际生效的那一份：两份都填时优先读访问令牌（走请求头，不把密钥放进 URL）。
  TmdbCredential get _credential =>
      TmdbCredential.resolve(apiKey: _key.text, readToken: _token.text);

  /// 填了就必须是对应格式：密钥框里放令牌、令牌框里放密钥都要挡住。
  bool get _canSave =>
      (_key.text.trim().isEmpty ||
          _keyCredential.kind == TmdbCredentialKind.apiKey) &&
      (_token.text.trim().isEmpty ||
          _tokenCredential.kind == TmdbCredentialKind.readToken);

  @override
  void initState() {
    super.initState();
    _key.addListener(_onChanged);
    _token.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _key.removeListener(_onChanged);
    _token.removeListener(_onChanged);
    _key.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final app = AppScope.of(context);
    setState(() {
      _probing = true;
      _probeError = '';
      _results = const [];
    });
    try {
      // 测试前先保存凭据，否则服务读到的还是旧配置。
      await app.setPlayerSettings(
        app.playerSettings.copyWith(
          tmdbApiKey: _keyCredential.kind == TmdbCredentialKind.apiKey
              ? _keyCredential.value
              : '',
          tmdbReadToken: _tokenCredential.kind == TmdbCredentialKind.readToken
              ? _tokenCredential.value
              : '',
        ),
      );
      final results = await app.artworkService.probe('流浪地球', year: '2019');
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _probeError = '$e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('横图封面来源'),
      content: SizedBox(
        width: 660,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '沉浸观影的海报轮播、详情页背景与卡片都优先使用横图。'
                '找不到横图时会自动尝试下一个来源，最后回落到源里的竖版海报。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
              const SizedBox(height: 16),
              Text('优先来源', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in const [
                    ('douban', '豆瓣'),
                    ('tmdb', 'TMDB'),
                    ('imdb', 'IMDb'),
                  ])
                    ChoiceChip(
                      label: Text(item.$2),
                      selected: _priority == item.$1,
                      onSelected: (_) => setState(() => _priority = item.$1),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _priority == 'douban'
                    ? '豆瓣：按片名查条目后取剧情剧照里最宽的一张；无需配置。'
                    : (_priority == 'tmdb'
                          ? 'TMDB：优先使用 backdrop 横图；需要 API Key 或 v4 Token，未填写时会自动回落到其它来源。'
                          : 'IMDb：自动查 IMDb 公开图库的剧照；无需登录，也不会出现“配置完没有封面”。'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              Text('TMDB 凭据（填一个即可）', style: theme.textTheme.labelMedium),
              const SizedBox(height: 6),
              TextField(
                controller: _key,
                decoration: const InputDecoration(
                  labelText: 'API 密钥（v3）',
                  hintText: '32 位十六进制，请求时作为 api_key 参数',
                ),
              ),
              if (_key.text.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _keyCredential.kind == TmdbCredentialKind.apiKey
                      ? '格式正确：32 位 API 密钥，请求时作为 api_key 参数。'
                      : (_keyCredential.kind == TmdbCredentialKind.readToken
                            ? '这是读访问令牌，请填到下面的「API 读访问令牌」框。'
                            : _keyCredential.problem),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _keyCredential.kind == TmdbCredentialKind.apiKey
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _token,
                minLines: 1,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'API 读访问令牌（v4）',
                  hintText: 'eyJ 开头的长串，请求时放在 Authorization 头',
                ),
              ),
              if (_token.text.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _tokenCredential.kind == TmdbCredentialKind.readToken
                      ? '格式正确：读访问令牌，请求时放在 Authorization 头里。'
                      : (_tokenCredential.kind == TmdbCredentialKind.apiKey
                            ? '这是 v3 API 密钥，请填到上面的「API 密钥」框。'
                            : _tokenCredential.problem),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _tokenCredential.kind == TmdbCredentialKind.readToken
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ],
              if (_keyCredential.kind == TmdbCredentialKind.apiKey &&
                  _tokenCredential.kind == TmdbCredentialKind.readToken) ...[
                const SizedBox(height: 6),
                Text(
                  '两份都有效：实际使用 ${_credential.label}（令牌优先）。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '两个值在 TMDB 后台都能拿到，填一个就够；都填时优先用读访问令牌'
                '（令牌走请求头，密钥不会出现在 URL 里）。整段粘贴也行，会自动去掉 Bearer 前缀。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.52),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _probing ? null : _probe,
                    icon: _probing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_size_select_large_rounded),
                    label: Text(_probing ? '正在测试…' : '测试封面抓取'),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '测试片名：流浪地球（2019）',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.52,
                      ),
                    ),
                  ),
                ],
              ),
              if (_probeError.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _probeError,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              for (final result in _results) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        switch (result.source) {
                          'tmdb' => 'TMDB',
                          'imdb' => 'IMDb',
                          _ => '豆瓣',
                        },
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: result.url.isEmpty
                          ? Text(
                              '未取到横图：${result.error}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.error.withValues(
                                  alpha: 0.85,
                                ),
                              ),
                            )
                          : Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    result.url,
                                    width: 112,
                                    height: 63,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox(width: 112, height: 63),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    result.url,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.55),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          // 填了却对不上格式（或填错了框）时不让保存，避免存一份用不了的凭据。
          onPressed: _canSave
              ? () => Navigator.of(context).pop(
                  _ArtworkConfig(
                    _priority,
                    _keyCredential.kind == TmdbCredentialKind.apiKey
                        ? _keyCredential.value
                        : '',
                    _tokenCredential.kind == TmdbCredentialKind.readToken
                        ? _tokenCredential.value
                        : '',
                  ),
                )
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<void> _exportMerged(BuildContext context) async {
  final app = AppScope.of(context);
  final picked = await showDialog<Set<String>>(
    context: context,
    builder: (_) => _MergeExportDialog(profiles: app.vodProfiles),
  );
  if (picked == null || picked.isEmpty) return;
  try {
    final text = app.exportMergedConfig(picked);
    final path = await FileDialogService.saveText(
      suggestedName: 'misatv-merged.json',
      text: text,
      type: FileDialogService.jsonType,
    );
    if (!context.mounted) return;
    _settingsSnack(context, path == null ? '已取消导出' : '合并配置已保存到 $path');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '合并导出失败：$e');
  }
}

Future<void> _exportBackup(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final data = app.buildBackupData();
    final text = const JsonEncoder.withIndent('  ').convert(data);
    final stamp = DateTime.now();
    final name =
        'misatv-backup-${stamp.year}'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}-'
        '${stamp.hour.toString().padLeft(2, '0')}'
        '${stamp.minute.toString().padLeft(2, '0')}.json';
    final path = await FileDialogService.saveText(
      suggestedName: name,
      text: text,
      type: FileDialogService.backupType,
    );
    if (!context.mounted) return;
    _settingsSnack(context, path == null ? '已取消导出' : '设置备份已保存到 $path');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导出备份失败：$e');
  }
}

Future<void> _restoreBackup(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.backupType],
    );
    if (path == null) return;
    final text = await FileDialogService.readText(path);
    final data = BackupData.parse(text);
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入设置备份？'),
        content: const Text(
          '会用备份内容覆盖当前的订阅档案、收藏、历史、播放设置与网盘 Cookie。\n'
          '备份文件里的网盘凭据是明文，请只导入你信任的文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('覆盖导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await app.restoreBackupData(data);
    if (!context.mounted) return;
    _settingsSnack(context, '设置备份已导入');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导入备份失败：$e');
  }
}

String _driveAccountsSubtitle(AppState app) {
  bool ready(String key) {
    final account = app.driveAccounts[key];
    return (account?.cookie ?? '').trim().isNotEmpty &&
        account?.extra['guest'] != 'true';
  }

  final signed = [
    for (final entry in driveProviderNames.entries)
      if (ready(entry.key)) entry.value,
  ];
  if (signed.isEmpty) {
    final stale = [
      for (final entry in driveProviderNames.entries)
        if (!AppState.isOptionalDriveProvider(entry.key) &&
            (app.driveAccounts[entry.key]?.cookie ?? '').trim().isNotEmpty &&
            app.driveAccounts[entry.key]?.extra['guest'] == 'true')
          entry.value,
    ];
    return stale.isEmpty
        ? '未登录 · 点击扫码或粘贴 Cookie 配置夸克 / UC / 百度 / 115 / 哔哩'
        : '${stale.join(' / ')} 登录已失效，点击重新配置';
  }
  final usernames = [
    for (final entry in driveProviderNames.entries)
      if (ready(entry.key))
        (app.driveAccounts[entry.key]?.username ?? '').trim(),
  ].where((name) => name.isNotEmpty).toList();
  return '${signed.join(' / ')} 已登录'
      '${usernames.isEmpty ? '' : ' · ${usernames.join(' / ')}'}';
}

void _settingsSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// 开启 / 关闭 R18 过滤：开启时设置关闭密码，关闭时必须验证该密码。
Future<void> _toggleContentFilter(
  BuildContext context,
  AppState app,
  bool enable,
) async {
  if (enable) {
    if (app.contentFilter.hasPassword) {
      await app.setContentFilter(app.contentFilter.copyWith(enabled: true));
      return;
    }
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _SetFilterPasswordDialog(),
    );
    if (password == null) return;
    await app.setContentFilter(
      app.contentFilter.copyWith(
        enabled: true,
        passwordHash: hashContentFilterPassword(password),
      ),
    );
    return;
  }

  // 旧配置可能已开启但没有密码：允许直接关闭，下次开启时会补设密码。
  if (!app.contentFilter.hasPassword) {
    await app.setContentFilter(app.contentFilter.copyWith(enabled: false));
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _VerifyFilterPasswordDialog(settings: app.contentFilter),
  );
  if (confirmed != true) return;
  await app.setContentFilter(app.contentFilter.copyWith(enabled: false));
}

class _SetFilterPasswordDialog extends StatefulWidget {
  const _SetFilterPasswordDialog();

  @override
  State<_SetFilterPasswordDialog> createState() =>
      _SetFilterPasswordDialogState();
}

class _SetFilterPasswordDialogState extends State<_SetFilterPasswordDialog> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordCtrl.text;
    if (password.length < contentFilterPasswordMinLength) {
      setState(() => _error = '密码至少 $contentFilterPasswordMinLength 位');
      return;
    }
    if (password != _confirmCtrl.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('设置关闭密码'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'R18 过滤开启后，关闭过滤需要输入此密码。请设置一个孩子不知道的密码。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: '密码（至少 $contentFilterPasswordMinLength 位）',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '再次输入密码'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开启过滤')),
      ],
    );
  }
}

class _VerifyFilterPasswordDialog extends StatefulWidget {
  const _VerifyFilterPasswordDialog({
    required this.settings,
    this.title = '关闭 R18 过滤',
    this.message = '请输入开启过滤时设置的关闭密码。',
    this.confirmLabel = '关闭过滤',
  });
  final ContentFilterSettings settings;
  final String title;
  final String message;
  final String confirmLabel;

  @override
  State<_VerifyFilterPasswordDialog> createState() =>
      _VerifyFilterPasswordDialogState();
}

class _VerifyFilterPasswordDialogState
    extends State<_VerifyFilterPasswordDialog> {
  final _controller = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.settings.verifyPassword(_controller.text)) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _error = '密码不正确');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.message,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: '关闭密码'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

Future<void> _editContentFilterKeywords(BuildContext context) async {
  final app = AppScope.of(context);
  // 过滤开启时，改屏蔽词等于改变过滤效果，同样需要密码。
  if (app.contentFilter.enabled && app.contentFilter.hasPassword) {
    final verified = await showDialog<bool>(
      context: context,
      builder: (_) => _VerifyFilterPasswordDialog(
        settings: app.contentFilter,
        title: '修改 R18 过滤规则',
        message: '修改屏蔽关键词需要输入开启过滤时设置的密码。',
        confirmLabel: '继续修改',
      ),
    );
    if (verified != true || !context.mounted) return;
  }
  final result = await showDialog<List<String>>(
    context: context,
    builder: (_) =>
        _ContentFilterKeywordsDialog(initial: app.contentFilter.keywords),
  );
  if (result == null) return;
  await app.setContentFilter(app.contentFilter.copyWith(keywords: result));
  if (context.mounted) {
    _settingsSnack(
      context,
      result.isEmpty
          ? '已清空屏蔽关键词（恢复默认词可重新启用）'
          : '已保存 ${result.length} 个屏蔽关键词'
                '${app.contentFilter.enabled ? '' : '；开启「屏蔽 R18 / 成人内容」后生效'}',
    );
  }
}

class _ContentFilterKeywordsDialog extends StatefulWidget {
  const _ContentFilterKeywordsDialog({required this.initial});
  final List<String> initial;

  @override
  State<_ContentFilterKeywordsDialog> createState() =>
      _ContentFilterKeywordsDialogState();
}

class _ContentFilterKeywordsDialogState
    extends State<_ContentFilterKeywordsDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial.join('\n'),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('R18 屏蔽关键词'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '每行一个关键词（也可用逗号分隔），不区分大小写；命中片名、备注、类型、地区、标签或来源名称即隐藏，分类名命中也会从分类栏隐藏。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '屏蔽关键词',
                hintText: 'R18\n18禁\n成人',
                alignLabelWithHint: true,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(
                  () => _controller.text = defaultContentFilterKeywords.join(
                    '\n',
                  ),
                ),
                child: const Text('恢复默认词'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(normalizeContentFilterKeywords(_controller.text.split('\n'))),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<void> _editDanmakuStyle(BuildContext context) async {
  final app = AppScope.of(context);
  final result = await showDialog<DanmakuSettings>(
    context: context,
    builder: (_) => _DanmakuStyleDialog(initial: app.danmakuSettings),
  );
  if (result != null) await app.setDanmakuSettings(result);
}

int _customLineCount(String text) {
  var n = 0;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isNotEmpty && !t.startsWith('#')) n++;
  }
  return n;
}

String _danmakuEndpointsSubtitle(DanmakuSettings settings) {
  final enabled = settings.endpoints
      .where((e) => e.enabled && e.url.trim().isNotEmpty)
      .length;
  final custom = settings.endpoints
      .where((e) => !isBuiltinEndpoint(e.url))
      .length;
  return '已启用 $enabled 个'
      '${custom == 0 ? '' : ' · 自定义 $custom 个'}'
      '；匹配失败时会自动扩大搜索';
}

Future<void> _editDanmakuEndpoints(BuildContext context) async {
  final app = AppScope.of(context);
  final result = await showDialog<DanmakuSettings>(
    context: context,
    builder: (_) => _DanmakuEndpointDialog(initial: app.danmakuSettings),
  );
  if (result != null) await app.setDanmakuSettings(result);
}

class _DanmakuEndpointDialog extends StatefulWidget {
  const _DanmakuEndpointDialog({required this.initial});
  final DanmakuSettings initial;

  @override
  State<_DanmakuEndpointDialog> createState() => _DanmakuEndpointDialogState();
}

class _DanmakuEndpointDialogState extends State<_DanmakuEndpointDialog> {
  late final Map<String, bool> _enabled = {
    for (final e in widget.initial.endpoints)
      normalizeEndpointBase(e.url): e.enabled,
  };
  late final TextEditingController _customCtrl = TextEditingController(
    text: customEndpointsText(widget.initial.endpoints),
  );

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('弹幕接口'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '勾选参与搜索的内置接口；匹配失败时播放器会自动再查一遍所有接口。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
                ),
              ),
              const SizedBox(height: 6),
              for (final e in builtinDanmakuEndpoints)
                SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _enabled[normalizeEndpointBase(e.url)] ?? e.enabled,
                  onChanged: (v) => setState(
                    () => _enabled[normalizeEndpointBase(e.url)] = v,
                  ),
                  title: Text(e.name),
                  subtitle: Text(
                    e.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              const Divider(height: 24),
              TextField(
                controller: _customCtrl,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '自定义接口',
                  hintText: '每行：名称@https://...',
                  helperText: '只要兼容 TVBox 弹幕协议（/api/v2/search/anime 等）即可',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final toggled = <DanmakuEndpoint>[
              for (final e in widget.initial.endpoints)
                isBuiltinEndpoint(e.url)
                    ? e.copyWith(
                        enabled:
                            _enabled[normalizeEndpointBase(e.url)] ?? e.enabled,
                      )
                    : e,
            ];
            Navigator.of(context).pop(
              widget.initial.copyWith(
                endpoints: mergeEndpoints(toggled, _customCtrl.text),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _DanmakuStyleDialog extends StatefulWidget {
  const _DanmakuStyleDialog({required this.initial});
  final DanmakuSettings initial;

  @override
  State<_DanmakuStyleDialog> createState() => _DanmakuStyleDialogState();
}

class _DanmakuStyleDialogState extends State<_DanmakuStyleDialog> {
  late double _regionRatio = widget.initial.regionRatio;
  late double _fontSize = widget.initial.fontSize;
  late double _opacity = widget.initial.opacity;
  late double _speed = widget.initial.speed;
  late double _offset = widget.initial.offset;
  late final TextEditingController _blockWordCtrl = TextEditingController(
    text: widget.initial.blockWords.join('\n'),
  );

  @override
  void dispose() {
    _blockWordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      int divisions,
      ValueChanged<double> onChanged,
      String display,
    ) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(display, style: theme.textTheme.labelSmall),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (v) => setState(() => onChanged(v)),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('弹幕样式'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              slider(
                '显示区域',
                _regionRatio,
                danmakuRegionMinRatio,
                danmakuRegionMaxRatio,
                18,
                (v) => _regionRatio = v,
                '${(_regionRatio * 100).round()}% 屏',
              ),
              const SizedBox(height: 4),
              slider(
                '字号',
                _fontSize,
                12,
                40,
                28,
                (v) => _fontSize = v,
                '${_fontSize.toStringAsFixed(0)}px',
              ),
              slider(
                '透明度',
                _opacity,
                0.2,
                1,
                8,
                (v) => _opacity = v,
                '${(_opacity * 100).round()}%',
              ),
              slider(
                '滚动速度',
                _speed,
                60,
                240,
                18,
                (v) => _speed = v,
                '${_speed.round()}px/s',
              ),
              slider(
                '时间偏移',
                _offset,
                -10,
                10,
                40,
                (v) => _offset = v,
                '${_offset.toStringAsFixed(1)}s',
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _blockWordCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '弹幕屏蔽词',
                  hintText: '每行一个关键词，如：剧透、广告；/正则/ 也可',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            widget.initial.copyWith(
              regionRatio: _regionRatio,
              fontSize: _fontSize,
              opacity: _opacity,
              speed: _speed,
              offset: _offset,
              blockWords: normalizeDanmakuBlockWords(_blockWordCtrl.text),
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<void> _pickPlayerFit(BuildContext context, AppState app) async {
  final current = normalizePlayerFit(app.playerSettings.fit);
  final picked = await showDialog<PlayerFit>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('画面比例'),
      children: [
        for (final fit in playerFits)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(fit),
            child: Row(
              children: [
                Icon(
                  current == fit
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 20,
                  color: current == fit
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 10),
                Text(fit.label),
              ],
            ),
          ),
      ],
    ),
  );
  if (picked == null) return;
  await app.setPlayerSettings(app.playerSettings.copyWith(fit: picked.name));
}

Future<void> _editAssrtToken(BuildContext context) async {
  final app = AppScope.of(context);
  final token = await showDialog<String>(
    context: context,
    builder: (_) => _TokenDialog(initial: app.assrtToken),
  );
  if (token == null) return;
  await app.setAssrtToken(token);
  if (context.mounted) {
    _settingsSnack(
      context,
      token.trim().isEmpty ? '已清空 assrt token' : '已保存 assrt token',
    );
  }
}

String _defaultPlayerLabel(AppState app) {
  final id = app.playerSettings.defaultPlayer;
  if (id == kDefaultPlayerYaozhiMpv) return 'Yaozhi MPV';
  final path = app.playerSettings.defaultCustomPlayerPathValue;
  if (path.isNotEmpty) {
    for (final entry in app.playerSettings.externalPlayers) {
      if (entry.path.trim().toLowerCase() != path.toLowerCase()) continue;
      final name = entry.name.trim().isEmpty
          ? externalPlayerDisplayName(entry.path)
          : entry.name.trim();
      return externalPlayerExists(path) ? name : '$name（文件不存在）';
    }
    return externalPlayerDisplayName(path);
  }
  return '内置播放器';
}

Future<void> _pickDefaultPlayer(BuildContext context, AppState app) async {
  final mpvInstalled = await MpvExtension.instance.isInstalled;
  if (!context.mounted) return;
  final current = app.playerSettings.defaultPlayer;
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('默认播放器'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DefaultPlayerTile(
                icon: Icons.desktop_windows_outlined,
                title: '内置播放器',
                subtitle: 'MisaTV 内置 fvp 内核',
                selected:
                    normalizeDefaultPlayer(current) == kDefaultPlayerBuiltin,
                onTap: () => Navigator.of(ctx).pop(kDefaultPlayerBuiltin),
              ),
              _DefaultPlayerTile(
                icon: Icons.play_circle_outline_rounded,
                title: 'Yaozhi MPV',
                subtitle: mpvInstalled
                    ? '已安装 · 独立 MPV 窗口'
                    : '未安装 · 播放时会回退到内置播放器',
                selected: current == kDefaultPlayerYaozhiMpv,
                onTap: () => Navigator.of(ctx).pop(kDefaultPlayerYaozhiMpv),
              ),
              for (final entry in app.playerSettings.externalPlayers)
                _DefaultPlayerTile(
                  icon: Icons.open_in_new_rounded,
                  title: entry.name.trim().isEmpty
                      ? externalPlayerDisplayName(entry.path)
                      : entry.name.trim(),
                  subtitle: externalPlayerExists(entry.path)
                      ? entry.path
                      : '文件不存在 · ${entry.path}',
                  selected: current == defaultCustomPlayerId(entry.path),
                  enabled: externalPlayerExists(entry.path),
                  onTap: () =>
                      Navigator.of(ctx).pop(defaultCustomPlayerId(entry.path)),
                ),
              if (app.playerSettings.externalPlayers.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '还没有自定义第三方播放器，可在上一项「自定义第三方播放器」里添加。',
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurface
                          .withValues(alpha: 0.72),
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(defaultPlayer: picked),
  );
  if (!context.mounted) return;
  _settingsSnack(context, '默认播放器已设为 ${_defaultPlayerLabel(app)}');
}

class _DefaultPlayerTile extends StatelessWidget {
  const _DefaultPlayerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
          : const Icon(Icons.circle_outlined, size: 18),
      onTap: enabled ? onTap : null,
    );
  }
}

Future<void> _editExternalPlayers(BuildContext context) async {
  final app = AppScope.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('自定义第三方播放器'),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: app,
              builder: (ctx, _) {
                final entries = app.playerSettings.externalPlayers;
                if (entries.isEmpty) {
                  return Text(
                    '还没有添加播放器。点击下方「添加播放器」选择任意播放器 exe，'
                    '无需安装或在系统中注册；添加后会出现在播放器的「外部播放器」列表最前面。',
                    style: Theme.of(ctx).textTheme.bodySmall
                        ?.copyWith(height: 1.6),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in entries)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.play_circle_outline_rounded),
                        title: Text(
                          entry.name.trim().isEmpty
                              ? externalPlayerDisplayName(entry.path)
                              : entry.name,
                        ),
                        subtitle: Text(
                          externalPlayerExists(entry.path)
                              ? entry.path
                              : '文件不存在 · ${entry.path}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: '移除',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () =>
                              _removeExternalPlayer(ctx, app, entry),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.tonalIcon(
          onPressed: () => _addExternalPlayers(ctx, app),
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加播放器'),
        ),
      ],
    ),
  );
}

Future<void> _addExternalPlayers(BuildContext context, AppState app) async {
  List<String>? paths;
  try {
    paths = await FileDialogService.pickFiles(
      types: const [FileDialogService.exeType],
      confirmButtonText: '添加播放器',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '无法打开文件选择器：$e');
    return;
  }
  if (paths == null || paths.isEmpty) return;
  final entries = [...app.playerSettings.externalPlayers];
  final seen = {for (final entry in entries) entry.path.trim().toLowerCase()};
  var added = 0;
  for (final raw in paths) {
    final path = raw.trim();
    if (path.isEmpty || !seen.add(path.toLowerCase())) continue;
    entries.add(
      ExternalPlayerEntry(name: externalPlayerDisplayName(path), path: path),
    );
    added++;
  }
  if (added == 0) {
    if (context.mounted) _settingsSnack(context, '选择的播放器已经在列表中了');
    return;
  }
  await app.setCustomExternalPlayers(entries);
  if (context.mounted) _settingsSnack(context, '已添加 $added 个播放器');
}

Future<void> _removeExternalPlayer(
  BuildContext context,
  AppState app,
  ExternalPlayerEntry entry,
) async {
  final entries = [
    for (final item in app.playerSettings.externalPlayers)
      if (item.path.toLowerCase() != entry.path.toLowerCase()) item,
  ];
  await app.setCustomExternalPlayers(entries);
  if (app.playerSettings.defaultCustomPlayerPathValue.toLowerCase() ==
      entry.path.toLowerCase()) {
    await app.setPlayerSettings(
      app.playerSettings.copyWith(defaultPlayer: kDefaultPlayerBuiltin),
    );
  }
  if (context.mounted) {
    _settingsSnack(
      context,
      '已移除 ${entry.name.trim().isEmpty ? externalPlayerDisplayName(entry.path) : entry.name}',
    );
  }
}

Future<void> _editSubtitleApis(BuildContext context) async {
  final app = AppScope.of(context);
  final text = await showDialog<String>(
    context: context,
    builder: (_) => _SubtitleApiDialog(initial: app.customSubtitleApis),
  );
  if (text == null) return;
  await app.setCustomSubtitleApis(text);
  if (context.mounted) {
    final n = _customLineCount(text);
    _settingsSnack(context, n == 0 ? '已清空自定义字幕 API' : '已保存 $n 个自定义字幕接口');
  }
}

class _SubtitleApiDialog extends StatefulWidget {
  const _SubtitleApiDialog({required this.initial});
  final String initial;

  @override
  State<_SubtitleApiDialog> createState() => _SubtitleApiDialogState();
}

class _SubtitleApiDialogState extends State<_SubtitleApiDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义字幕 API'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _ctrl,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  hintText:
                      '名称@https://example.com/sub?title={title}&ep={episode}',
                  helperText:
                      '每行一个。支持 {title} {year} {season} {episode} {rawName}；'
                      '接口可返回 JSON 候选列表，或直接返回 srt / ass / vtt / zip。',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'JSON 列表字段：url（必填）、title、language、format；'
                '也可以放在 data / results / subtitles / list 下。',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.72),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 播放缓冲：起播预缓冲 + 最大缓冲（fvp 的 `bufferRange`）。
Future<void> _editBufferSettings(BuildContext context, AppState app) async {
  var minSec = app.playerSettings.bufferMinSec;
  var maxSec = app.playerSettings.bufferMaxSec;
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('播放缓冲'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '起播预缓冲 ${minSec.toStringAsFixed(1)} 秒',
                  style: theme.textTheme.bodyMedium,
                ),
                Slider(
                  value: minSec,
                  min: 0.2,
                  max: 10,
                  divisions: 49,
                  label: '${minSec.toStringAsFixed(1)}s',
                  onChanged: (v) => setDialog(() => minSec = v),
                ),
                Text(
                  '最大缓冲 ${maxSec.toStringAsFixed(0)} 秒',
                  style: theme.textTheme.bodyMedium,
                ),
                Slider(
                  value: maxSec,
                  min: 2,
                  max: 60,
                  divisions: 58,
                  label: '${maxSec.toStringAsFixed(0)}s',
                  onChanged: (v) => setDialog(() => maxSec = v),
                ),
                const SizedBox(height: 6),
                Text(
                  '只对内置 fvp 内核生效：预缓冲越大起播越稳，最大缓冲越大越抗卡顿，'
                  '代价是更多内存与流量；保存后立即应用到当前播放。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    ),
  );
  if (saved != true) return;
  final fixedMax = maxSec < minSec + 0.5 ? minSec + 0.5 : maxSec;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(bufferMinSec: minSec, bufferMaxSec: fixedMax),
  );
  if (context.mounted) _settingsSnack(context, '播放缓冲已更新，当前播放已应用');
}

/// 缓存容量上限：给固定档位，避免手填出离谱的值。
Future<void> _pickStreamCacheSize(BuildContext context, AppState app) async {
  const options = [256, 512, 1024, 2048, 4096, 8192];
  final current = app.playerSettings.streamCacheMb;
  final picked = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('缓存容量上限'),
      children: [
        for (final mb in options)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(mb),
            child: Row(
              children: [
                Icon(
                  mb == current
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 18,
                  color: mb == current
                      ? Theme.of(ctx).colorScheme.primary
                      : Theme.of(ctx).disabledColor,
                ),
                const SizedBox(width: 10),
                Text(mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB'),
              ],
            ),
          ),
      ],
    ),
  );
  if (picked == null) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(streamCacheMb: picked),
  );
  if (context.mounted) {
    _settingsSnack(
      context,
      '缓存上限已设为 ${picked >= 1024 ? '${picked ~/ 1024} GB' : '$picked MB'}',
    );
  }
}

/// 清空边播缓存目录。
Future<void> _clearStreamCache(BuildContext context) async {
  final bytes = await LocalRelay.instance.streamCacheBytes();
  if (!context.mounted) return;
  final size = bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('清空播放缓存'),
      content: Text('当前占用约 $size。清空后已缓存的分片会重新从网络拉取。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await LocalRelay.instance.clearStreamCache();
  if (context.mounted) _settingsSnack(context, '播放缓存已清空');
}

Future<void> _pickMagnetDownloadDir(BuildContext context, AppState app) async {
  final current = app.playerSettings.magnetDownloadDir;
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('磁力下载位置'),
      content: Text(
        current.isEmpty
            ? '当前使用默认目录：应用数据目录/bt。\n\n'
                  '可指定其它文件夹；切换后新磁力任务会下载到新位置，'
                  '正在播放的任务会停止并需要重新打开。'
            : '当前目录：\n$current\n\n'
                  '切换后新磁力任务会下载到新位置，正在播放的任务会停止并需要重新打开。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('reset'),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop('pick'),
          child: const Text('选择文件夹'),
        ),
      ],
    ),
  );
  if (action == 'reset') {
    await app.setPlayerSettings(
      app.playerSettings.copyWith(magnetDownloadDir: ''),
    );
    if (context.mounted) _settingsSnack(context, '已恢复默认磁力下载位置');
    return;
  }
  if (action != 'pick') return;
  final path = await FileDialogService.pickDirectory(
    confirmButtonText: '选择磁力下载目录',
  );
  if (path == null || path.trim().isEmpty) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(magnetDownloadDir: path.trim()),
  );
  if (context.mounted) _settingsSnack(context, '磁力下载位置已更新');
}

Future<void> _editXunlei(BuildContext context, AppState app) async {
  final account = app.xunleiAccount;
  if (!account.loggedIn) {
    final ok = await showXunleiLoginDialog(context, app);
    if (ok && context.mounted) {
      _settingsSnack(context, '迅雷云盘登录成功');
    }
    return;
  }
  final logout = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('迅雷云盘'),
      content: Text(
        '已登录：${account.displayName}\n\n'
        '磁力会先提交到迅雷云盘离线下载，云端完成后直接播放；'
        '云端失败或关闭该开关时自动回退 aria2。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('退出登录'),
        ),
      ],
    ),
  );
  if (logout == true) {
    await app.logoutXunlei();
    if (context.mounted) _settingsSnack(context, '已退出迅雷云盘');
  }
}

Future<void> _editProxy(BuildContext context) async {
  if (kIsWeb) {
    _settingsSnack(context, '内置代理仅支持桌面版');
    return;
  }
  final app = AppScope.of(context);
  final config = await showDialog<ProxyConfig>(
    context: context,
    builder: (_) => _ProxyDialog(initial: app.proxy),
  );
  if (config == null) return;
  await app.setProxy(config);
  if (context.mounted) {
    _settingsSnack(context, '网络代理：${ProxyRuntime.instance.summary}');
  }
}

class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog({required this.initial});
  final ProxyConfig initial;

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  late bool _enabled = widget.initial.enabled;
  late bool _followSystem = widget.initial.followSystem;
  late String _type = widget.initial.type;
  late final TextEditingController _host = TextEditingController(
    text: widget.initial.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: widget.initial.port > 0 ? '${widget.initial.port}' : '7890',
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initial.username,
  );
  late final TextEditingController _pass = TextEditingController(
    text: widget.initial.password,
  );
  String _error = '';
  bool _diagnosing = false;
  List<String> _diagnosis = const [];

  Future<void> _diagnose() async {
    setState(() {
      _diagnosing = true;
      _diagnosis = const [];
    });
    final lines = await ProxyRuntime.instance.diagnose();
    if (!mounted) return;
    setState(() {
      _diagnosing = false;
      _diagnosis = lines;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _save() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (_enabled &&
        !_followSystem &&
        (host.isEmpty || port <= 0 || port > 65535)) {
      setState(() => _error = '请填写有效的代理地址和端口（1-65535）');
      return;
    }
    Navigator.of(context).pop(
      ProxyConfig(
        enabled: _enabled && !_followSystem,
        followSystem: _followSystem,
        type: _type,
        host: host,
        port: port,
        username: _user.text.trim(),
        password: _pass.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('网络代理'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile.adaptive(
                value: _followSystem,
                onChanged: (v) => setState(() {
                  _followSystem = v;
                  _error = '';
                }),
                title: const Text('跟随系统代理'),
                subtitle: const Text(
                  '用 Windows「局域网设置」或 HTTPS_PROXY 环境变量里的代理（Clash / v2rayN 开系统代理即生效）；'
                  '连 api.themoviedb.org 这类域名必须走它',
                ),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile.adaptive(
                value: _enabled,
                onChanged: (v) => setState(() {
                  _enabled = v;
                  if (v) _followSystem = false;
                  _error = '';
                }),
                title: const Text('使用手动代理'),
                subtitle: const Text('HTTP / SOCKS5 上联；本机 127.0.0.1 始终直连'),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'http', label: Text('HTTP')),
                  ButtonSegment(value: 'socks5', label: Text('SOCKS5')),
                ],
                selected: {_type},
                onSelectionChanged: _followSystem
                    ? null
                    : (value) => setState(() => _type = value.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                enabled: !_followSystem,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: '127.0.0.1 或代理域名',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _port,
                enabled: !_followSystem,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '端口',
                  hintText: '7890',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _user,
                enabled: !_followSystem,
                decoration: const InputDecoration(
                  labelText: '用户名（可选）',
                  hintText: '代理开启认证时填写',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pass,
                enabled: !_followSystem,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可选）'),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _diagnosing ? null : _diagnose,
                  icon: _diagnosing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check_rounded, size: 18),
                  label: Text(_diagnosing ? '正在自检…' : '代理自检'),
                ),
              ),
              for (final line in _diagnosis)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class _TokenDialog extends StatefulWidget {
  const _TokenDialog({required this.initial});
  final String initial;

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('assrt 字幕 token'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'assrt.net 免费注册后获取 token；留空只用 SubtitleCat',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _MergeExportDialog extends StatefulWidget {
  const _MergeExportDialog({required this.profiles});
  final List<ConfigProfile> profiles;

  @override
  State<_MergeExportDialog> createState() => _MergeExportDialogState();
}

class _MergeExportDialogState extends State<_MergeExportDialog> {
  late final Set<String> _selected = {
    for (final p in widget.profiles)
      if (p.rawJson.trim().isNotEmpty) p.id,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('合并导出配置'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '把勾选档案的源合并去重成一份 TVBox 订阅 JSON；不同档案的 jar / flags / 直播线路会一并带上。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final profile in widget.profiles)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(profile.id),
                        onChanged: profile.rawJson.trim().isEmpty
                            ? null
                            : (v) => setState(() {
                                if (v == true) {
                                  _selected.add(profile.id);
                                } else {
                                  _selected.remove(profile.id);
                                }
                              }),
                        title: Text(profile.name),
                        subtitle: Text(
                          '${profile.siteCount} 站点 · ${profile.liveCount} 直播',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: const Text('导出'),
        ),
      ],
    );
  }
}

/// WebDAV 服务器列表：添加 / 编辑 / 删除 / 浏览。
class _DavServerList extends StatefulWidget {
  const _DavServerList({required this.app});
  final AppState app;

  @override
  State<_DavServerList> createState() => _DavServerListState();
}

class _DavServerListState extends State<_DavServerList> {
  Future<void> _edit([DavServer? server]) async {
    final result = await showDialog<DavServer>(
      context: context,
      builder: (ctx) => _DavEditDialog(initial: server),
    );
    if (result == null || !mounted) return;
    try {
      await widget.app.saveDavServer(result);
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(DavServer server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 WebDAV 服务器'),
        content: Text('确定删除「${server.name}」？只影响本机保存的地址与凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.app.removeDavServer(server.id);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _browse(DavServer server) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DavBrowsePage(server: server)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final servers = widget.app.davService.servers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (servers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '只读直连：PROPFIND 列目录，播放经本地 /play 中继注入 Basic 认证。',
              style: theme.textTheme.bodySmall,
            ),
          )
        else
          for (final server in servers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_shared_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          server.username.isEmpty
                              ? server.url
                              : '${server.username}@${server.url}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _RowIconButton(
                    icon: Icons.folder_open_rounded,
                    tooltip: '浏览',
                    onPressed: () => _browse(server),
                  ),
                  _RowIconButton(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    onPressed: () => _edit(server),
                  ),
                  _RowIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: '删除',
                    onPressed: () => _delete(server),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('添加 WebDAV 服务器'),
        ),
      ],
    );
  }
}

class _DavEditDialog extends StatefulWidget {
  const _DavEditDialog({this.initial});
  final DavServer? initial;

  @override
  State<_DavEditDialog> createState() => _DavEditDialogState();
}

class _DavEditDialogState extends State<_DavEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.initial?.url ?? '',
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initial?.username ?? '',
  );
  late final TextEditingController _pass = TextEditingController(
    text: widget.initial?.password ?? '',
  );
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    Navigator.of(context).pop(
      DavServer(
        id: widget.initial?.id ?? '',
        name: _name.text.trim(),
        url: url,
        username: _user.text.trim(),
        password: _pass.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.initial == null ? '添加 WebDAV 服务器' : '编辑 WebDAV 服务器'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '地址要指到 WebDAV 根（如 OpenList/AList 的 https://host:5244/dav）。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称（可空，默认用主机名）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _url,
                autofocus: widget.initial == null,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'https://host:5244/dav',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: '用户名（无认证可空）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: '密码',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),
              Text(
                '凭据与网盘 Cookie 一样只保存在本机（明文），请勿在多设备共享的电脑上使用。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
