package com.tvbus.engine;

import android.content.Context;
import android.text.TextUtils;

import java.util.List;

/**
 * TVBus Go 引擎的 Java 侧包装。
 *
 * 适配自 FongMi/TV（GPL-3.0）的 tvbus 模块。类名、包名与 native 方法签名
 * 必须与直播源下发的 Go `.so` 的 JNI 导出符号保持一致，不能重命名或裁剪。
 *
 * 与 FongMi 的差异：FongMi 从 `com.github.catvod.Runtime.context()` 取 Context，
 * 本项目没有这套宿主 Runtime，改为由 [TvBusPlugin] 在 attach 时调用
 * [setContext] 注入 Application Context。
 *
 * 注意：`.so` 是每个直播源自己的（来自订阅 `core.so`），不是通用 Go 运行时；
 * 主 APK 只包含这个很薄的 Java 包装。
 */
public class TVCore implements Runnable {

    private static volatile Context appContext;

    private final Thread thread;
    private final long handle;

    public static void setContext(Context context) {
        appContext = context;
    }

    public TVCore(String path) {
        System.load(path);
        handle = initialise();
        thread = new Thread(this);
    }

    public TVCore listener(Listener listener) {
        try {
            setListener(handle, listener);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore play(int port) {
        try {
            setPlayPort(handle, port);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore serv(int port) {
        try {
            setServPort(handle, port);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore mode(int mode) {
        try {
            setRunningMode(handle, mode);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore auth(String str) {
        try {
            if (!TextUtils.isEmpty(str)) setAuthUrl(handle, str);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore domain(String str) {
        try {
            if (!TextUtils.isEmpty(str)) setDomainSuffix(handle, str);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore broker(String str) {
        try {
            if (!TextUtils.isEmpty(str)) setMKBroker(handle, str);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore name(String str) {
        try {
            if (!TextUtils.isEmpty(str)) setUsername(handle, str);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public TVCore pass(String str) {
        try {
            if (!TextUtils.isEmpty(str)) setPassword(handle, str);
            return this;
        } catch (Throwable ignored) {
            return this;
        }
    }

    public void option(String key, List<String> values) {
        try {
            if (values.isEmpty()) return;
            values.removeIf(TextUtils::isEmpty);
            for (String value : values) setOption(handle, key, value);
        } catch (Throwable ignored) {
        }
    }

    public void init() {
        thread.start();
    }

    public void start(String url) {
        try {
            start(handle, url);
        } catch (Throwable ignored) {
        }
    }

    public void stop() {
        try {
            stop(handle);
        } catch (Throwable ignored) {
        }
    }

    public void quit() {
        try {
            quit(handle);
            thread.interrupt();
        } catch (Throwable ignored) {
        }
    }

    @Override
    public void run() {
        try {
            Context context = appContext;
            if (context == null) return;
            init(handle, context);
            run(handle);
        } catch (Throwable ignored) {
        }
    }

    private native long initialise();

    private native int init(long handle, Context context);

    private native int run(long handle);

    private native void start(long handle, String url);

    private native void stop(long handle);

    private native void quit(long handle);

    private native void setServPort(long handle, int iPort);

    private native void setPlayPort(long handle, int iPort);

    private native void setRunningMode(long handle, int mode);

    private native void setAuthUrl(long handle, String str);

    private native void setDomainSuffix(long handle, String str);

    private native void setMKBroker(long handle, String str);

    private native void setPassword(long handle, String str);

    private native void setUsername(long handle, String str);

    private native void setListener(long handle, Listener listener);

    private native void setOption(long handle, String key, String value);
}
