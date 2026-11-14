package com.github.catvod.crawler;

/**
 * TVBox / CatVod 的 SpiderApi 宿主类占位实现。
 *
 * <p>普通 jar 蜘蛛不会用到；加固壳解出的真实实现偶而会反射拿它做日志 / 本地代理端口查询。
 * 提供最小签名即可保证类解析不失败，具体能力由壳自带的 payload 自行实现。
 */
public class SpiderApi {

    public static final String LOOPBACK = "127.0.0.1";

    public SpiderApi() {
    }

    public String getAddress(boolean local) {
        return LOOPBACK;
    }

    public String getPort() {
        return "0";
    }

    public void log(String message) {
    }

    public int getScreenOrientation() {
        return 0;
    }
}
