package com.kniephos.kniephos

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Android 版「jar / DEX 蜘蛛」运行器 —— 直接落地 MisaTV 桌面端 dex2jar + JRE + unidbg 的
 * 安卓等价实现。
 *
 * 桌面端：下载 JRE17 → dex2jar 把 .dex 转成 .class jar → 用外部 JVM 进程(spider-host.jar)
 * 通过 stdio JSON 信封调用蜘蛛 → 加固壳首次用 unidbg 模拟 ARM .so 解包。
 *
 * 安卓端（ART 直接跑 DEX，无 java 可执行文件、无外部 JVM）：
 *   · 普通 jar / dex 蜘蛛  → 用 [dalvik.system.DexClassLoader] 直接加载并反射调用，
 *                          等价于「dex2jar 把 dex 变可运行」（这是安卓原生的做法）。
 *   · 加固壳（含 ARM .so）  → 走「原生执行」而非 unidbg 模拟：安卓设备本身就是 ARM，
 *                          直接用 [System.load] 加载壳里的 .so 就能跑通解密逻辑，
 *                          再用 DexClassLoader 加载解密出的真实实现（shell-shim 快路径）。
 *
 * 本插件通过 MethodChannel(com.kniephos.kniephos/spider) 与 Dart 侧通信：
 *   loadSpider(paths, className, ext, cacheDir) -> {ok, proxyPort, error}
 *   invoke(method, args[], className)             -> {ok, data, error}
 *   unload()                                     -> {ok}
 *   loadNative(path)                             -> {ok, error}   （unidbg 替代：原生 .so）
 *
 * 蜘蛛接口（对齐 TVBox / CatVod，与桌面 SpiderHost.java 的 dispatchMethod 一致）：
 *   String homeContent(boolean)
 *   String categoryContent(String, String, boolean, Map<String,String>)
 *   String detailContent(List<String>)
 *   String searchContent(String, boolean, String)
 *   String playerContent(String, String, List<String>)
 *   String liveContent(String)
 *   Object[] proxy(Map<String,String>)
 */
class SpiderHostPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var appContext: Context? = null

    /** 按 className 保存已初始化的蜘蛛实例：一个订阅会同时用到几十个源，不能用单例互相覆盖。 */
    private data class SpiderHolder(val instance: Any, val clazz: Class<*>)

    /** 同一份 jar 只建一个 DexClassLoader，避免为每个源重复解包加固壳。 */
    private val loaders = ConcurrentHashMap<String, dalvik.system.DexClassLoader>()
    private val spiders = ConcurrentHashMap<String, SpiderHolder>()
    @Volatile private var lastClassName: String? = null

    // 壳自带的「宿主代理」本地端口（playerContent 返回的 127.0.0.1 地址要改写到这个端口）
    @Volatile private var proxyPort = 0

    // 在进程内起一个最小 HTTP server，把 /proxy?do=… 转发给蜘蛛的 proxy(Map) 方法，
    // 让加固壳回的 127.0.0.1 取流地址在安卓上也能解析（桌面由 spider-host.jar 的
    // com.github.catvod.Proxy 监听；这里用原生 ServerSocket 等价实现）。
    private var proxyServer: ServerSocket? = null
    private val proxyExecutor = Executors.newCachedThreadPool()

    // 加载/调用蜘蛛会做文件 IO、网络请求、加固壳原生解包（可达数十秒），必须离开主线程，
    // 否则 NetworkOnMainThreadException / ANR。MethodChannel 的 reply 仍回主线程。
    private val workExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL = "com.kniephos.kniephos/spider"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        unloadInternal()
        stopProxy()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "loadSpider" -> {
                    val paths = (call.argument<List<*>>("paths") as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                    val className = call.argument<String>("className") ?: ""
                    val ext = call.argument<String>("ext") ?: ""
                    val cacheDir = call.argument<String>("cacheDir") ?: appContext?.cacheDir?.absolutePath ?: ""
                    runAsync(result) { loadSpider(paths, className, ext, cacheDir) }
                }
                "invoke" -> {
                    val method = call.argument<String>("method") ?: ""
                    val args = (call.argument<List<*>>("args") as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                    val className = call.argument<String>("className") ?: ""
                    runAsync(result) { invoke(method, args, className) }
                }
                "loadNative" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(loadNative(path))
                }
                "unload" -> {
                    result.success(unload())
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.success(
                mapOf(
                    "ok" to false,
                    "error" to "plugin: ${t.javaClass.name}: ${t.message}",
                ),
            )
        }
    }

    /** 把耗时调用挪到后台线程，reply 仍需回到主线程。 */
    private fun runAsync(result: MethodChannel.Result, block: () -> Map<String, Any?>) {
        workExecutor.execute {
            val reply: Map<String, Any?> = try {
                block()
            } catch (t: Throwable) {
                mapOf("ok" to false, "error" to "plugin: ${t.javaClass.name}: ${t.message}")
            }
            mainHandler.post { result.success(reply) }
        }
    }

    // ------------------------------------------------------------------
    // 加载并初始化蜘蛛
    // ------------------------------------------------------------------
    @Synchronized   // 加固壳首次解包很贵，串行加载避免多个源同时触发重复解包
    private fun loadSpider(paths: List<String>, className: String, ext: String, cacheDir: String): Map<String, Any?> {
        return try {
            if (paths.isEmpty()) throw IllegalArgumentException("paths 为空")
            if (className.isEmpty()) throw IllegalArgumentException("className 为空")

            // Android 14 (API 34) 起对动态代码加载加了只读要求：交给 DexClassLoader 的
            // dex / jar / apk 在打开前必须是不可写文件，否则 ART 直接抛
            // `SecurityException: Writable dex file '...' is not allowed.`。
            // 这些文件由 Dart 侧下载到 files/jvm_cache/jars（默认可写），所以在这里统一收紧。
            val dexPath = paths.joinToString(File.pathSeparator) { path ->
                val f = File(path)
                if (!f.exists()) throw IllegalArgumentException("蜘蛛文件不存在：$path")
                if (!makeReadOnly(f)) {
                    throw SecurityException("无法把蜘蛛文件设为只读（Android 14+ 要求）：$path")
                }
                f.absolutePath
            }

            val optimizedDir = File(appContext?.codeCacheDir ?: appContext!!.cacheDir, "spider_dex").apply { mkdirs() }
            val loader = loaders.getOrPut(dexPath) {
                dalvik.system.DexClassLoader(
                    dexPath,
                    optimizedDir.absolutePath,
                    null,
                    this.javaClass.classLoader
                )
            }

            if (spiders.containsKey(className)) {
                lastClassName = className
                return mapOf("ok" to true, "proxyPort" to proxyPort)
            }

            val clazz = Class.forName(className, true, loader)
            val instance = clazz.getDeclaredConstructor().newInstance()

            // init(Context, ext)
            try {
                clazz.getMethod("init", Context::class.java, String::class.java)
                    .invoke(instance, appContext, ext)
            } catch (_: NoSuchMethodException) {
                try { clazz.getMethod("init", Context::class.java).invoke(instance, appContext) } catch (_: NoSuchMethodException) {}
            }

            // initApi(SpiderApi)（可选）
            try {
                val apiCls = Class.forName("com.github.catvod.crawler.SpiderApi", true, loader)
                val api = apiCls.getDeclaredConstructor().newInstance()
                clazz.getMethod("initApi", apiCls).invoke(instance, api)
            } catch (_: Throwable) { /* 多数蜘蛛没有 initApi */ }

            spiders[className] = SpiderHolder(instance, clazz)
            lastClassName = className

            // 启动进程内宿主代理（加固壳 / 哔哩聚合源会用 127.0.0.1 回放地址）
            startProxy()

            mapOf("ok" to true, "proxyPort" to proxyPort)
        } catch (t: Throwable) {
            val c = rootCause(t)
            mapOf("ok" to false, "error" to "${c.javaClass.name}: ${c.message}")
        }
    }

    // ------------------------------------------------------------------
    // 反射调用蜘蛛方法（对齐 SpiderHost.java dispatchMethod）
    // ------------------------------------------------------------------
    private fun invoke(method: String, args: List<String>, className: String = ""): Map<String, Any?> {
        val name = className.ifEmpty { lastClassName ?: "" }
        val holder = spiders[name] ?: return errMap("蜘蛛尚未加载：$name")
        val sp = holder.instance
        val clazz = holder.clazz
        return try {
            val data = when (method) {
                "homeContent" -> clazz.getMethod("homeContent", Boolean::class.javaPrimitiveType)
                    .invoke(sp, true) as? String ?: ""
                "homeVideoContent" -> clazz.getMethod("homeVideoContent").invoke(sp) as? String ?: ""
                "categoryContent" -> {
                    val extend = LinkedHashMap<String, String>()
                    if (args.size > 2 && args[2].isNotEmpty()) {
                        for (kv in args[2].split("&".toRegex()).toTypedArray()) {
                            val eq = kv.indexOf('=')
                            if (eq > 0) {
                                val k = decode(kv.substring(0, eq))
                                val v = decode(kv.substring(eq + 1))
                                extend[k] = v
                            }
                        }
                    }
                    clazz.getMethod(
                        "categoryContent", String::class.java, String::class.java,
                        Boolean::class.javaPrimitiveType, java.util.HashMap::class.java
                    ).invoke(
                        sp,
                        args.getOrNull(0) ?: "",
                        args.getOrNull(1) ?: "1",
                        true,
                        extend
                    ) as? String ?: ""
                }
                "detailContent" -> {
                    val ids = (args.getOrNull(0) ?: "").split(",").toMutableList()
                    clazz.getMethod("detailContent", List::class.java)
                        .invoke(sp, ids) as? String ?: ""
                }
                "searchContent" -> {
                    val wd = args.getOrNull(0) ?: ""
                    try {
                        clazz.getMethod("searchContent", String::class.java, Boolean::class.javaPrimitiveType, String::class.java)
                            .invoke(sp, wd, false, args.getOrNull(1) ?: "1") as? String ?: ""
                    } catch (_: NoSuchMethodException) {
                        clazz.getMethod("searchContent", String::class.java, Boolean::class.javaPrimitiveType)
                            .invoke(sp, wd, false) as? String ?: ""
                    }
                }
                "playerContent" -> {
                    val vips = (args.getOrNull(2) ?: "").split(",").map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
                    clazz.getMethod("playerContent", String::class.java, String::class.java, List::class.java)
                        .invoke(sp, args.getOrNull(0) ?: "", args.getOrNull(1) ?: "", vips) as? String ?: ""
                }
                "liveContent" -> clazz.getMethod("liveContent", String::class.java)
                    .invoke(sp, args.getOrNull(0) ?: "") as? String ?: ""
                "proxy" -> {
                    val params = LinkedHashMap<String, String>()
                    if (args.isNotEmpty() && args[0].isNotEmpty()) {
                        try {
                            val obj = JSONObject(args[0])
                            obj.keys().forEach { params[it] = obj.optString(it) }
                        } catch (_: Throwable) {}
                    }
                    val ret = clazz.getMethod("proxy", Map::class.java).invoke(sp, params)
                    ret?.let { toProxyJson(it) } ?: ""
                }
                else -> return errMap("未知方法: $method")
            }
            mapOf("ok" to true, "data" to data)
        } catch (t: Throwable) {
            val cause = rootCause(t)
            mapOf("ok" to false, "error" to "${cause.javaClass.name}: ${cause.message}")
        }
    }

    private fun loadNative(path: String): Map<String, Any> {
        return try {
            if (path.isEmpty()) throw IllegalArgumentException("path 为空")
            // 安卓原生的「unidbg 替代」：直接在本机 ART/ARM 上加载壳的 .so，
            // 让它的 JNI 解密逻辑真实跑起来（桌面用 unidbg 模拟，安卓不需要）。
            // W^X：被 dlopen 的库同样不能可写，否则新版 Android 会拒绝加载。
            val lib = File(path)
            if (!lib.exists()) throw IllegalArgumentException("原生库不存在：$path")
            makeReadOnly(lib)
            System.load(lib.absolutePath)
            mapOf("ok" to true)
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to "${t.javaClass.name}: ${t.message}")
        }
    }

    private fun unload(): Map<String, Any> {
        unloadInternal()
        stopProxy()
        return mapOf("ok" to true)
    }

    private fun unloadInternal() {
        spiders.clear()
        loaders.clear()
        lastClassName = null
    }

    // ------------------------------------------------------------------
    // 进程内宿主代理（最小 HTTP server，转发 /proxy）
    // ------------------------------------------------------------------
    private fun startProxy() {
        if (proxyServer != null) return
        try {
            val server = ServerSocket(0, 0, java.net.InetAddress.getLoopbackAddress())
            proxyPort = server.localPort
            proxyServer = server
            proxyExecutor.execute {
                try {
                    while (!server.isClosed) {
                        val sock = server.accept() ?: break
                        proxyExecutor.execute { handleProxy(sock) }
                    }
                } catch (_: Throwable) { /* server 关闭 */ }
            }
        } catch (_: Throwable) {
            // 绑定失败不致命：只影响加固壳/聚合源的 127.0.0.1 回放地址
            proxyPort = 0
        }
    }

    private fun stopProxy() {
        try { proxyServer?.close() } catch (_: Throwable) {}
        proxyServer = null
        proxyPort = 0
    }

    private fun handleProxy(sock: java.net.Socket) {
        try {
            sock.soTimeout = 30000
            val reader = sock.getInputStream().bufferedReader()
            val requestLine = reader.readLine() ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) { sock.close(); return }
            val uri = java.net.URI.create("http://localhost" + parts[1])
            val params = LinkedHashMap<String, String>()
            uri.query?.split("&")?.forEach { pair ->
                val eq = pair.indexOf('=')
                if (eq > 0) params[decode(pair.substring(0, eq))] = decode(pair.substring(eq + 1))
            }
            val out = invokeProxy(params)
            val body = out.second ?: byteArrayOf()
            val headers = buildString {
                append("HTTP/1.1 ${out.first}\r\n")
                append("Content-Length: ${body.size}\r\n")
                append("Access-Control-Allow-Origin: *\r\n")
                append("Connection: close\r\n\r\n")
            }
            sock.getOutputStream().write(headers.toByteArray())
            sock.getOutputStream().write(body)
            sock.getOutputStream().flush()
        } catch (_: Throwable) {
            try { sock.close() } catch (_: Throwable) {}
        } finally {
            try { sock.close() } catch (_: Throwable) {}
        }
    }

    /** 调用蜘蛛的 proxy(Map)，把 Object[]{status, contentType, InputStream} 转成 HTTP 响应。 */
    private fun invokeProxy(params: Map<String, String>): Pair<Int, ByteArray> {
        val holder = lastClassName?.let { spiders[it] }
            ?: return 500 to "spider not loaded".toByteArray()
        val sp = holder.instance
        val clazz = holder.clazz
        // 显式标注类型，避免 try/catch 表达式被推断成公共超类型 Serializable。
        val result: Pair<Int, ByteArray> = try {
            val ret = clazz.getMethod("proxy", Map::class.java).invoke(sp, params)
            val arr = ret as? Array<*> ?: return 500 to "bad proxy return".toByteArray()
            val status = (arr.getOrNull(0) as? Number)?.toInt() ?: 200
            val bytes = when (val body = arr.getOrNull(2)) {
                is ByteArray -> body
                is String -> body.toByteArray()
                is InputStream -> readStream(body)
                else -> byteArrayOf()
            }
            status to bytes
        } catch (t: Throwable) {
            500 to (rootCause(t).message?.toByteArray() ?: byteArrayOf())
        }
        return result
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /**
     * Android 14 (API 34) 起，DexClassLoader / System.load 打开的文件必须不可写
     * （"更安全的动态代码加载"）。Dart 侧下载的 jar 默认是可写的，这里在加载前收紧权限。
     * File.setReadOnly() 内部就是 chmod；个别 ROM 上不生效时用 /system/bin/chmod 兜底。
     */
    private fun makeReadOnly(file: File): Boolean {
        if (!file.exists()) return false
        if (file.canWrite()) file.setReadOnly()
        if (file.canWrite()) {
            try {
                Runtime.getRuntime().exec(arrayOf("/system/bin/chmod", "444", file.absolutePath)).waitFor()
            } catch (_: Throwable) { /* 部分 ROM 无该可执行文件 */ }
        }
        return !file.canWrite()
    }

    private fun errMap(msg: String): Map<String, Any> = mapOf("ok" to false, "error" to msg)

    private fun decode(s: String): String = try { java.net.URLDecoder.decode(s, "UTF-8") } catch (_: Throwable) { s }

    private fun rootCause(t: Throwable): Throwable {
        var c = t
        while (c.cause != null) c = c.cause as Throwable
        return c
    }

    private fun toProxyJson(ret: Any?): String {
        if (ret !is Array<*>) return ""
        val status = (ret.getOrNull(0) as? Number)?.toInt() ?: 200
        val bytes = when (val b = ret.getOrNull(2)) {
            is ByteArray -> b.toString(Charsets.UTF_8)
            is String -> b
            is InputStream -> readStream(b).toString(Charsets.UTF_8)
            else -> ""
        }
        return JSONObject().apply {
            put("status", status)
            put("body", bytes)
        }.toString()
    }

    private fun readStream(stream: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(8192)
        var n: Int
        while (stream.read(buf).also { n = it } > 0) {
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }
}
