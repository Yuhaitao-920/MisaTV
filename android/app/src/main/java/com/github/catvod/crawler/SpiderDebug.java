package com.github.catvod.crawler;

import android.util.Log;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

/**
 * TVBox / CatVod 蜘蛛的调试日志宿主类。加固壳 payload 常静态调用 SpiderDebug.log，
 * 缺失时会在真实实现类加载阶段抛 NoClassDefFoundError。
 */
public class SpiderDebug {

     private static final int MAX_RECENT = 16;
     private static final int MAX_LINE_LEN = 240;
     private static final ArrayDeque<String> RECENT = new ArrayDeque<>();
     
     private static synchronized void record(String message) {
     if (message == null) return;
     String clean = message.replace('\r', ' ').replace('\n', ' ').trim();
     if (clean.isEmpty()) return;
     clean = clean.replaceAll("(?i)(BDUSS|STOKEN|__puus|randsk)=([^;\\s&\"']+)", "$1=***");
     if (clean.length() > MAX_LINE_LEN) clean = clean.substring(0, MAX_LINE_LEN) + "...";
     while (RECENT.size() >= MAX_RECENT) RECENT.removeFirst();
     RECENT.addLast(clean);
     }
     
     public static synchronized void clearRecent() {
     RECENT.clear();
     }
     
     public static synchronized List<String> drainRecent() {
     List<String> out = new ArrayList<>(RECENT);
     RECENT.clear();
     return out;
      
      }
        private static final String TAG = "CatVodSpider";

    public SpiderDebug() {
    }

    public static void log(String message) {
        if (message != null) Log.d(TAG, message);
         if (message != null) record(message);
            }

    public static void log(Throwable throwable) {
        if (throwable != null) Log.w(TAG, throwable);
         if (throwable != null) record(throwable.toString());
            }

    public static void trace(String message, Throwable throwable) {
        if (throwable != null) Log.w(TAG, message, throwable);
         if (throwable != null) record((message != null ? message + ": " : "") + throwable.toString());
            }

    public static String ec(int code) {
        return String.valueOf(code);
    }
}
