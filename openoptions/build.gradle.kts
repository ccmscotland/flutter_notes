// All plugins are declared here (apply false) so that every module loads them from one classloader.
// Machines without access to Google's Maven repository use build.core-only.gradle.kts instead
// (selected by `-Popenoptions.coreOnly=true` in settings.gradle.kts).
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
