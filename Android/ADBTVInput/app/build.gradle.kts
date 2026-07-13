plugins {
    id("com.android.application")
}

android {
    namespace = "com.maxduke.adbtv.input"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.maxduke.adbtv.input"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
