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
import java.util.Locale

/// Android 外部播放器通道：mpv-android 下载/安装、枚举可播视频的 App，
/// 以及用标准 ACTION_VIEW Intent 把片源交给系统里任意播放器。
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
                "listVideoPlayers" -> result.success(listVideoPlayers())
                "openWithMpv" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.success(false)
                        return
                    }
                    val title = call.argument<String>("title")
                    val positionMs = call.argument<Int>("positionMs") ?: 0
                    result.success(
                        openWithExternalPlayer(url, title, positionMs, MPV_PACKAGE),
                    )
                }
                "openWithExternalPlayer" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.success(false)
                        return
                    }
                    val title = call.argument<String>("title")
                    val positionMs = call.argument<Int>("positionMs") ?: 0
                    val packageName = call.argument<String>("package")?.trim()
                    result.success(
                        openWithExternalPlayer(
                            url,
                            title,
                            positionMs,
                            packageName?.ifEmpty { null },
                        ),
                    )
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

    /// 列出系统里所有能播放视频的 App（按名称排序，同包名只留一个）。
    ///
    /// Android 11+ 有包可见性限制，AndroidManifest 的 <queries> 里声明了
    /// ACTION_VIEW + video/*，这里才能拿到完整列表。
    private fun listVideoPlayers(): List<Map<String, String>> {
        val pm = context.packageManager
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, String>>()
        // 不同播放器声明的 MIME 不完全一致：通配、具体视频类型、HLS 都查一遍。
        val mimes = listOf("video/*", "video/mp4", "application/vnd.apple.mpegurl")
        for (mime in mimes) {
            val probe = Intent(Intent.ACTION_VIEW).apply { type = mime }
            try {
                @Suppress("DEPRECATION")
                val resolved = pm.queryIntentActivities(probe, 0)
                for (info in resolved) {
                    val pkg = info.activityInfo?.packageName ?: continue
                    if (!seen.add(pkg)) continue
                    val label = try {
                        info.loadLabel(pm).toString()
                    } catch (e: Exception) {
                        pkg
                    }
                    out.add(
                        mapOf("package" to pkg, "label" to label.ifEmpty { pkg }),
                    )
                }
            } catch (e: Exception) {
                // 单个 MIME 查询失败不影响其它类型
            }
        }
        out.sortWith(compareBy<Map<String, String>> { it["label"] ?: "" })
        return out
    }

    /// 用标准 ACTION_VIEW Intent 把播放地址交给任意外部播放器。
    ///
    /// [packageName] 为空时弹出系统选择器（用户可选手机里任何一个播放器，
    /// 并可点「始终」记住）；非空时精确定位到用户指定的播放器。
    /// 必须显式设置 type：本机 /chunk 地址没有扩展名，播放器靠 MIME 匹配。
    private fun openWithExternalPlayer(
        url: String,
        title: String?,
        positionMs: Int,
        packageName: String?,
    ): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (e: Exception) {
            return false
        }
        val scheme = uri.scheme
        if (scheme != "http" && scheme != "https" && scheme != "ftp") return false
        val primaryMime = mimeFor(url)
        // 先用按扩展名推断的精确 MIME，失败再用 video/* 通配兜底：
        // 有些播放器只注册了 video/*，有些只认具体 MIME。
        if (startPlayer(uri, primaryMime, title, positionMs, packageName)) return true
        if (primaryMime != "video/*") {
            return startPlayer(uri, "video/*", title, positionMs, packageName)
        }
        return false
    }

    private fun startPlayer(
        uri: Uri,
        mime: String,
        title: String?,
        positionMs: Int,
        packageName: String?,
    ): Boolean {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (!title.isNullOrEmpty()) putExtra("title", title)
            if (positionMs > 0) putExtra("position", positionMs)
            if (!packageName.isNullOrEmpty()) setPackage(packageName)
        }
        // chooser 本身总能启动，先确认确实有 App 能处理，避免弹出空白选择器。
        @Suppress("DEPRECATION")
        if (intent.resolveActivity(context.packageManager) == null) return false
        // 没有指定包名时用 chooser，避免只有「设置为默认」的 App 出现在列表里，
        // 也让用户每次都能看到设备上全部支持视频的播放器。
        val target = if (packageName.isNullOrEmpty()) {
            Intent.createChooser(intent, "选择播放器").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            intent
        }
        return try {
            context.startActivity(target)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun mimeFor(url: String): String {
        val path = url.substringBefore('?').substringBefore('#').lowercase(Locale.ROOT)
        return when {
            path.endsWith(".mp4") -> "video/mp4"
            path.endsWith(".mkv") -> "video/x-matroska"
            path.endsWith(".webm") -> "video/webm"
            path.endsWith(".avi") -> "video/x-msvideo"
            path.endsWith(".flv") -> "video/x-flv"
            path.endsWith(".ts") -> "video/mp2t"
            path.endsWith(".m3u8") -> "application/vnd.apple.mpegurl"
            else -> "video/*"
        }
    }
}
