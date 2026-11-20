package com.kniephos.kniephos

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/// 安卓外部播放器通道：枚举能播放视频的 App，并用标准 ACTION_VIEW Intent
/// 把片源交给系统里任意播放器（含系统选择器）。不含下载/安装逻辑。
class ExternalPlayerPlugin(private val context: Context) {
    companion object {
        private const val CHANNEL = "com.kniephos.kniephos/external_player"

        fun register(engine: FlutterEngine, context: Context) {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(ExternalPlayerPlugin(context.applicationContext)::onMethodCall)
        }
    }

    private fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listVideoPlayers" -> result.success(listVideoPlayers())
                "openWithExternalPlayer" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.success(false)
                        return
                    }
                    val title = call.argument<String>("title")
                    val positionMs = call.argument<Int>("positionMs") ?: 0
                    val packageName = call.argument<String>("package")?.trim()
                    result.success(open(url, title, positionMs, packageName?.ifEmpty { null }))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("EXT_PLAYER_ERROR", e.message ?: "unknown error", null)
        }
    }

    /// 枚举手机上所有能处理视频的播放器（多种 MIME 都查一遍，去重后按名排序）。
    private fun listVideoPlayers(): List<Map<String, String>> {
        val pm = context.packageManager
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, String>>()
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
                    out.add(mapOf("package" to pkg, "label" to label.ifEmpty { pkg }))
                }
            } catch (e: Exception) {
                // 单个 MIME 查询失败不影响其它类型
            }
        }
        out.sortWith(compareBy<Map<String, String>> { it["label"] ?: "" })
        return out
    }

    /// 用 ACTION_VIEW 打开播放地址。[packageName] 为空时用 chooser 让用户每次选。
    private fun open(
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
        @Suppress("DEPRECATION")
        if (intent.resolveActivity(context.packageManager) == null) return false
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
