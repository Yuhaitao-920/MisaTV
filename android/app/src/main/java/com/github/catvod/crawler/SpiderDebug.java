package com.github.catvod.crawler;

import android.util.Log;

/**
 * TVBox / CatVod 蜘蛛的调试日志宿主类。加固壳 payload 常静态调用 SpiderDebug.log，
 * 缺失时会在真实实现类加载阶段抛 NoClassDefFoundError。
 */
public class SpiderDebug {

    private static final String TAG = "CatVodSpider";

    public SpiderDebug() {
    }

    public static void log(String message) {
        if (message != null) Log.d(TAG, message);
    }

    public static void log(Throwable throwable) {
        if (throwable != null) Log.w(TAG, throwable);
    }

    public static void trace(String message, Throwable throwable) {
        if (throwable != null) Log.w(TAG, message, throwable);
    }

    public static String ec(int code) {
        return String.valueOf(code);
    }
}
