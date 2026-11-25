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

// 调试包的提交编号：优先认 tool/build_debug.ps1 传进来的 -Pzhixin.commit，没有这个
// 参数时读它写下的 last_build.json（脚本异常退出、之后用 gradlew 或 Android Studio
// 直接构建时用）。提交编号随 dart-define 进 Dart 侧，版本串由 platform/app_info.dart
// 拼出来；构建产物由脚本整理到仓库根目录的 build/debug/，只留最新一份。
val commitFromScript = providers.gradleProperty("zhixin.commit").orNull?.trim().orEmpty()
val lastBuildFile = rootProject.file("last_build.json")
val commitFromFile =
    if (commitFromScript.isEmpty() && lastBuildFile.exists()) {
        Regex("\"commit\"\\s*:\\s*\"([0-9a-fA-F]{7,40})\"")
            .find(lastBuildFile.readText())
            ?.groupValues
            ?.get(1)
            ?.lowercase()
            .orEmpty()
    } else {
        ""
    }
val buildCommit = commitFromScript.ifEmpty { commitFromFile }

logger.lifecycle(
    if (buildCommit.isEmpty()) {
        "调试包不带提交编号：用 tool/build_debug.ps1 构建，或者传 -Pzhixin.commit=<commit>"
    } else {
        "调试包提交编号：$buildCommit"
    },
)

android {
    // Flutter 任务从同名 Gradle 属性读 dart-define；项目属性是只读的，这里写同名的
    // 系统属性，Gradle 9 读项目属性时会回落到它。命令行传进来的同名数组优先，两边
    // 不会打架，同一个 key 也不会出现两个值。
    if (buildCommit.isNotEmpty()) {
        System.setProperty("dart-defines", "ZHIXIN_COMMIT=$buildCommit")
    }
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

// 调试包与正式包都按 Flutter 默认的 build/app/outputs/ 落盘，文件名固定，脚本
// 构建完从那里取走；每次构建前脚本会清掉自己那一份。
flutter {
    source = "../.."
}
