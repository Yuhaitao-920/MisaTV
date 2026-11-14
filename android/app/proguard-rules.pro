# Flutter 3.47 的 release 构建默认启用 R8（minify + obfuscate）。
# 下面这组类是「宿主 API」，只被外部 jar / 加固壳 dex 通过类名反射引用，
# R8 看不到任何静态引用，会把它们裁掉或重命名为 a.b.c，导致壳加载时报
# ClassNotFoundException / NoClassDefFoundError。必须原样保留。
-keep class com.github.catvod.crawler.** { *; }
-keepnames class com.github.catvod.crawler.**
-keep class com.kniephos.kniephos.SpiderHostPlugin { *; }
-keepnames class com.kniephos.kniephos.SpiderHostPlugin

# 壳入口 / 宿主类的名字是以字符串常量写在插件里的（Class.forName），
# R8 不会去改写外部 jar 里的类名，这里不做 -adaptclassstrings，保持原样即可。
