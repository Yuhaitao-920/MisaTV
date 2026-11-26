import 'package:flutter/material.dart';

/// 点播 / 直播播放器共用的音量面板。
///
/// [onChanged] 用于拖动时实时生效；[onCommit] 在松手或点预设时调用，
/// 由调用方负责持久化。静音按钮会先关闭面板再执行 [onToggleMute]。
Future<void> showVolumeSheet({
  required BuildContext context,
  required double volume,
  required ValueChanged<double> onChanged,
  required ValueChanged<double> onCommit,
  required VoidCallback onToggleMute,
  String? hint,
}) async {
  var value = volume.clamp(0.0, 1.0).toDouble();
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('音量', style: theme.textTheme.titleLarge),
                    const SizedBox(width: 10),
                    Text(
                      '${(value * 100).round()}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onToggleMute();
                      },
                      child: Text(value <= 0.001 ? '取消静音' : '静音'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Icon(
                      value <= 0.001
                          ? Icons.volume_off_rounded
                          : Icons.volume_mute_rounded,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                    Expanded(
                      child: Slider(
                        max: 1,
                        value: value.clamp(0.0, 1.0),
                        onChanged: (v) {
                          value = v;
                          setSheet(() {});
                          onChanged(v);
                        },
                        onChangeEnd: onCommit,
                      ),
                    ),
                    Icon(
                      Icons.volume_up_rounded,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ],
                ),
                Row(
                  children: [
                    for (final pct in const [0.3, 0.5, 0.7, 1.0]) ...[
                      ChoiceChip(
                        label: Text('${(pct * 100).round()}%'),
                        selected: (value - pct).abs() < 0.001,
                        onSelected: (_) {
                          value = pct;
                          setSheet(() {});
                          onCommit(pct);
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
                if (hint != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.76,
                      ),
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}
