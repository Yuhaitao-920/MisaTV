import 'package:flutter/material.dart';

/// 播放器按键提示：点播 / 直播共用，按 H 或 F1 打开。
Future<void> showPlayerKeyHelp(BuildContext context, {required bool live}) {
  final entries = live
      ? const <(String, String)>[
          ('↑ / ↓', '音量'),
          ('M', '静音'),
          ('数字键', '输入频道号换台'),
          ('Enter', '全屏切换'),
          ('Esc', '退出全屏 / 返回'),
          ('H / F1', '按键提示'),
        ]
      : const <(String, String)>[
          ('空格', '播放 / 暂停'),
          ('← / →', '快退 / 快进 10 秒'),
          ('↑ / ↓', '音量'),
          ('M', '静音'),
          ('F / Enter', '全屏切换'),
          ('Esc', '退出全屏 / 返回'),
          ('H / F1', '按键提示'),
        ];
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text(live ? '直播播放器按键' : '播放器按键'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          entry.$1,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      Expanded(child: Text(entry.$2)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}
