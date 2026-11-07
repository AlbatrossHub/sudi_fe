import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Play upload key. android/key.properties points at the keystore and is NOT in
// the repo (nor is the keystore): a signing identity in version control is a leak,
// and this one is the apps' identity on the store. A machine without the file still
// builds - it just signs with the debug key, which the store refuses.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.sudi.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // `resValue` in the flavors below needs this switched on explicitly in
    // recent AGP versions.
    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications needs java.time on older Androids.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.sudi.app"
        // flutter_secure_storage 11 and sqflite_sqlcipher both need 23+.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Decision D1: one codebase, two binaries. They share every line of
    // `lib/src/core` and differ in entry point, accent, id and store listing.
    flavorDimensions += "app"
    productFlavors {
        create("field") {
            dimension = "app"
            // Renamed for the store launch: the staff app is "Sudi Work". The
            // flavor keeps its internal name `field` so entry points, schemes
            // and build commands stay as they were.
            applicationId = "com.sudi.work"
            resValue("string", "app_name", "Sudi Work")
        }
        create("customer") {
            dimension = "app"
            applicationId = "com.sudi.customer"
            resValue("string", "app_name", "Sudi")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
