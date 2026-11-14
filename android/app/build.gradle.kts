plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.kniephos.kniephos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.kniephos.kniephos"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Flutter 3.47 的 release 构建会跑 R8。CatVod 宿主类只被外部 jar/壳 dex
            // 反射引用，不 keep 会被裁掉或混淆成短名，导致加固壳 ClassNotFoundException。
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
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
