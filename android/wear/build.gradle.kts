plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.androp.watch"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.androp"
        minSdk = 30
        targetSdk = 35
        versionCode = 14
        versionName = "3.2.2"
    }
    sourceSets.named("main") {
        res.srcDir("../signal/src/main/res")
        assets.srcDir("../signal/src/main/assets")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("com.google.android.gms:play-services-wearable:19.0.0")
}
