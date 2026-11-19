package com.kniephos.kniephos

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// mpv-android 安装通道：下载目录、ABI、安装状态，以及拉起系统安装器。
///
/// Android 8+ 起第三方 APK 不能静默安装，只能把 APK 通过 FileProvider 分享成
/// content:// URI，再以 ACTION_VIEW + application/vnd.android.package-archive
/// 交给系统安装器，由用户确认。这里只负责把 Intent 发出去。
class MpvInstallPlugin(private val context: Context) {
    companion object {
        private const val CHANNEL = "com.kniephos.kniephos/mpv_install"
        private const val MPV_PACKAGE = "is.xyz.mpv"

        fun register(engine: FlutterEngine, context: Context) {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(MpvInstallPlugin(context.applicationContext)::onMethodCall)
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "apkDir" -> {
                    val dir = File(context.cacheDir, "mpv-android")
                    if (!dir.exists()) dir.mkdirs()
                    result.success(dir.absolutePath)
                }
                "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "isInstalled" -> result.success(isInstalled())
                "installedVersion" -> result.success(installedVersion())
                "install" -> {
                    val path = call.arguments as? String
                    if (path.isNullOrEmpty()) {
                        result.error("INVALID_ARG", "APK path is empty", null)
                        return
                    }
                    result.success(install(path))
                }
                "openWithMpv" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.success(false)
                        return
                    }
                    val title = call.argument<String>("title")
                    val positionMs = call.argument<Int>("positionMs") ?: 0
                    result.success(openWithMpv(url, title, positionMs))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("MPV_INSTALL_ERROR", e.message ?: "unknown error", null)
        }
    }

    private fun isInstalled(): Boolean = try {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(MPV_PACKAGE, 0) != null
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun installedVersion(): String? = try {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(MPV_PACKAGE, 0).versionName
    } catch (e: Exception) {
        null
    }

    private fun install(path: String): Boolean {
        val apk = File(path)
        if (!apk.exists()) return false
        val uri: Uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        return true
    }

    /// 用标准 ACTION_VIEW Intent 把播放地址交给 mpv-android。
    ///
    /// 必须显式 setType("video/*")：本机 /chunk 地址没有扩展名，mpv 的
    /// intent-filter 靠 MIME 匹配；同时 setPackage 精确定位到 is.xyz.mpv，
    /// 避免 url_launcher 拼 intent:// URI 时 fragment 不被解析的问题。
    private fun openWithMpv(url: String, title: String?, positionMs: Int): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (e: Exception) {
            return false
        }
        val scheme = uri.scheme
        if (scheme != "http" && scheme != "https" && scheme != "ftp") return false
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "video/*")
            setPackage(MPV_PACKAGE)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (!title.isNullOrEmpty()) putExtra("title", title)
            if (positionMs > 0) putExtra("position", positionMs)
        }
        return try {
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
