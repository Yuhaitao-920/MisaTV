# 第三方组件与许可

MisaTV 本体代码以 GPL-3.0 发布（见 [LICENSE](LICENSE)）。仓库里还包含或依赖下列第三方内容，
它们各自遵循原作者的许可；本文件按「随仓库分发 / 运行期按需下载 / 不随仓库分发」三类列出。

## 一、随仓库分发的第三方内容

| 内容 | 位置 | 来源与许可 |
| --- | --- | --- |
| MiSans 字体（随包 3 个字重；仓库保留 5 个） | `assets/fonts/` | 小米 MiSans，遵循 MiSans 字体许可协议（免费商用，见 <https://hyperos.mi.com/font/>） |
| cheerio（浏览器构建） | `assets/js_lib/cheerio.min.js` | cheerio，MIT，<https://github.com/cheeriojs/cheerio> |
| crypto-js | `assets/js_lib/crypto-js.js` | crypto-js，MIT，<https://github.com/brix/crypto-js> |
| cat.js / 模板.js / gbk.js | `assets/js_lib/` | TVBox / CatVod JS 蜘蛛生态的公共支持库，版权归原作者 |
| string-similarity | `assets/js_lib/similarity.js` | MIT，<https://github.com/aceakash/string-similarity> |
| MCrypt 移植 | `lib/services/relay/m3u8_purify.dart` | 逐函数移植 TVBox `util/M3u8.java` 的 `purify()` 链（作者 asdfgh / FongMi），源码内已注明 |
| TVBus Java 包装 | `android/.../com/tvbus/engine/` | 适配自 [FongMi/TV](https://github.com/FongMi/TV) 的 tvbus 模块（GPL-3.0）；只保留 JNI 契约与 Java 包装 |
| TVBus PackageManager Hook | `android/app/libs/hook-release.aar` | 适配自 FongMi/TV 的 hook 模块（GPL-3.0），用于 `core.pkg` / `core.sign` 伪造，仅 5KB |

`assets/js_lib/utils.js`、`assets/python_runner/`（`runner.py`、`base/spider.py`）、
`assets/jvm/src/`（`SpiderHost.java`、`DexNative.java`、`MyCrypto.java`、`GoProxy.java`）
以及 `assets/jvm/` 下的 `*.jar`（`stubs` 为 TVBox 接口兼容桩、其余为对应 Java 源构建的 shim）
均为本项目自建内容，随本仓库以 GPL-3.0 发布。

## 二、运行期按需下载（不随仓库分发）

| 运行时 | 用途 | 来源与许可 |
| --- | --- | --- |
| JRE 17（Adoptium Temurin） | JAR / DEX 蜘蛛 | GPL-2.0 with Classpath Exception，<https://adoptium.net/> |
| dex2jar | DEX → JAR 转换 | Apache-2.0，<https://github.com/pxb1988/dex2jar> |
| CPython 3.11 embedded | PY 蜘蛛 | PSF License，<https://www.python.org/> |
| TVBus Go 引擎 `.so` | Android TVBus P2P 直播 | 由用户导入的直播源 `core.so` 在运行期下载；不随仓库/APK 分发，许可与内容由源提供方负责 |
| unidbg 0.9.9 + dynarmic | 加固壳 ARM 桥 | Apache-2.0，<https://github.com/zhkl0228/unidbg> |
| okhttp / okio / gson / jsoup / slf4j / bcprov / sqlite-jdbc | 蜘蛛支持库 | Apache-2.0 / MIT / EPL-1.0，取自 Maven 镜像 |
| Yaozhi MPV 整合包 | 可选外部播放器 | GPL-2.0+，<https://github.com/Yaozhil/mpv-Yaozhi> |

## 三、不随仓库分发（需自行准备，见 README「运行前准备」）

| 内容 | 原因 |
| --- | --- |
| `assets/aria2/aria2c.exe` | 第三方产物（aria2，GPLv2），体积大、可自行下载 |
| `assets/jvm/shell-real/*.jar` | 第三方加固壳的真实实现，版权归各自权利人；缺失时自动回退原生解包 |

## 四、依赖与播放内核

Dart / Flutter 依赖见 [`pubspec.yaml`](pubspec.yaml) 与 [`pubspec.lock`](pubspec.lock)，
各自遵循 pub.dev 上声明的许可（多数为 BSD-3 / MIT / Apache-2.0）。内置播放器使用
[fvp](https://pub.dev/packages/fvp)（libmdk / FFmpeg），其许可见对应项目。

Android 构建还会在构建期通过 [Chaquopy](https://chaquo.com/chaquopy/) 打包
CPython 3.12（MIT / PSF License）以及 requests、urllib3、certifi、
charset-normalizer、idna、lxml、pycryptodome、beautifulsoup4、soupsieve、
pyquery、cssselect、chardet、requests-toolbelt、typing-extensions、
websocket-client、pywasm 等 PY 蜘蛛依赖（各自原许可）。它们只存在于构建产物
APK 中，不随本仓库分发，也不在运行期下载。

## 五、图标

应用图标是同人作品，**不适用 GPL-3.0**，著作权与使用权归其权利人（详见 README「图标」一节）。
