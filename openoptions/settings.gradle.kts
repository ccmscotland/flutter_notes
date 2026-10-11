val coreOnly = providers.gradleProperty("openoptions.coreOnly").orNull == "true"

pluginManagement {
    repositories {
        if (providers.gradleProperty("openoptions.coreOnly").orNull != "true") google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        if (coreOnly.not()) google()
        mavenCentral()
    }
}
rootProject.name = "openoptions"
if (coreOnly) rootProject.buildFileName = "build.core-only.gradle.kts"
include(":core:hidpp")
// `./gradlew -Popenoptions.coreOnly=true :core:hidpp:test` builds the pure-Kotlin core without the Android app.
if (!coreOnly) {
    include(":app")
}
