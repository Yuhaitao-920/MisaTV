package com.kniephos.kniephos

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.system.Os
import com.fongmi.hook.Hook
import com.tvbus.engine.Listener
import com.tvbus.engine.TVCore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Android 端 TVBus（Go P2P 直播）宿主。
 *
 * 与 FongMi/TV 的做法一致：主 APK 只带很小的 [TVCore]/[Listener] Java 包装，
 * 真正的 Go 引擎由直播源 `core.so` 指定，Dart 侧下载到应用私有目录后，
 * 这里用 `System.load` 加载并启动。`.so` 是每个源自己的，不做通用 Go APK。
 *
 * MethodChannel `com.kniephos.kniephos/tvbus`：
 *   resolve  {soPath,url,auth,name,pass,domain,broker,options,playPort,timeoutMs}
 *   stop
 *   shutdown
 */
class TvBusPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.kniephos.kniephos/tvbus"

        @Volatile
        private var application: Application? = null

        /**
         * 与 SpiderHostPlugin 同理：FlutterPluginBinding.applicationContext 在部分
         * 机型上是 ContextImpl，Go 引擎/加固壳需要真实 Application。
         */
        fun bindApplication(app: Application) {
            application = app
        }
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val workExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var engine: TVCore? = null
    private var engineSo: String? = null
    private var engineStarted = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = application ?: binding.applicationContext
        appContext = context
        TVCore.setContext(context)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
        workExecutor.execute { quitEngine() }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        when (call.method) {
            "resolve" -> {
                if (args == null) {
                    result.error("tvbus", "TVBus 参数错误", null)
                    return
                }
                workExecutor.execute {
                    try {
                        val output = resolve(args)
                        mainHandler.post { result.success(output) }
                    } catch (e: Throwable) {
                        val message = e.message ?: e.toString()
                        mainHandler.post { result.error("tvbus", message, null) }
                    }
                }
            }

            "stop" -> workExecutor.execute {
                try {
                    engine?.stop()
                } catch (_: Throwable) {
                }
                mainHandler.post { result.success(null) }
            }

            "shutdown" -> workExecutor.execute {
                quitEngine()
                mainHandler.post { result.success(null) }
            }

            else -> result.notImplemented()
        }
    }

    private fun resolve(args: Map<*, *>): String {
        val soPath = args.str("soPath")
        val url = args.str("url")
        if (soPath.isEmpty()) throw IllegalArgumentException("TVBus 引擎路径为空")
        if (url.isEmpty()) throw IllegalArgumentException("TVBus 频道地址为空")
        val file = File(soPath)
        if (!file.isFile) throw IllegalArgumentException("TVBus 引擎文件不存在：$soPath")
        makeReadOnly(file)

        val pkg = args.str("pkg")
        val sign = args.str("sign")
        val hook = if (pkg.isNotEmpty() && sign.isNotEmpty()) Hook(sign, pkg) else null
        val baseContext =
            application ?: appContext ?: throw IllegalStateException("TVBus 宿主 Context 未初始化")
        val engineContext = if (hook != null) HookContext(baseContext, hook) else baseContext
        val created = engine == null || engineSo != soPath
        if (created) {
            quitEngine()
            TVCore.setContext(engineContext)
            try {
                engine = TVCore(soPath)
                engineSo = soPath
                engineStarted = false
            } catch (e: Throwable) {
                TVCore.setContext(baseContext)
                throw e
            }
        }
        val core = engine ?: throw IllegalStateException("TVBus 引擎创建失败")
        val bridge = Bridge()
        val playPort = (args["playPort"] as? Number)?.toInt() ?: 8902
        core.listener(bridge).serv(0).play(playPort).mode(1)
        args.str("auth").takeIf { it.isNotEmpty() }?.let { core.auth(it) }
        args.str("name").takeIf { it.isNotEmpty() }?.let { core.name(it) }
        args.str("pass").takeIf { it.isNotEmpty() }?.let { core.pass(it) }
        args.str("domain").takeIf { it.isNotEmpty() }?.let { core.domain(it) }
        args.str("broker").takeIf { it.isNotEmpty() }?.let { core.broker(it) }
        applyOptions(core, args.str("options"))

        if (!engineStarted) {
            TVCore.setContext(engineContext)
            try {
                core.init()
                engineStarted = true
                // 大部分引擎会回 onInited；个别版本不回，最多等 3 秒后继续 start。
                bridge.awaitInited(3000)
            } finally {
                // HookContext 只交给 TVCore 的 init；之后恢复真实 Application Context。
                TVCore.setContext(baseContext)
            }
        }

        core.start(url)
        val timeout = (args["timeoutMs"] as? Number)?.toLong() ?: 30000L
        if (!bridge.latch.await(timeout, TimeUnit.MILLISECONDS)) {
            try {
                core.stop()
            } catch (_: Throwable) {
            }
            throw IllegalStateException("TVBus 引擎启动超时")
        }
        bridge.error?.let { throw IllegalStateException("TVBus 引擎错误：$it") }
        val hls = bridge.hls?.trim().orEmpty()
        if (hls.isEmpty()) throw IllegalStateException("TVBus 引擎没有返回播放地址")
        return JSONObject().put("ok", true).put("hls", hls).toString()
    }

    private fun applyOptions(core: TVCore, raw: String) {
        if (raw.isEmpty()) return
        try {
            val array = JSONArray(raw)
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val key = item.optString("key", "").trim()
                if (key.isEmpty()) continue
                val values = item.optJSONArray("values") ?: JSONArray()
                val list = ArrayList<String>()
                for (j in 0 until values.length()) list.add(values.optString(j, ""))
                core.option(key, list)
            }
        } catch (_: Throwable) {
            // 非法的 option 不阻断播放
        }
    }

    private fun makeReadOnly(file: File) {
        try {
            // Android 14 的动态代码加载要求文件只读；Go .so 加载前先 chmod 0444。
            Os.chmod(file.absolutePath, 0b100100100)
        } catch (_: Throwable) {
            try {
                file.setReadOnly()
            } catch (_: Throwable) {
            }
        }
    }

    private fun quitEngine() {
        try {
            engine?.quit()
        } catch (_: Throwable) {
        }
        engine = null
        engineSo = null
        engineStarted = false
    }

    private fun Map<*, *>.str(key: String): String =
        (this[key] as? String)?.trim() ?: ""

    /**
     * 只传给 TVCore 的 Context：getPackageManager / getPackageName 返回订阅
     * 期望的包名与签名，不影响 Flutter 自己的 Application。
     */
    private class HookContext(
        base: Context,
        private val hook: Hook,
    ) : ContextWrapper(base) {
        override fun getPackageManager(): PackageManager = hook
        override fun getPackageName(): String = hook.packageName
        // 部分 Go 引擎会先取 applicationContext；返回自己，避免绕过包名/签名影子。
        override fun getApplicationContext(): Context = this
    }

    private class Bridge : Listener {
        val latch = CountDownLatch(1)
        private val inited = CountDownLatch(1)

        @Volatile
        var hls: String? = null

        @Volatile
        var error: String? = null

        fun awaitInited(timeoutMs: Long) {
            try {
                inited.await(timeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        override fun onInited(result: String) {
            inited.countDown()
        }

        override fun onStart(result: String) {}

        override fun onPrepared(result: String) {
            try {
                val json = JSONObject(result)
                val value = json.optString("hls", "")
                if (value.isNotEmpty()) {
                    hls = value
                    latch.countDown()
                }
            } catch (_: Throwable) {
            }
        }

        override fun onInfo(result: String) {}

        override fun onStop(result: String) {
            try {
                val json = JSONObject(result)
                val errno = json.optString("errno", "")
                if (errno.startsWith("-")) {
                    error = errno
                    latch.countDown()
                }
            } catch (_: Throwable) {
                latch.countDown()
            }
        }

        override fun onQuit(result: String) {}
    }
}
