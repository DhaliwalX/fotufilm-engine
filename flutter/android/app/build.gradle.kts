plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.muastudio.fotufilm.flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Its own app beside the Compose one (com.muastudio.fotufilm) while this is an experiment.
        applicationId = "com.muastudio.fotufilm.flutter"
        // The engine is built for android-28 (the Swift SDK's lowest), for 64-bit ARM alone.
        minSdk = 28
        ndk { abiFilters += "arm64-v8a" }
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The engine, its Swift runtime and codecs, and the films and camera profiles it reads, from
    // tools/build-android-engine.sh; build output, so outside the source tree.
    sourceSets["main"].jniLibs.srcDir("../../build/android-engine/jniLibs")
    sourceSets["main"].assets.srcDir("../../build/android-engine/assets")
    // Film profiles are JSON the engine reads once unpacked; compressing them in the APK is fine.

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
