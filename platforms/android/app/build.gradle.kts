import javax.inject.Inject
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction

abstract class StageSchemaAssetsTask @Inject constructor(
    private val fileSystem: FileSystemOperations,
) : DefaultTask() {
    @get:InputDirectory
    abstract val sourceDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun stage() {
        val expected = setOf("default.yaml", "inkflow.schema.yaml", "inkflow.dict.yaml")
        val actual = sourceDirectory.get().asFile.listFiles()
            ?.filter(File::isFile)
            ?.map(File::getName)
            ?.toSet()
            .orEmpty()
        require(actual == expected) {
            "Canonical Android schema sources differ from the locked file set: $actual"
        }

        fileSystem.sync {
            from(sourceDirectory) {
                include(expected)
                into("inkflow-schema")
            }
            into(outputDirectory)
        }
    }
}

plugins {
    alias(libs.plugins.android.application)
}

val repositoryRoot = rootProject.layout.projectDirectory.dir("../..")
val dependencyCachePath = repositoryRoot.dir("build/dependencies").asFile
    .toPath()
    .toAbsolutePath()
    .normalize()
    .toString()
val nativeBuildPythonPath = repositoryRoot.file("tools/build/python-isolated").asFile
    .toPath()
    .toAbsolutePath()
    .normalize()
    .toString()
val stageSchemaAssets by tasks.registering(StageSchemaAssetsTask::class) {
    sourceDirectory.set(repositoryRoot.dir("schemas/source"))
    outputDirectory.set(layout.buildDirectory.dir("generated/inkflow/assets"))
}

android {
    namespace = "io.damao.inkflow"
    compileSdk = libs.versions.compile.sdk.get().toInt()
    ndkVersion = libs.versions.ndk.get()

    defaultConfig {
        applicationId = "io.damao.inkflow"
        minSdk = libs.versions.min.sdk.get().toInt()
        targetSdk = libs.versions.target.sdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DBUILD_TESTING=OFF",
                    "-DINKFLOW_BUILD_APPLE_PACKAGING_TOOLS=OFF",
                    "-DINKFLOW_DEPENDENCY_CACHE_DIR=$dependencyCachePath",
                    "-DPYTHON_EXECUTABLE=$nativeBuildPythonPath",
                    "-DCMAKE_C_FLAGS=",
                    "-DCMAKE_CXX_FLAGS=",
                    "-DCMAKE_EXE_LINKER_FLAGS=",
                    "-DCMAKE_MODULE_LINKER_FLAGS=",
                    "-DCMAKE_SHARED_LINKER_FLAGS=",
                    "-DCMAKE_STATIC_LINKER_FLAGS=",
                    "-DCMAKE_C_COMPILER_LAUNCHER=",
                    "-DCMAKE_CXX_COMPILER_LAUNCHER=",
                    "-DCMAKE_C_LINKER_LAUNCHER=",
                    "-DCMAKE_CXX_LINKER_LAUNCHER=",
                    "-DCMAKE_MODULE_PATH=",
                    "-DCMAKE_PREFIX_PATH=",
                    "-DCMAKE_PROJECT_INCLUDE=",
                    "-DCMAKE_PROJECT_INCLUDE_BEFORE=",
                    "-DCMAKE_PROJECT_InkFlow_INCLUDE=",
                    "-DCMAKE_PROJECT_InkFlow_INCLUDE_BEFORE=",
                    "-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=",
                    "-DCMAKE_USER_MAKE_RULES_OVERRIDE=",
                    "-DCMAKE_USER_MAKE_RULES_OVERRIDE_C=",
                    "-DCMAKE_USER_MAKE_RULES_OVERRIDE_CXX=",
                )
                targets += "inkflow_android_jni"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    externalNativeBuild {
        cmake {
            path = repositoryRoot.file("CMakeLists.txt").asFile
            version = libs.versions.cmake.get()
        }
    }
}

androidComponents {
    onVariants(selector().all()) { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            stageSchemaAssets,
            StageSchemaAssetsTask::outputDirectory,
        )
    }
}

dependencies {
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
}
