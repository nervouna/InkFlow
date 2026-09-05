plugins {
    alias(libs.plugins.android.application) apply false
}

tasks.register("verifyBuildJvm") {
    val expectedMajor = providers.gradleProperty("inkflowExpectedJavaMajor")
    inputs.property("expectedJavaMajor", expectedMajor)

    doLast {
        val expected = expectedMajor.orNull?.toIntOrNull()
            ?: throw GradleException(
                "verifyBuildJvm requires -PinkflowExpectedJavaMajor=<major>",
            )
        val actual = Runtime.version().feature()
        if (actual != expected) {
            throw GradleException(
                "Gradle build JVM major $actual does not match locked major $expected",
            )
        }
        logger.lifecycle("PASS Gradle build JVM $actual matches toolchains.lock.json")
    }
}
