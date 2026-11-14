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

# TVBox / CatVod 蜘蛛依赖的 Java 宿主库：APK 自身代码完全不引用它们，
# 只由加固壳解出的外部 dex 在运行时链接。不 keep 会被 R8 整体裁掉，
# 表现为 homeContent 抛 NoClassDefFoundError: Failed resolution of: Lokhttp3/Request$Builder;
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class com.google.gson.** { *; }
-keep class org.jsoup.** { *; }
-keep class com.alibaba.fastjson.** { *; }
-keep class com.kniephos.kniephos.MainActivity { *; }

# Gson / fastjson / OkHttp 的反射需要泛型签名与注解信息；R8 默认可能丢掉 Signature，
# 会导致外部蜘蛛 new TypeToken<List<X>>(){} 解析不到类型。
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# 这些库里有对 Android 平台上不存在的可选依赖的引用（conscrypt、javax.annotation、
# animal-sniffer 注解、JDK 内部类等），R8 会报 missing class warning。
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn com.google.gson.**
-dontwarn org.jsoup.**
-dontwarn com.alibaba.fastjson.**
-dontwarn org.conscrypt.**
-dontwarn javax.annotation.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
-dontwarn java.lang.invoke.**
-dontwarn sun.misc.**
