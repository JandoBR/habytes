allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// The Nix dev shell provides exactly one NDK, and Gradle cannot download the
// one Flutter prefers into the read-only store. Use whichever is there, in the
// app and in every plugin.
val nixNdkVersion: String? =
    System.getenv("ANDROID_HOME")
        ?.let { file("$it/ndk").listFiles()?.firstOrNull { ndk -> ndk.isDirectory }?.name }
if (nixNdkVersion != null) {
    subprojects {
        afterEvaluate {
            extensions.findByName("android")?.let { android ->
                android.javaClass
                    .getMethod("setNdkVersion", String::class.java)
                    .invoke(android, nixNdkVersion)
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
