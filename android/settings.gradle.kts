pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Androp"
include(":app")

// Optional, dependency-free app for testing native drags across a real app boundary.
include(":drag-source")
project(":drag-source").projectDir = file("drag-source")
