package com.tvbus.engine;

/**
 * TVBus Go 引擎回调。接口方法名与 JNI 侧固定，不能改名。
 *
 * 适配自 FongMi/TV（GPL-3.0）的 tvbus 模块，仅保留 JNI 契约。
 */
public interface Listener {

    void onInited(String result);

    void onStart(String result);

    void onPrepared(String result);

    void onInfo(String result);

    void onStop(String result);

    void onQuit(String result);
}
