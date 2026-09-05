package io.damao.inkflow.engine

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

internal object SchemaAssets {
    private const val ASSET_DIRECTORY = "inkflow-schema"
    private val expectedFiles = setOf(
        "default.yaml",
        "inkflow.schema.yaml",
        "inkflow.dict.yaml",
    )

    data class Paths(
        val shared: File,
        val user: File,
        val prebuilt: File,
        val staging: File,
    )

    fun install(context: Context): Paths {
        val packagedFiles = context.assets.list(ASSET_DIRECTORY)?.toSet().orEmpty()
        require(packagedFiles == expectedFiles) {
            "Packaged schema assets differ from the locked file set"
        }

        val root = File(context.noBackupFilesDir, "rime")
        val shared = File(root, "shared")
        val user = File(root, "user")
        val prebuilt = File(root, "prebuilt")
        val staging = File(root, "staging")
        listOf(shared, user, prebuilt, staging).forEach { directory ->
            check(directory.mkdirs() || directory.isDirectory) {
                "Could not create an InkFlow data directory"
            }
        }

        expectedFiles.sorted().forEach { name ->
            val destination = File(shared, name)
            val temporary = File(shared, ".$name.tmp")
            context.assets.open("$ASSET_DIRECTORY/$name").use { input ->
                FileOutputStream(temporary, false).use { output ->
                    input.copyTo(output)
                    output.fd.sync()
                }
            }
            replaceAtomically(temporary, destination)
        }

        return Paths(
            shared = shared,
            user = user,
            prebuilt = prebuilt,
            staging = staging,
        )
    }

    private fun replaceAtomically(source: File, destination: File) {
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }
    }
}
