part of '../settings_page.dart';

Future<void> _openHeroFonts(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _HeroFontsDialog(),
  );
}

class _HeroFontsDialog extends StatefulWidget {
  const _HeroFontsDialog();

  @override
  State<_HeroFontsDialog> createState() => _HeroFontsDialogState();
}

class _HeroFontsDialogState extends State<_HeroFontsDialog> {
  bool _bulk = false;

  Future<void> _installMissing() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final missing = HeroFontService.instance.missingCount;
        final size = HeroFontService.instance.missingBytes / 1048576;
        return AlertDialog(
          title: const Text('下载全部字体包'),
          content: Text(
            '将依次下载 $missing 个字体包，共约 ${size.toStringAsFixed(1)} MB。\n\n'
            '全部为 SIL Open Font License 字体，可免费商用。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('开始下载'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    setState(() => _bulk = true);
    var failed = 0;
    try {
      for (final pack in heroFontPacks) {
        if (!mounted) return;
        if (HeroFontService.instance.installed(pack.role)) continue;
        try {
          await HeroFontService.instance.install(pack);
        } catch (e) {
          failed++;
          AppLog.w('font', '批量下载 ${pack.title} 失败：$e');
        }
      }
      if (mounted) {
        _settingsSnack(
          context,
          failed == 0 ? '字体包下载完成' : '字体包下载完成，$failed 个失败',
        );
      }
    } finally {
      if (mounted) setState(() => _bulk = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
      height: 1.5,
    );
    final groups = <String, List<HeroFontPack>>{};
    for (final pack in heroFontPacks) {
      groups.putIfAbsent(pack.group, () => []).add(pack);
    }
    return AlertDialog(
      title: const Text('沉浸标题字体'),
      content: SizedBox(
        width: 680,
        height: (MediaQuery.sizeOf(context).height - 230).clamp(300.0, 580.0),
        child: AnimatedBuilder(
          animation: HeroFontService.instance,
          builder: (context, _) {
            if (!HeroFontService.instance.supported) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('当前平台不支持运行时字体扩展。', style: hint),
              );
            }
            final missing = HeroFontService.instance.missingCount;
            final missingSize = HeroFontService.instance.missingBytes / 1048576;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Hero 标题会按影片的地区与类型自动选择字体和排版；'
                        '字体不随安装包内置，下载或导入后才生效。',
                        style: hint,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonal(
                      onPressed: _bulk || missing == 0 ? null : _installMissing,
                      child: Text(
                        _bulk
                            ? '正在下载…'
                            : missing == 0
                            ? '已全部安装'
                            : '下载全部缺失（${missingSize.toStringAsFixed(1)} MB）',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      for (final entry in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
                          child: Text(
                            entry.key,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        for (final pack in entry.value)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _HeroFontTile(pack: pack),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '全部为 SIL Open Font License 1.1 字体，可免费商用。'
                  '删除字体后需重启应用才会彻底释放已加载的字形。',
                  style: hint,
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _HeroFontTile extends StatelessWidget {
  const _HeroFontTile({required this.pack});

  final HeroFontPack pack;

  Future<void> _download(BuildContext context) async {
    try {
      await HeroFontService.instance.install(pack);
      if (context.mounted) _settingsSnack(context, '${pack.title} 已安装');
    } catch (e) {
      if (context.mounted) _settingsSnack(context, '下载失败：$e');
    }
  }

  Future<void> _import(BuildContext context) async {
    if (!HeroFontService.instance.supported) return;
    final path = await FileDialogService.pickFile(
      types: const [FileDialogService.fontType],
    );
    if (path == null) return;
    try {
      await HeroFontService.instance.importLocal(pack, path);
      if (context.mounted) {
        _settingsSnack(context, '已导入到「${pack.title}」槽位');
      }
    } catch (e) {
      if (context.mounted) _settingsSnack(context, '导入失败：$e');
    }
  }

  Future<void> _remove(BuildContext context) async {
    await HeroFontService.instance.remove(pack.role);
    if (context.mounted) {
      _settingsSnack(context, '${pack.title} 已删除，重启后彻底释放');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = HeroFontService.instance;
    final installed = service.installed(pack.role);
    final busy = service.busy(pack.role);
    final custom = service.customNameOf(pack.role);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
      height: 1.45,
    );
    final progress = service.progress(pack.role);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            pack.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (installed) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.16,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '已安装',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(pack.tagline, style: hint),
                    if (custom != null) Text('当前使用：$custom', style: hint),
                  ],
                ),
              ),
              if (!busy) ...[
                if (installed)
                  TextButton(
                    onPressed: () => _remove(context),
                    child: const Text('删除'),
                  )
                else
                  FilledButton.tonal(
                    onPressed: () => _download(context),
                    child: Text('下载 ${pack.sizeLabel}'),
                  ),
                TextButton(
                  onPressed: () => _import(context),
                  child: const Text('导入本地'),
                ),
              ],
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress <= 0 ? null : progress),
            const SizedBox(height: 4),
            Text(
              progress <= 0
                  ? '正在连接下载源…'
                  : '下载中 ${(progress * 100).toStringAsFixed(0)}%',
              style: hint,
            ),
          ],
          if (pack.role == HeroFontRole.jaCrime) ...[
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '想要《冰冷热带鱼》那种裂痕明朝体，可从 BOOTH 免费下载 '
                  'ダストデビルM（OFL）后点「导入本地」。',
                  style: hint,
                ),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://booth.pm/ja/items/8723012'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('打开 BOOTH'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
