package com.kniephos.kniephos

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val WAKELOCK_CHANNEL = "com.kniephos.kniephos/wakelock"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // wex / *Guard 加固壳的 Init.init(Application) 必须拿到真实的 Application。
        // FlutterPluginBinding.applicationContext 在部分机型上是 ContextImpl 而不是
        // Application，插件里再怎么剥 ContextWrapper 都取不到，所以这里从 Activity
        // 直接绑定一次（getApplication() 是框架保证的 Application 实例）。
        SpiderHostPlugin.bindApplication(application)
        super.configureFlutterEngine(flutterEngine)
        // 手动注册安卓原生 jar/DEX 蜘蛛运行器（dex2jar + unidbg 的安卓等价实现）。
        // 该插件是本地代码（未走 pub 插件自动注册），故在此显式添加。
        flutterEngine.plugins.add(SpiderHostPlugin())

        // 安卓外部播放器通道：枚举手机上任意播放器 + ACTION_VIEW 拉起。
        ExternalPlayerPlugin.register(flutterEngine, application)

        // 播放期间保持屏幕常亮：Dart 侧 SleepInhibitor 通过此 channel 控制。
        // 用 window flag 而非 WakeLock，无需额外权限；失败静默忽略，不影响播放。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKELOCK_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "acquire" -> {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            result.success(null)
                        }
                        "release" -> {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.success(null)
                }
            }
    }
}
