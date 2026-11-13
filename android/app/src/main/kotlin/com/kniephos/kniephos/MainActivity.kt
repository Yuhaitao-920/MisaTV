package com.kniephos.kniephos

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 手动注册安卓原生 jar/DEX 蜘蛛运行器（dex2jar + unidbg 的安卓等价实现）。
        // 该插件是本地代码（未走 pub 插件自动注册），故在此显式添加。
        flutterEngine.plugins.add(SpiderHostPlugin())
    }
}
