import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// One version for the whole project, read from the repository's VERSION file (MAJOR.MINOR.PATCH).
val projectVersion = rootProject.file("../VERSION").readText().trim()
val versionParts = projectVersion.split(".").map { it.toInt() }
require(versionParts.size == 3) { "VERSION must be MAJOR.MINOR.PATCH, got '$projectVersion'" }

// Release signing: android/keystore.properties (storeFile, storePassword, keyAlias, keyPassword),
// written by CI from encrypted secrets. Without it, local release builds use the debug keystore.
val keystoreProps = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "app.beamly.tv"
    compileSdk = 35

    defaultConfig {
        // Legacy application ID, kept so existing installs upgrade in place.
        applicationId = "com.mac2tv.receiver"
        minSdk = 26
        targetSdk = 35
        versionCode = versionParts[0] * 10_000 + versionParts[1] * 100 + versionParts[2]
        versionName = projectVersion
    }

    signingConfigs {
        create("release") {
            if (keystoreProps.isNotEmpty()) {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            } else {
                val debug = getByName("debug")
                storeFile = debug.storeFile
                storePassword = debug.storePassword
                keyAlias = debug.keyAlias
                keyPassword = debug.keyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.tv.material)
    implementation(libs.kotlinx.coroutines.android)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.json)
}

tasks.withType<Test>().configureEach {
    // Shared protocol fixtures live outside the Android project.
    inputs.dir(rootProject.file("../protocol/test-vectors"))
}
