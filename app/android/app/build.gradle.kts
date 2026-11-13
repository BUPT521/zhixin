import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发版签名配置在 android/key.properties（本机文件，不入库，模板见 app/README）。
// 没有这个文件时回退 debug 签名，保证 clone 下来的人仍能 `flutter run --release`。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties =
    Properties().apply {
        if (keystorePropertiesFile.exists()) {
            keystorePropertiesFile.inputStream().use { load(it) }
        }
    }
val hasReleaseSigning = keystorePropertiesFile.exists()

android {
    namespace = "com.zhixin.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zhixin.app"
        // ADR-0003：最低 Android 11（API 30）。只出 arm64 包，不为 32 位和老机器降配。
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                // storeFile 相对 android/ 解析，与 key.properties 里的写法一致。
                val storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                require(storeFile.exists()) {
                    "key.properties 指向的 keystore 不存在：$storeFile（keystore 不入库，需随 key.properties 一起备份）"
                }
                this.storeFile = storeFile
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // 开发包与正式包按两个应用安装：可以并存，数据互不影响，安装也不互相覆盖。
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
        release {
            // 有 key.properties 就正式签名；没有则用 debug 签名，`flutter run --release` 仍可用。
            signingConfig =
                if (hasReleaseSigning) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
