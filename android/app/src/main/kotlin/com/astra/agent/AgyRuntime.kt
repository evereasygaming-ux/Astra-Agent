package com.astra.agent

import android.content.Context
import android.util.Log
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

object AgyRuntime {
    private const val TAG = "AstraAgy"
    private const val UPDATE_URL =
        "https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/api/update/linux-arm64/stable/latest"

    fun binDir(context: Context): File =
        File(File(context.filesDir, "home").apply { mkdirs() }, ".local/bin").apply { mkdirs() }

    fun wrapperFile(context: Context): File = File(binDir(context), "agy")

    fun realFile(context: Context): File = File(binDir(context), "agy.va39")

    fun isInstalled(context: Context): Boolean {
        val real = realFile(context)
        return real.exists() && real.length() >= 10 * 1024 * 1024
    }

    fun status(context: Context): Map<String, Any?> {
        val real = realFile(context)
        val wrapper = wrapperFile(context)
        return mapOf(
            "installed" to isInstalled(context),
            "path" to real.absolutePath,
            "size" to real.length(),
            "wrapper" to wrapper.exists(),
        )
    }

    fun ensureWrapper(context: Context): String? {
        if (!isInstalled(context)) {
            return null
        }
        val glibc = File(context.filesDir, "glibc")
        val loader = File(glibc, "lib/ld-linux-aarch64.so.1")
        val lib = File(glibc, "lib")
        val real = realFile(context)
        val wrapper = wrapperFile(context)

        val script = """
            #!/system/bin/sh
            # AGY launcher written by AstraAgent. Edits are overwritten on app start.
            REAL="${real.absolutePath}"
            GLIBC_LIB="${lib.absolutePath}"
            LOADER="${loader.absolutePath}"
            if [ ! -f "${'$'}REAL" ]; then
                echo "AGY daemon is not installed. Open AstraAgent > Settings > AGY and install it." >&2
                exit 127
            fi
            if [ ! -x "${'$'}LOADER" ]; then
                echo "The glibc runtime is missing (${'$'}LOADER). Restart AstraAgent to restore it." >&2
                exit 127
            fi
            unset LD_PRELOAD
            exec "${'$'}LOADER" --library-path "${'$'}GLIBC_LIB" "${'$'}REAL" "${'$'}@"
        """.trimIndent() + "\n"

        if (!wrapper.exists() || wrapper.readText() != script) {
            val temp = File(wrapper.parentFile, ".agy.tmp")
            temp.writeText(script)
            temp.setReadable(true, false)
            temp.setExecutable(true, false)
            if (wrapper.exists()) {
                wrapper.delete()
            }
            if (!temp.renameTo(wrapper)) {
                temp.copyTo(wrapper, overwrite = true)
                temp.delete()
            }
        }
        wrapper.setReadable(true, false)
        wrapper.setExecutable(true, false)
        return wrapper.absolutePath
    }

    fun resolveArchiveUrl(): String {
        val connection = (URL(UPDATE_URL).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15000
            readTimeout = 15000
            setRequestProperty("User-Agent", "AstraAgent/Android")
        }
        try {
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(body)
            val url = json.optString("url")
            if (url.isBlank()) {
                throw IllegalStateException("No download URL in updater response")
            }
            return url
        } finally {
            connection.disconnect()
        }
    }

    fun install(context: Context): Map<String, Any?> {
        val url = resolveArchiveUrl()
        Log.d(TAG, "Downloading AGY archive from $url")
        val tmpDir = File(context.filesDir, "tmp").apply { mkdirs() }
        val archive = File(tmpDir, "agy-download.tar.gz")
        archive.delete()

        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30000
            readTimeout = 120000
            setRequestProperty("User-Agent", "AstraAgent/Android")
            instanceFollowRedirects = true
        }
        try {
            connection.inputStream.use { input ->
                archive.outputStream().use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                }
            }
        } finally {
            connection.disconnect()
        }
        Log.d(TAG, "Downloaded ${archive.length()} bytes")

        val real = extractLanguageServer(context, archive)
        archive.delete()
        ensureWrapper(context)
        return status(context) + ("installed" to true)
    }

    private fun extractLanguageServer(context: Context, archive: File): File {
        val dir = binDir(context)
        val target = File(dir, "agy.va39")
        val temp = File(dir, ".agy.va39.tmp")
        temp.delete()

        val gzip = GzipCompressorInputStream(archive.inputStream())
        TarArchiveInputStream(gzip).use { tar ->
            var entry = tar.nextEntry
            var found = false
            while (entry != null) {
                val name = entry.name.trimStart('.', '/')
                val isLanguageServer = name.endsWith("resources/bin/language_server") ||
                    name == "language_server" ||
                    name == "bin/language_server"
                if (!entry.isDirectory && isLanguageServer) {
                    temp.outputStream().use { output ->
                        tar.copyTo(output, bufferSize = 64 * 1024)
                    }
                    found = true
                    break
                }
                entry = tar.nextEntry
            }
            if (!found) {
                throw IllegalStateException("language_server not found in archive")
            }
        }

        if (temp.length() < 10 * 1024 * 1024) {
            throw IllegalStateException("Extracted language_server is too small")
        }
        if (target.exists()) {
            target.delete()
        }
        if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = true)
        }
        temp.delete()
        target.setReadable(true, false)
        target.setExecutable(true, false)
        Log.d(TAG, "AGY daemon installed at ${target.absolutePath} (${target.length()} bytes)")
        return target
    }
}
