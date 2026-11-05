import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

val kerdlyVersion: String = providers.gradleProperty("KERDLY_VERSION").get()

group = "com.kerdly"
version = kerdlyVersion

android {
    namespace = "com.kerdly.sdk"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "KERDLY_VERSION", "\"$kerdlyVersion\"")
    }

    buildFeatures {
        buildConfig = true
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

    testOptions {
        unitTests.all {
            // The contract tests read the golden fixtures straight from spec/ (never a copy).
            it.systemProperty("kerdly.specDir", rootProject.file("../spec").absolutePath)
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        // The SDK never throws into the host app. Without these, a Java caller passing null to a
        // non-null parameter (e.g. handleUrl(intent.getDataString())) would hit Kotlin's
        // generated null check before the SDK's own try/catch.
        freeCompilerArgs.addAll("-Xno-param-assertions", "-Xno-call-assertions", "-Xno-receiver-assertions")
    }
}

dependencies {
    implementation("com.android.installreferrer:installreferrer:2.2")
    implementation("com.google.android.gms:play-services-ads-identifier:18.0.1")

    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub in local unit tests; this is the reference implementation.
    testImplementation("org.json:json:20180813")
}

// Maven Central: ./gradlew :kerdly-sdk:publishToMavenCentral (CI, on a release tag). Needs the
// Gradle properties mavenCentralUsername / mavenCentralPassword (a Central Portal user token) and
// signingInMemoryKey / signingInMemoryKeyPassword (an armored GPG key), usually as
// ORG_GRADLE_PROJECT_* environment variables.
mavenPublishing {
    publishToMavenCentral()
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
    coordinates("com.kerdly", "kerdly-sdk", kerdlyVersion)
    pom {
        name.set("Kerdly Android SDK")
        description.set("Kerdly SDK for Android: first-party install attribution, deep links, events and purchases.")
        inceptionYear.set("2026")
        url.set("https://github.com/Kerdly/kerdly-sdk")
        licenses {
            license {
                name.set("MIT License")
                url.set("https://opensource.org/licenses/MIT")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("kerdly")
                name.set("Kerdly")
                url.set("https://kerdly.com")
            }
        }
        scm {
            url.set("https://github.com/Kerdly/kerdly-sdk")
            connection.set("scm:git:https://github.com/Kerdly/kerdly-sdk.git")
            developerConnection.set("scm:git:ssh://git@github.com/Kerdly/kerdly-sdk.git")
        }
    }
}

publishing {
    repositories {
        // ./gradlew :kerdly-sdk:publishAllPublicationsToLocalRepoRepository → android/build/repo
        maven {
            name = "localRepo"
            url = uri(rootProject.layout.buildDirectory.dir("repo"))
        }
    }
}
