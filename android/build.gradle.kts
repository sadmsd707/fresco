allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Fix third-party plugins missing 'namespace' (required by AGP 8+).
    // pluginManager.withPlugin fires when the plugin is applied (during evaluation),
    // so it runs before evaluationDependsOn completes.
    pluginManager.withPlugin("com.android.library") {
        val android = extensions.getByType<com.android.build.gradle.LibraryExtension>()
        if (android.namespace.isNullOrEmpty()) {
            val manifest = file("src/main/AndroidManifest.xml")
            if (manifest.exists()) {
                val pkg = Regex("""package\s*=\s*"([^"]+)"""")
                    .find(manifest.readText())?.groupValues?.get(1)
                if (!pkg.isNullOrEmpty()) {
                    android.namespace = pkg
                    println("Auto-set namespace for ${project.name}: $pkg")
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
