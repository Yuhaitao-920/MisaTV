#!/usr/bin/env python3
"""TV 精简版：把字体裁到只剩 MiSans-Regular。

为什么需要这个脚本（而不是在 workflow 里内联 sed / python）：
  1. **只删字体文件不改 pubspec 会直接构建失败**：
       Error: unable to locate asset entry in pubspec.yaml:
              "assets/fonts/MiSans-Medium.ttf"
     Flutter 会校验 pubspec 里声明的字体文件是否存在。
  2. **只改 pubspec 不删文件也省不到体积**：`assets/fonts/` 整个目录在
     pubspec 的 assets: 段里也被声明了，文件仍会被打进 APK。
     所以两件事必须同时做。
  3. workflow 里内联 heredoc 与 YAML 缩进容易互相干扰（已经踩过一次），
     独立脚本文件更清晰、也能在本地直接跑。

用法（在仓库根目录）：
    python3 tool/trim_fonts_for_tv.py
"""

from __future__ import annotations

import os
import re
import sys

# TV 版**完全不打包** MiSans：改用系统字体（AppTheme.fontFamily 在 TV 版返回
# null，Flutter 走平台默认字体，中文由系统渲染，显示正常）。
# 这样能省 5.3 MB —— 比只留一个 Regular 更彻底。
KEEP_WEIGHT = None
KEEP_FILE = None
FONT_DIR = os.path.join("assets", "fonts")
PUBSPEC = "pubspec.yaml"


def trim_pubspec() -> tuple[int, list[str]]:
    """从 pubspec 的 fonts 段移除除 KEEP_WEIGHT 之外的 MiSans 条目。

    返回 (保留条数, 被移除的条目描述)。找不到任何可裁剪条目时抛错 ——
    那说明 pubspec 结构变了，脚本需要跟着改，不能静默跳过（否则构建会用
    一个缺文件的 pubspec 继续跑，最终报一个更难懂的错误）。
    """
    with open(PUBSPEC, encoding="utf-8") as f:
        src = f.read()

    pattern = re.compile(
        r"(?P<indent>[ ]*)- asset: assets/fonts/MiSans-[^\n]+\n"
        r"[ ]*weight: (?P<weight>[0-9]+)\n"
    )

    kept: list[str] = []
    removed: list[str] = []

    def repl(m: re.Match[str]) -> str:
        block = m.group(0)
        if KEEP_WEIGHT is not None and m.group("weight").strip() == KEEP_WEIGHT:
            kept.append(block)
            return block
        removed.append(block.strip().splitlines()[0])
        return ""

    out = pattern.sub(repl, src)

    if not removed:
        print(
            "错误：pubspec.yaml 里没有找到可裁剪的 MiSans 字重条目。\n"
            "      可能是字体声明结构变了，请更新 tool/trim_fonts_for_tv.py。",
            file=sys.stderr,
        )
        raise SystemExit(1)

    # TV 版一个字重都不留时，把空的 fonts: 段整体去掉（否则 Flutter 会报
    # 「family MiSans 没有声明任何字体」）。
    if KEEP_WEIGHT is None:
        out = re.sub(
            r"[ ]*fonts:\n(?:[ ]*#.*\n)*[ ]*- family: MiSans\n[ ]*fonts:\n",
            "",
            out,
        )

    with open(PUBSPEC, "w", encoding="utf-8", newline="") as f:
        f.write(out)

    return len(kept), removed


def trim_files() -> list[str]:
    """删掉除 MiSans-Regular 之外的 MiSans 字体文件。"""
    if not os.path.isdir(FONT_DIR):
        print(f"错误：找不到 {FONT_DIR}", file=sys.stderr)
        raise SystemExit(1)

    removed: list[str] = []
    for name in sorted(os.listdir(FONT_DIR)):
        if not name.startswith("MiSans-"):
            continue
        if KEEP_FILE is not None and name == KEEP_FILE:
            continue
        path = os.path.join(FONT_DIR, name)
        if not os.path.isfile(path):
            continue
        os.remove(path)
        removed.append(name)
    return removed


def main() -> int:
    kept, removed_entries = trim_pubspec()
    removed_files = trim_files()

    print(f"pubspec：保留 {kept} 个字重，移除 {len(removed_entries)} 条声明")
    for e in removed_entries:
        print(f"  - {e}")

    print(f"文件：删除 {len(removed_files)} 个")
    for f in removed_files:
        print(f"  - {f}")

    # 一致性检查：pubspec 保留的条目必须有对应文件，否则下游构建会失败
    if KEEP_FILE is not None:
        keep_path = os.path.join(FONT_DIR, KEEP_FILE)
        if not os.path.isfile(keep_path):
            print(f"错误：保留的字体文件不存在：{keep_path}", file=sys.stderr)
            return 1

    remaining = [n for n in os.listdir(FONT_DIR) if n.startswith("MiSans-")]
    print(f"assets/fonts 剩余 MiSans 文件：{remaining}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
