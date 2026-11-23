package com.kniephos.kniephos

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.chaquo.python.PyException
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Android 版 .py 蜘蛛运行器。
 *
 * 桌面端是「按需下载 CPython embed 包 → 外部 python.exe 进程执行 runner.py」；
 * Android 10+ 的应用被禁止 exec 应用数据目录里的文件（targetSdk ≥ 29），
 * 无法照搬。这里改用 Chaquopy 把 CPython 3.12 随 APK 内置，并在应用进程内
 * 通过 JNI 调用同一份 `runner.py` 的 inproc 入口：
 *
 *   call       {runnerDir, script, className, method, ext, argsJson} -> 信封 JSON
 *   hold       {key, ...同上}                                        -> 信封 JSON
 *   heldCall   {key, method, argsJson}                               -> 信封 JSON
 *   release    {key}                                                 -> 信封 JSON
 *   releaseAll / reset                                               -> 信封 JSON
 *
 * 信封格式由 runner.py 统一生成：{"ok": true, "data": "..."} 或
 * {"ok": false, "error": "[SpiderRunner.ERROR] ..."}。Dart 侧只认这一层，
 * 与桌面进程版共用同一套解析 / 错误归类逻辑。
 *
 * 所有 Python 调用都放到后台线程：蜘蛛会做文件 IO、网络请求与解析，
 * 不能在主线程执行（否则 ANR）。MethodChannel 的回包仍切回主线程。
 */
class PythonHostPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.kniephos.kniephos/python"

        @Volatile
        private var pythonStarted = false

        /** Chaquopy 的 Python 解释器每个进程只能启动一次。 */
        @Synchronized
        private fun ensurePython(context: Context) {
            if (pythonStarted || Python.isStarted()) {
                pythonStarted = true
                return
            }
            Python.start(AndroidPlatform(context))
            pythonStarted = true
        }
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val workExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** runner.py 所在目录。首次调用时加入 sys.path，之后复用已 import 的模块。 */
    @Volatile
    private var runnerDir: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("python", "Python 宿主尚未初始化", null)
            return
        }
        val args = call.arguments as? Map<*, *>
        if (args == null) {
            result.error("python", "Python 调用参数错误", null)
            return
        }
        val method = call.method
        // 应用退出时 Dart 会兜底 releaseAll；Python 没启动过就不要为了释放而启动解释器。
        if ((method == "release" || method == "releaseAll") &&
            !pythonStarted &&
            !Python.isStarted()
        ) {
            result.success("""{"ok": true, "data": ""}""")
            return
        }
        workExecutor.execute {
            try {
                ensurePython(context)
                val py = Python.getInstance()
                val dir = args.str("runnerDir")
                if (dir.isNotEmpty()) ensureRunnerPath(py, dir)
                val runner = py.getModule("runner")
                val output = when (method) {
                    "call" -> runner.callAttr(
                        "inproc_call",
                        args.str("script"),
                        args.str("className"),
                        args.str("method"),
                        args.str("ext"),
                        args.str("argsJson"),
                    ).toString()

                    "hold" -> runner.callAttr(
                        "inproc_hold",
                        args.str("key"),
                        args.str("script"),
                        args.str("className"),
                        args.str("method"),
                        args.str("ext"),
                        args.str("argsJson"),
                    ).toString()

                    "heldCall" -> runner.callAttr(
                        "inproc_held_call",
                        args.str("key"),
                        args.str("method"),
                        args.str("argsJson"),
                    ).toString()

                    "release" -> runner.callAttr(
                        "inproc_release",
                        args.str("key"),
                    ).toString()

                    "releaseAll" -> runner.callAttr("inproc_release_all").toString()

                    "reset" -> runner.callAttr("inproc_reset").toString()

                    "version" -> py.getModule("sys").get("version").toString()

                    else -> throw IllegalArgumentException("未知的 Python 调用: $method")
                }
                mainHandler.post { result.success(output) }
            } catch (e: Throwable) {
                val message = if (e is PyException) {
                    e.message ?: "Python 调用失败"
                } else {
                    e.message ?: e.toString()
                }
                mainHandler.post { result.error("python", message, null) }
            }
        }
    }

    /** 把 runner.py 所在目录加入 sys.path，让 `import runner` / `import base.spider` 命中。 */
    @Synchronized
    private fun ensureRunnerPath(py: Python, dir: String) {
        if (runnerDir == dir) return
        // Chaquopy 的 PyObject.get 返回可空类型；sys.path 必然存在，取不到说明运行时异常。
        val path = py.getModule("sys").get("path")
            ?: throw IllegalStateException("无法获取 sys.path")
        // 去重后插到最前：升级 / 重建时旧目录不能继续挡住新 runner。
        while (true) {
            try {
                path.callAttr("remove", dir)
            } catch (_: Throwable) {
                break
            }
        }
        path.callAttr("insert", 0, dir)
        runnerDir = dir
    }

    private fun Map<*, *>.str(key: String): String = this[key]?.toString() ?: ""
}
