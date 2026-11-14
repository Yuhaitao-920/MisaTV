package com.kniephos.kniephos

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
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
    }
}
