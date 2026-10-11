// Root build script used when `-Popenoptions.coreOnly=true`: only the pure-Kotlin core is configured,
// so neither the Android Gradle plugin nor Google's Maven repository is needed.
plugins {
    alias(libs.plugins.kotlin.jvm) apply false
}
