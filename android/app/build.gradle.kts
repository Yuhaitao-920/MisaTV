import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // .py 蜘蛛的 CPython 运行时（3.12，随 APK 内置；Android 禁止执行数据目录里的下载文件）。
    id("com.chaquo.python")
}

// Chaquopy 只为 abiFilters 中的 ABI 打包 Python，而 Python 3.12 只有 64 位。
// Flutter 默认会把 armeabi-v7a 也加进 abiFilters，必须在脚本体里覆盖掉，
// 否则 APK 会声明支持 32 位 ARM，安装后加载 libpython 直接崩溃。
// `target-platform` 是 Flutter 工具传给 Gradle 的属性；没有传时按 64 位通用包处理。
val flutterTargetPlatforms =
    (project.findProperty("target-platform") as? String)
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        ?: emptyList()
val pythonAbis = buildList {
    if (flutterTargetPlatforms.isEmpty() ||
        flutterTargetPlatforms.any { it == "android-arm64" }
    ) {
        add("arm64-v8a")
    }
    if (flutterTargetPlatforms.isEmpty() ||
        flutterTargetPlatforms.any { it == "android-x64" }
    ) {
        add("x86_64")
    }
}
if (pythonAbis.isEmpty()) {
    throw GradleException(
        "Python 运行时仅支持 64 位 Android；请使用 --target-platform android-arm64 或 android-x64",
    )
}

android {
    namespace = "com.kniephos.kniephos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // hook-release.aar 用了 java.time 等新 API，AGP 的 AAR 元数据检查要求
        // 必须开启核心库脱糖，否则 checkReleaseAarMetadata 直接失败。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.kniephos.kniephos"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Chaquopy 17 要求 minSdk ≥ 24；Flutter 3.47 的默认值也是 24。
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // 只保留本次构建实际需要的 64 位 ABI：Chaquopy 会按这个列表裁剪 Python 运行库。
        ndk {
            abiFilters.clear()
            abiFilters.addAll(pythonAbis)
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 正式签名：四个环境变量齐全且 keystore 存在才启用。
    //
    // 这里**故意不回退 debug 签名**。debug keystore 是每台机器首次构建时
    // 自动生成的，不同机器 / 不同 CI runner 的指纹都不同；用它签出来的
    // release APK，用户装过一次之后就没法覆盖安装新版本（报「签名冲突」
    // / INSTALL_FAILED_UPDATE_INCOMPATIBLE）。以前这里写的是
    // `?: getByName("debug")`，等于把这个问题静默吞掉了。
    //
    // 现在缺配置时构建直接失败，并提示怎么补——比发一个装不上的包好。
    val releaseKeystore = System.getenv("ANDROID_KEYSTORE_PATH")
    val releaseStorePass = System.getenv("ANDROID_STORE_PASSWORD")
    val releaseKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
    val releaseKeyPass = System.getenv("ANDROID_KEY_PASSWORD")
    val hasReleaseSigning = !releaseKeystore.isNullOrBlank() &&
        !releaseStorePass.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPass.isNullOrBlank() &&
        file(releaseKeystore).exists()

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystore!!)
                storePassword = releaseStorePass
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPass
                // v2/v3 都要开：v2 起 Android 7.0+ 会优先用，某些 ROM 只认 v2+。
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    // 两个构建变体：
    //   full —— 现有全功能版（沉浸 + 常规 UI + 一起看 + DLNA + 外部播放器）
    //   tv   —— TV 精简版（只有沉浸界面；砍掉一起看 / DLNA / 外部播放器 / JVM 资源）
    //
    // Dart 侧通过 --dart-define=MISA_TV=true 配合，让不用的页面被 tree-shake；
    // 这里只负责「资源与清单层面」的裁剪（字体、assets）。
    flavorDimensions += "edition"
    productFlavors {
        create("full") {
            dimension = "edition"
            applicationId = "com.kniephos.kniephos"
        }
        create("tv") {
            dimension = "edition"
            // 独立包名：可与全功能版并存安装，互不覆盖。
            applicationId = "com.kniephos.kniephos.tv"
        }
    }

    packaging {
        jniLibs {
            // 双保险：Flutter 的 configureAbis 会在插件 apply 时把所有默认 ABI 加回来，
            // 这里按本次实际构建的 ABI 再把不用的目录排除一次。1.2.0 的 APK 因此
            // 多带了 armv7/x86_64 的 ffmpeg/mdk，约 25 MB。
            if (!pythonAbis.contains("arm64-v8a")) {
                excludes += "lib/arm64-v8a/**"
            }
            if (!pythonAbis.contains("armeabi-v7a")) {
                excludes += "lib/armeabi-v7a/**"
            }
            if (!pythonAbis.contains("x86_64")) {
                excludes += "lib/x86_64/**"
            }
            if (!pythonAbis.contains("x86")) {
                excludes += "lib/x86/**"
            }
        }
        resources {
            // 安卓端**永远**不需要这些，打进去只是白占体积：
            //   · jvm/**       桌面端 JRE 用的 shim jar。安卓走 ART / DexClassLoader，
            //                  JvmRuntime.jarSpiderReady() 对 Android 直接返回 true，
            //                  这些 jar 在安卓上没有任何读取者。
            //   · aria2/**     Windows 的 aria2c.exe，安卓用内置 BT 实现。
            //
            // **路径前缀必须是 `assets/flutter_assets/`**：Flutter 会把 pubspec 里
            // 声明的 assets 复制到 APK 的这个目录下，而不是 APK 根部的 `assets/`。
            // 写成 `assets/jvm/**` 一条都匹配不上（实测残留 0.4 MB 才发现的）。
            excludes += "assets/flutter_assets/assets/jvm/**"
            excludes += "assets/flutter_assets/assets/aria2/**"
        }
    }

    buildTypes {
        release {
            // 没有正式签名就构建失败，绝不回退 debug 签名。
            //
            // 回退 debug 的后果是：用户装过一个版本后，新版本因为用的是另一个
            // debug keystore（换机器 / 换 CI runner 就会变）而无法覆盖安装。
            // 与其发一个「装不上」的包，不如在构建阶段就报错。
            signingConfig = signingConfigs.findByName("release")
                ?: throw GradleException(
                    "缺少 Android 正式签名配置，release 构建已中止。\n" +
                        "原因是 debug keystore 每台机器不同，用它签的包无法覆盖安装" +
                        "（用户会看到「签名冲突」）。\n" +
                        "请配置以下 4 个环境变量后重试：\n" +
                        "  ANDROID_KEYSTORE_PATH    keystore 文件路径（.jks）\n" +
                        "  ANDROID_STORE_PASSWORD   keystore 密码\n" +
                        "  ANDROID_KEY_ALIAS        密钥别名\n" +
                        "  ANDROID_KEY_PASSWORD     密钥密码\n" +
                        "本地调试可用 --debug 构建，那条路径不受影响。",
                )
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles("proguard-rules.pro")
        }
    }
}

// .py 蜘蛛运行时。依赖清单与桌面端 PyRuntime._wheels 保持一致：
// requests 系为必需，lxml / pycryptodome / bs4 / pyquery / websocket-client
// 等为可选增强。纯 Python 包走 PyPI，带原生扩展的包由 Chaquopy 的
// Android wheel 仓库（chaquo.com/pypi-13.1）提供。
chaquopy {
    defaultConfig {
        // Chaquopy 的 buildPython 需要同主次版本（3.12）：Windows 上会自动找
        // `py -3.12`，CI 由 setup-python 提供。
        version = "3.12"
        pip {
            install("requests")
            install("urllib3")
            install("certifi")
            install("charset_normalizer")
            install("idna")
            install("beautifulsoup4")
            install("soupsieve")
            // 锁定 Chaquopy 仓库里有 Android wheel 的版本，避免 pip 去 PyPI
            // 取新版本源码包（没有 Android 交叉编译环境，会直接失败）。
            install("lxml==5.3.0")
            install("pycryptodome==3.21.0")
            install("pyquery")
            install("cssselect")
            // chardet 与 charset_normalizer 功能重复，且 python_runner 的基础库
            // 只用后者（requests 会自动挑可用的那个）。去掉可省约 1 MB。
            install("requests-toolbelt")
            install("typing_extensions")
            install("websocket-client")
            // 与桌面端一致：锁在无依赖、API 兼容的 0.4.8。
            install("pywasm==0.4.8")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 核心库脱糖运行时（与 compileOptions.isCoreLibraryDesugaringEnabled 配套）。
    // hook-release.aar 的 AAR 元数据要求 nio flavor 且 >= 2.1.5，普通 flavor 会被拒。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")

    // TVBus（Go 引擎）启动时按 core.pkg / core.sign 伪造 PackageManager。
    // 适配自 FongMi/TV 的 hook-release.aar（GPL-3.0），仅 5KB。
    implementation(files("libs/hook-release.aar"))
    // CatVod / wex 加固壳解密出的「真实蜘蛛」运行在宿主 ClassLoader 的 parent 链上，
    // 会直接引用 TVBox 宿主自带的 Java 库。Flutter 侧一个都没有，缺了就在
    // homeContent 抛 `NoClassDefFoundError: Failed resolution of: Lokhttp3/Request$Builder;`。
    // 这些类宿主代码本身不引用，只被外部 dex 反射/链接使用，因此 proguard-rules.pro
    // 里必须一并 -keep，否则 R8 会把它们全裁掉。
    //
    // 固定 OkHttp 3.12.x：这批壳是按 TVBox 的 OkHttp3 3.x API 编译的
    // （RequestBody.create(MediaType, String) 等），4.x 改了签名会 NoSuchMethodError。
    implementation("com.squareup.okhttp3:okhttp:3.12.13")   // 传递依赖 okio 1.17.x
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("org.jsoup:jsoup:1.16.1")
    implementation("com.alibaba:fastjson:1.2.83")
}

flutter {
    source = "../.."
}
