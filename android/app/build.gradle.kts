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

    // 可选正式签名：四个环境变量齐全且 keystore 存在才启用，否则回退 debug 签名。
    // 合并自 PR #30；与 build-android.yml 里「Decode Android release keystore」配套。
    signingConfigs {
        val keystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
        val storePasswordEnv = System.getenv("ANDROID_STORE_PASSWORD")
        val keyAliasEnv = System.getenv("ANDROID_KEY_ALIAS")
        val keyPasswordEnv = System.getenv("ANDROID_KEY_PASSWORD")
        if (!keystorePath.isNullOrBlank() &&
            !storePasswordEnv.isNullOrBlank() &&
            !keyAliasEnv.isNullOrBlank() &&
            !keyPasswordEnv.isNullOrBlank() &&
            file(keystorePath).exists()
        ) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = storePasswordEnv
                keyAlias = keyAliasEnv
                keyPassword = keyPasswordEnv
            }
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
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
            install("chardet")
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
