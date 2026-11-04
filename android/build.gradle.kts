// AGP 8.13 + Kotlin 2.1.20. Kotlin stays on the toolchain React Native 0.86 builds with
// (Kotlin 2.1.20), so the AAR never pulls a newer kotlin-stdlib or metadata version into an
// app compiled with an older Kotlin.
plugins {
    id("com.android.library") version "8.13.0" apply false
    id("org.jetbrains.kotlin.android") version "2.1.20" apply false
    // Maven Central (Central Portal) publishing and signing.
    id("com.vanniktech.maven.publish") version "0.34.0" apply false
}
