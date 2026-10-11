// Plugins are declared per module. The Android plugins are deliberately not listed here so that
// `-Popenoptions.coreOnly=true` can configure and test `:core:hidpp` on machines without Google's Maven
// repository or an Android SDK.
plugins {
    alias(libs.plugins.kotlin.jvm) apply false
}
