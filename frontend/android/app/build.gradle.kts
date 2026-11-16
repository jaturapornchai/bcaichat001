import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// One project builds two apps: the chat app by default and the shop app
// (BC Ai Chat OA) with `--dart-define=CLIENT_APP=oa`. Flutter hands dart-defines
// to Gradle as comma-separated base64 `KEY=VALUE` entries.
val clientApp: String = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.map { String(Base64.getDecoder().decode(it)) }
    ?.firstOrNull { it.startsWith("CLIENT_APP=") }
    ?.substringAfter("=")
    ?: "chat"
if (clientApp != "chat" && clientApp != "oa") {
    // The server refuses connections from an app name it does not know.
    throw GradleException("CLIENT_APP must be chat or oa, got: $clientApp")
}
val isShopApp = clientApp == "oa"

android {
    namespace = "com.bcaichat.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (java.time on older Android).
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (isShopApp) "com.bcaichat.oa" else "com.bcaichat.app"
        resValue("string", "app_name", if (isShopApp) "BC Ai Chat OA" else "BC Ai Chat")
        buildConfigField("String", "CLIENT_APP", "\"$clientApp\"")
        manifestPlaceholders["appIcon"] =
            if (isShopApp) "@mipmap/ic_launcher_oa" else "@mipmap/ic_launcher"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Push works only with android/app/google-services.json from the Firebase
// console (kept out of git); without it the app builds with in-app alerts only.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation(platform("com.google.firebase:firebase-bom:35.1.0"))
    implementation("com.google.firebase:firebase-messaging")
}
