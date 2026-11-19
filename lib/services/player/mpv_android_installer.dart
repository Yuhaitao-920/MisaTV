// 在 Android 端下载 mpv-android 官方 release APK 并拉起系统安装器。
// 平台实现分离：Android/桌面走 _io（真实下载 + MethodChannel 安装），
// Web 走 _web（无操作 stub），避免出现 dart:io / MethodChannel 的编译错误。
export 'mpv_android_installer_io.dart'
    if (dart.library.js_interop) 'mpv_android_installer_web.dart';
