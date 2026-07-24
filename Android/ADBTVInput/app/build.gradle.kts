plugins {
    id("com.android.application")
}

android {
    namespace = "com.maxduke.adbtv.helper.v3"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.maxduke.adbtv.helper.v3"
        minSdk = 26
        targetSdk = 36
        versionCode = 5
        versionName = "1.3.1"
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
