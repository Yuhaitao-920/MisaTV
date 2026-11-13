package com.kniephos.kniephos

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.ServerSocket
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
 *   invoke(method, args[])                        -> {ok, data, error}
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

    // 当前已加载的蜘蛛实例与它的类加载器
    private var spider: Any? = null
    private var spiderClassLoader: ClassLoader? = null
    private var spiderClass: Class<*>? = null

    // 壳自带的「宿主代理」本地端口（playerContent 返回的 127.0.0.1 地址要改写到这个端口）
    @Volatile private var proxyPort = 0

    // 在进程内起一个最小 HTTP server，把 /proxy?do=… 转发给蜘蛛的 proxy(Map) 方法，
    // 让加固壳回的 127.0.0.1 取流地址在安卓上也能解析（桌面由 spider-host.jar 的
    // com.github.catvod.Proxy 监听；这里用原生 ServerSocket 等价实现）。
    private var proxyServer: ServerSocket? = null
    private val proxyExecutor = Executors.newCachedThreadPool()

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
                    result.success(loadSpider(paths, className, ext, cacheDir))
                }
                "invoke" -> {
                    val method = call.argument<String>("method") ?: ""
                    val args = (call.argument<List<*>>("args") as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                    result.success(invoke(method, args))
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

    // ------------------------------------------------------------------
    // 加载并初始化蜘蛛
    // ------------------------------------------------------------------
    private fun loadSpider(paths: List<String>, className: String, ext: String, cacheDir: String): Map<String, Any> {
        return try {
            if (paths.isEmpty()) throw IllegalArgumentException("paths 为空")
            val optimizedDir = File(appContext?.codeCacheDir ?: appContext!!.cacheDir, "spider_dex").apply { mkdirs() }
            val parent = spiderClassLoader ?: this.javaClass.classLoader
            val loader = dalvik.system.DexClassLoader(
                paths.joinToString(File.pathSeparator),
                optimizedDir.absolutePath,
                null,
                parent
            )
            spiderClassLoader = loader

            val clazz = Class.forName(className, true, loader)
            spiderClass = clazz
            val instance = clazz.getDeclaredConstructor().newInstance()
            spider = instance

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

            // 启动进程内宿主代理（加固壳 / 哔哩聚合源会用 127.0.0.1 回放地址）
            startProxy()

            mapOf("ok" to true, "proxyPort" to proxyPort)
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to "${t.javaClass.name}: ${t.message}")
        }
    }

    // ------------------------------------------------------------------
    // 反射调用蜘蛛方法（对齐 SpiderHost.java dispatchMethod）
    // ------------------------------------------------------------------
    private fun invoke(method: String, args: List<String>): Map<String, Any?> {
        val sp = spider ?: return errMap("蜘蛛尚未加载")
        val clazz = spiderClass ?: return errMap("蜘蛛类缺失")
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
            System.load(File(path).absolutePath)
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
        spider = null
        spiderClass = null
        spiderClassLoader = null
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
        val sp = spider ?: return 500 to "spider not loaded".toByteArray()
        val clazz = spiderClass ?: return 500 to "spider class missing".toByteArray()
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
