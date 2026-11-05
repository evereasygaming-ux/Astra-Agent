package com.astra.agent

import android.content.Context
import android.system.Os
import android.util.Log
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import java.io.File

object ClaudeRuntime {
    private const val TAG = "AstraClaude"
    private const val GLIBC_ASSET = "glibc-min-arm64.tar"
    private const val PREFS_NAME = "astra_bridge"
    private const val PREF_GLIBC_UPDATE = "glibc_asset_update"

    fun ensure(context: Context): String {
        val glibcDir = ensureGlibc(context)
        return ensureWrapper(context, glibcDir).absolutePath
    }

    private fun ensureGlibc(context: Context): File {
        val root = File(context.filesDir, "glibc")
        val loader = File(root, "lib/ld-linux-aarch64.so.1")
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val updateTime = try {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        } catch (_: Exception) {
            0L
        }
        val needsExtract = !loader.exists() ||
            prefs.getLong(PREF_GLIBC_UPDATE, -1L) != updateTime

        if (needsExtract) {
            extractTar(context, root)
            loader.setExecutable(true, false)
            prefs.edit().putLong(PREF_GLIBC_UPDATE, updateTime).apply()
            Log.d(TAG, "glibc runtime extracted to ${root.absolutePath}")
        }

        val etc = File(root, "etc").apply { mkdirs() }
        File(etc, "nsswitch.conf").writeText(
            "hosts: files dns\nnetworks: files\nprotocols: files\nservices: files\n",
        )
        File(etc, "resolv.conf").writeText(
            "nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\n",
        )
        File(etc, "hosts").writeText("127.0.0.1 localhost\n::1 localhost\n")

        val lib = File(root, "lib")
        ensureLibraryLink(lib, "libnss_dns.so", "libnss_dns.so.2")
        ensureLibraryLink(lib, "libnss_files.so", "libnss_files.so.2")
        return root
    }

    private fun ensureWrapper(context: Context, glibcDir: File): File {
        val home = File(context.filesDir, "home").apply { mkdirs() }
        val bin = File(context.filesDir, "bin").apply { mkdirs() }
        val wrapper = File(bin, "claude")
        val versions = File(home, ".local/share/claude/versions")
        val loader = File(glibcDir, "lib/ld-linux-aarch64.so.1")
        val lib = File(glibcDir, "lib")

        val script = """
            #!/system/bin/sh
            # Claude Code launcher written by Astra Code Agent. Edits are overwritten on app start.
            VERSIONS_DIR="${versions.absolutePath}"
            GLIBC_LIB="${lib.absolutePath}"
            LOADER="${loader.absolutePath}"
            TARGET=""
            if [ -d "${'$'}VERSIONS_DIR" ]; then
                for name in ${'$'}(ls -1t "${'$'}VERSIONS_DIR" 2>/dev/null); do
                    case "${'$'}name" in
                        [0-9]*.[0-9]*.[0-9]*)
                            TARGET="${'$'}VERSIONS_DIR/${'$'}name"
                            break
                            ;;
                    esac
                done
            fi
            if [ -z "${'$'}TARGET" ]; then
                echo "Claude Code is not installed. Open Astra Code Agent > Settings > Claude Code and install it." >&2
                exit 127
            fi
            if [ ! -x "${'$'}LOADER" ]; then
                echo "The glibc runtime is missing (${'$'}LOADER). Restart Astra Code Agent to restore it." >&2
                exit 127
            fi
            unset LD_PRELOAD
            exec "${'$'}LOADER" --library-path "${'$'}GLIBC_LIB" "${'$'}TARGET" "${'$'}@"
        """.trimIndent() + "\n"

        if (!wrapper.exists() || wrapper.readText() != script) {
            val temp = File(bin, ".claude.tmp")
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
        return wrapper
    }

    private fun ensureLibraryLink(lib: File, linkName: String, target: String) {
        val link = File(lib, linkName)
        if (link.exists()) {
            return
        }
        try {
            Os.symlink(target, link.absolutePath)
        } catch (error: Exception) {
            Log.w(TAG, "Cannot create $linkName link: ${error.message}")
        }
    }

    private fun extractTar(context: Context, root: File) {
        if (root.exists()) {
            root.deleteRecursively()
        }
        root.mkdirs()
        val rootPath = root.canonicalPath

        context.assets.open(GLIBC_ASSET).use { input ->
            TarArchiveInputStream(input).use { tar ->
                var entry = tar.nextEntry
                while (entry != null) {
                    val name = entry.name
                        .removePrefix("./glibc/")
                        .removePrefix("glibc/")
                        .removePrefix("./")
                    if (name.isNotBlank() && name != "/") {
                        val target = File(root, name)
                        if (!target.canonicalPath.startsWith(rootPath)) {
                            throw IllegalStateException("Unsafe tar entry: ${entry.name}")
                        }
                        if (entry.isDirectory) {
                            target.mkdirs()
                        } else if (entry.isSymbolicLink) {
                            target.parentFile?.mkdirs()
                            if (target.exists()) {
                                target.delete()
                            }
                            Os.symlink(entry.linkName, target.absolutePath)
                        } else {
                            target.parentFile?.mkdirs()
                            target.outputStream().use { output ->
                                tar.copyTo(output)
                            }
                            target.setReadable(true, false)
                            target.setExecutable(true, false)
                        }
                    }
                    entry = tar.nextEntry
                }
            }
        }
    }
}
