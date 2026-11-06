package com.astra.agent

import android.content.Context
import android.os.Build
import android.os.StatFs
import android.system.Os
import android.util.Log
import java.io.BufferedInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.TimeZone
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import org.apache.commons.compress.compressors.xz.XZCompressorInputStream
import org.json.JSONObject

object LinuxRuntime {
    private const val TAG = "AstraLinux"
    private const val ROOTFS_URL =
        "https://github.com/termux/proot-distro/releases/download/v4.29.0/debian-trixie-aarch64-pd-v4.29.0.tar.xz"
    private const val ROOTFS_SHA256 =
        "3834a11cbc6496935760bdc20cca7e2c25724d0cd8f5e4926da8fd5ca1857918"
    private const val AGY_MANIFEST_URL =
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"
    private const val BRIDGE_ASSET = "bin/agy_ide_bridge"
    private const val PREFS_NAME = "astra_linux"
    private const val PREF_PROOT_UPDATE = "proot_asset_update"
    private const val PREF_BRIDGE_UPDATE = "bridge_asset_update"
    private const val PREF_ROOTFS_SHA = "rootfs_sha"
    private const val PREF_AGY_VERSION = "agy_version"
    private const val MIN_FREE_BYTES = 1_200L * 1024 * 1024
    private const val MAX_LOG_LINES = 400
    private const val MAX_OUTPUT = 200_000

    private val busy = AtomicBoolean(false)
    private val lock = Any()
    private val logs = ArrayDeque<String>()
    private val bridgeLogs = ArrayDeque<String>()

    @Volatile
    private var phase = "idle"

    @Volatile
    private var progress = 0L

    @Volatile
    private var total = 0L

    @Volatile
    private var lastError: String? = null

    @Volatile
    private var bridgeProcess: Process? = null

    @Volatile
    private var bridgePid = 0L

    fun status(context: Context): Map<String, Any?> {
        val proot = prootFile(context)
        val rootfs = rootfsDir(context)
        val agy = agyFile(context)
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val freeBytes = try {
            StatFs(linuxDir(context).absolutePath).availableBytes
        } catch (_: Exception) {
            0L
        }
        return mapOf(
            "installed" to (proot.exists() && File(rootfs, "etc/debian_version").exists()),
            "proot" to proot.exists(),
            "rootfs" to File(rootfs, "etc/debian_version").exists(),
            "rootfsPath" to rootfs.absolutePath,
            "rootfsSha" to prefs.getString(PREF_ROOTFS_SHA, ""),
            "agyInstalled" to (agy.exists() && agy.length() > 50L * 1024 * 1024),
            "agyVersion" to prefs.getString(PREF_AGY_VERSION, ""),
            "agySize" to agy.length(),
            "bridgeRunning" to (bridgeProcess?.isAlive == true),
            "bridgePid" to bridgePid,
            "busy" to busy.get(),
            "phase" to phase,
            "progress" to progress,
            "total" to total,
            "freeBytes" to freeBytes,
            "log" to synchronized(lock) { logs.joinToString("\n") },
            "bridgeLog" to synchronized(lock) { bridgeLogs.joinToString("\n") },
            "error" to lastError,
        )
    }

    fun install(context: Context): Map<String, Any?> {
        if (!busy.compareAndSet(false, true)) {
            throw IllegalStateException("Linux setup is already running")
        }
        lastError = null
        phase = "starting"
        progress = 0L
        total = 0L
        try {
            log("Preparing in-app Linux runtime")
            ensureDirs(context)
            checkFreeSpace(context)
            ensureProot(context)
            ensureRootfs(context)
            phase = "ready"
            log("Linux runtime is ready")
            return status(context)
        } catch (error: Exception) {
            lastError = error.message ?: error.toString()
            phase = "error"
            log("Linux setup failed: $lastError")
            throw error
        } finally {
            busy.set(false)
        }
    }

    fun installAgy(context: Context): Map<String, Any?> {
        if (!busy.compareAndSet(false, true)) {
            throw IllegalStateException("Linux setup is already running")
        }
        lastError = null
        phase = "agy"
        progress = 0L
        total = 0L
        try {
            requireRuntime(context)
            ensureDirs(context)
            ensureHome(context)
            val target = agyFile(context)
            if (bridgeProcess?.isAlive == true) {
                throw IllegalStateException("Stop the Linux bridge before installing AGY")
            }
            val manifest = fetchManifest()
            val version = manifest.optString("version")
            val url = manifest.optString("url")
            val sha512 = manifest.optString("sha512")
            if (version.isBlank() || url.isBlank() || sha512.isBlank()) {
                throw IllegalStateException("AGY release manifest is incomplete")
            }
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (
                target.exists() &&
                target.length() > 50L * 1024 * 1024 &&
                prefs.getString(PREF_AGY_VERSION, "") == version
            ) {
                log("AGY $version is already installed")
                phase = "ready"
                return status(context)
            }
            val archive = File(cacheDir(context), "agy-$version.pkg")
            if (!archive.exists() || digest(archive, "SHA-512") != sha512.lowercase()) {
                archive.delete()
                checkFreeSpace(context)
                log("Downloading AGY $version")
                download(url, archive, "SHA-512", sha512, "AGY $version")
            } else {
                log("Using cached AGY $version package")
            }
            log("Installing AGY $version inside Debian")
            if (url.endsWith(".tar.gz", ignoreCase = true)) {
                extractAgy(archive, target)
            } else {
                installAgyFile(archive, target)
            }
            archive.delete()
            prefs.edit().putString(PREF_AGY_VERSION, version).apply()
            writeShellProfile(context)
            phase = "ready"
            log("AGY $version installed at /root/.local/bin/agy")
            return status(context)
        } catch (error: Exception) {
            lastError = error.message ?: error.toString()
            phase = "error"
            log("AGY install failed: $lastError")
            throw error
        } finally {
            busy.set(false)
        }
    }

    fun runShell(context: Context, command: String, timeoutSeconds: Int = 600): Map<String, Any?> {
        if (command.isBlank()) {
            throw IllegalArgumentException("command is required")
        }
        if (busy.get()) {
            throw IllegalStateException("Linux setup is still running")
        }
        requireRuntime(context)
        ensureDirs(context)
        ensureHome(context)
        val args = prootArgs(
            context,
            listOf(
                "/usr/bin/env",
                "-i",
                "HOME=/root",
                "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM=xterm-256color",
                "LANG=C.UTF-8",
                "/bin/bash",
                "-lc",
                command,
            ),
        )
        log("Running command inside Debian")
        return execute(context, args, timeoutSeconds)
    }

    fun startBridge(
        context: Context,
        token: String?,
        port: Int,
        hubPort: Int,
        workspace: String?,
    ): Map<String, Any?> {
        if (busy.get()) {
            throw IllegalStateException("Linux setup is still running")
        }
        requireRuntime(context)
        ensureDirs(context)
        ensureHome(context)
        val agy = agyFile(context)
        if (!agy.exists()) {
            throw IllegalStateException("Install AGY inside Linux first")
        }
        val bridgeToken = token
            ?.takeIf { it.matches(Regex("^[0-9a-z]{12}$")) }
            ?: throw IllegalArgumentException("token must be 12 lowercase characters")
        if (port !in 1..65535 || hubPort !in 1..65535 || port == hubPort) {
            throw IllegalArgumentException("invalid bridge ports")
        }
        stopBridge()
        ensureBridge(context)
        val hostWorkspace = workspace
            ?.takeIf { it.isNotBlank() }
            ?.let { File(it) }
            ?: File(homeDir(context), "projects")
        hostWorkspace.mkdirs()
        val tzOffset = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000
        val args = prootArgs(
            context,
            listOf(
                "/usr/bin/env",
                "-i",
                "HOME=/root",
                "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM=xterm-256color",
                "LANG=C.UTF-8",
                bridgeGuestPath,
                "-f",
                "--no-claude",
                "--bin",
                "/root/.local/bin/agy",
                "--token",
                bridgeToken,
                "-p",
                port.toString(),
                "--hub-port",
                hubPort.toString(),
                "--tz-offset",
                tzOffset.toString(),
                "--dir",
                "/workspace",
            ),
            workspace = hostWorkspace,
        )
        val builder = ProcessBuilder(args)
            .directory(rootfsDir(context))
            .redirectErrorStream(true)
        prepareEnvironment(builder, context)
        val started = builder.start()
        synchronized(lock) {
            bridgeProcess = started
            bridgePid = started.safePid()
            bridgeLogs.clear()
            bridgeLogs.addLast("Linux bridge started on 127.0.0.1:$port (pid $bridgePid)")
        }
        Thread {
            try {
                started.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        synchronized(lock) {
                            bridgeLogs.addLast(line)
                            while (bridgeLogs.size > MAX_LOG_LINES) {
                                bridgeLogs.removeFirst()
                            }
                        }
                    }
                }
            } catch (_: Exception) {
            }
            val code = try {
                started.waitFor()
            } catch (_: InterruptedException) {
                -1
            }
            synchronized(lock) {
                bridgeLogs.addLast("Linux bridge exited (code $code)")
                while (bridgeLogs.size > MAX_LOG_LINES) {
                    bridgeLogs.removeFirst()
                }
                if (bridgeProcess === started) {
                    bridgeProcess = null
                    bridgePid = 0L
                    if (code != 0) {
                        lastError = "Linux bridge exited with code $code"
                    }
                }
            }
        }.apply { isDaemon = true }.start()
        log("Linux bridge started on port $port")
        return status(context)
    }

    fun stopBridge(): Map<String, Any?> {
        val running = synchronized(lock) {
            val current = bridgeProcess
            bridgeProcess = null
            bridgePid = 0L
            current
        }
        if (running != null) {
            try {
                running.destroy()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    if (!running.waitFor(3, TimeUnit.SECONDS)) {
                        running.destroyForcibly()
                    }
                } else {
                    running.waitFor()
                }
            } catch (_: Exception) {
            }
            synchronized(lock) {
                bridgeLogs.addLast("Linux bridge stopped")
            }
        }
        return mapOf("running" to false)
    }

    private fun requireRuntime(context: Context) {
        val rootfs = rootfsDir(context)
        if (!File(rootfs, "etc/debian_version").exists()) {
            throw IllegalStateException("Install the in-app Linux runtime first")
        }
        ensureProot(context)
    }

    private fun ensureDirs(context: Context) {
        listOf(
            linuxDir(context),
            prootDir(context),
            libDir(context),
            rootfsDir(context),
            homeDir(context),
            tmpDir(context),
            cacheDir(context),
        ).forEach {
            it.mkdirs()
            it.setReadable(true, false)
            it.setExecutable(true, false)
        }
    }

    private fun ensureProot(context: Context) {
        ensureDirs(context)
        val target = prootFile(context)
        val talloc = File(libDir(context), "libtalloc.so.2")
        val shmem = File(libDir(context), "libandroid-shmem.so")
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val updateTime = packageUpdateTime(context)
        val needsCopy = !target.exists() ||
            target.length() == 0L ||
            !talloc.exists() ||
            !shmem.exists() ||
            prefs.getLong(PREF_PROOT_UPDATE, -1L) != updateTime
        if (needsCopy) {
            copyAsset(context, "linux/proot", target, executable = true)
            copyAsset(context, "linux/libtalloc.so.2", talloc, executable = false)
            copyAsset(context, "linux/libandroid-shmem.so", shmem, executable = false)
            prefs.edit().putLong(PREF_PROOT_UPDATE, updateTime).apply()
            log("proot runtime extracted")
        }
        target.setReadable(true, false)
        target.setExecutable(true, false)
    }

    private fun ensureRootfs(context: Context) {
        val rootfs = rootfsDir(context)
        val marker = File(rootfs, ".astra-rootfs-sha")
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (
            marker.exists() &&
            marker.readText().trim() == ROOTFS_SHA256 &&
            File(rootfs, "etc/debian_version").exists()
        ) {
            log("Debian rootfs is already installed")
            return
        }
        val archive = File(cacheDir(context), "rootfs.tar.xz")
        if (!archive.exists() || digest(archive, "SHA-256") != ROOTFS_SHA256) {
            archive.delete()
            checkFreeSpace(context)
            log("Downloading Debian 13 rootfs")
            download(ROOTFS_URL, archive, "SHA-256", ROOTFS_SHA256, "Debian rootfs")
        } else {
            log("Using cached Debian rootfs")
        }
        phase = "extracting"
        progress = 0L
        total = 0L
        try {
            log("Extracting Debian rootfs")
            extractRootfs(archive, rootfs)
            flattenSingleRoot(rootfs)
            configureRootfs(context, rootfs)
            marker.writeText(ROOTFS_SHA256)
            prefs.edit().putString(PREF_ROOTFS_SHA, ROOTFS_SHA256).apply()
            archive.delete()
            log("Debian rootfs installed")
        } catch (error: Exception) {
            rootfs.deleteRecursively()
            throw error
        }
    }

    private fun ensureHome(context: Context) {
        val home = homeDir(context)
        home.mkdirs()
        home.setReadable(true, false)
        home.setExecutable(true, false)
        listOf(
            ".local/bin",
            ".cache",
            ".config",
            ".gemini/antigravity-cli",
            ".antigem_bridge",
            "projects",
        ).forEach { File(home, it).mkdirs() }
        writeShellProfile(context)
    }

    private fun writeShellProfile(context: Context) {
        val home = homeDir(context)
        val profile = "export PATH=\"/root/.local/bin:\$PATH\"\n"
        listOf(".bashrc", ".profile").forEach { name ->
            val file = File(home, name)
            if (!file.exists()) {
                file.writeText(profile)
            } else if (!file.readText().contains("/root/.local/bin")) {
                file.appendText(profile)
            }
            file.setReadable(true, false)
        }
    }

    private fun ensureBridge(context: Context): File {
        val target = File(rootfsDir(context), "opt/astra/agy_ide_bridge")
        target.parentFile?.mkdirs()
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val updateTime = packageUpdateTime(context)
        if (
            !target.exists() ||
            target.length() == 0L ||
            prefs.getLong(PREF_BRIDGE_UPDATE, -1L) != updateTime
        ) {
            copyAsset(context, BRIDGE_ASSET, target, executable = true)
            prefs.edit().putLong(PREF_BRIDGE_UPDATE, updateTime).apply()
        }
        target.setReadable(true, false)
        target.setExecutable(true, false)
        return target
    }

    private fun copyAsset(context: Context, asset: String, target: File, executable: Boolean) {
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, ".${target.name}.tmp")
        temp.delete()
        context.assets.open(asset).use { input ->
            temp.outputStream().use { output ->
                input.copyTo(output, 64 * 1024)
            }
        }
        temp.setReadable(true, false)
        if (executable) {
            temp.setExecutable(true, false)
        }
        target.delete()
        if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = true)
            temp.delete()
        }
        target.setReadable(true, false)
        if (executable) {
            target.setExecutable(true, false)
        }
    }

    private fun configureRootfs(context: Context, rootfs: File) {
        val etc = File(rootfs, "etc").apply { mkdirs() }
        writeResolvConf(etc)
        val hosts = File(etc, "hosts")
        hosts.delete()
        hosts.writeText("127.0.0.1 localhost\n::1 localhost\n")
        val hostname = File(etc, "hostname")
        hostname.delete()
        hostname.writeText("astra\n")
        listOf("dev", "proc", "sys", "tmp", "root", "workspace", "opt/astra").forEach {
            File(rootfs, it).mkdirs()
        }
        ensureHome(context)
        listOf(etc, File(rootfs, "root"), File(rootfs, "workspace"), File(rootfs, "tmp"))
            .forEach {
                it.setReadable(true, false)
                it.setExecutable(true, false)
            }
    }

    private fun writeResolvConf(etc: File) {
        val resolv = File(etc, "resolv.conf")
        resolv.delete()
        resolv.writeText(
            "nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\n",
        )
        resolv.setReadable(true, false)
    }

    private fun extractRootfs(archive: File, target: File) {
        target.deleteRecursively()
        target.mkdirs()
        val rootPath = target.canonicalPath
        XZCompressorInputStream(
            BufferedInputStream(archive.inputStream(), 64 * 1024),
        ).use { xz ->
            TarArchiveInputStream(xz).use { tar ->
                var entry = tar.nextEntry
                var count = 0
                while (entry != null) {
                    val name = entry.name.removePrefix("./")
                    if (name.isBlank() || name == "/" || name == ".") {
                        entry = tar.nextEntry
                        continue
                    }
                    val dest = File(target, name)
                    val canonical = dest.canonicalPath
                    if (
                        canonical != rootPath &&
                        !canonical.startsWith(rootPath + File.separator)
                    ) {
                        throw IllegalStateException("Unsafe rootfs entry: ${entry.name}")
                    }
                    when {
                        entry.isDirectory -> {
                            dest.mkdirs()
                            setMode(dest, entry.mode, directory = true)
                        }
                        entry.isSymbolicLink -> {
                            dest.parentFile?.mkdirs()
                            dest.delete()
                            try {
                                Os.symlink(entry.linkName, dest.absolutePath)
                            } catch (_: Exception) {
                            }
                        }
                        entry.isLink -> {
                            dest.parentFile?.mkdirs()
                            dest.delete()
                            val source = File(target, entry.linkName.removePrefix("./"))
                            try {
                                Os.link(source.absolutePath, dest.absolutePath)
                            } catch (_: Exception) {
                                try {
                                    Os.symlink(source.absolutePath, dest.absolutePath)
                                } catch (_: Exception) {
                                }
                            }
                        }
                        entry.isFile -> {
                            dest.parentFile?.mkdirs()
                            dest.outputStream().use { output ->
                                tar.copyTo(output, 64 * 1024)
                            }
                            setMode(dest, entry.mode, directory = false)
                        }
                    }
                    count++
                    if (count % 4000 == 0) {
                        progress = count.toLong()
                        log("Extracted $count rootfs entries")
                    }
                    entry = tar.nextEntry
                }
            }
        }
    }

    private fun flattenSingleRoot(root: File) {
        if (File(root, "etc").exists()) {
            return
        }
        val children = root.listFiles()?.filter { !it.name.startsWith(".") } ?: return
        val only = children.singleOrNull() ?: return
        if (!only.isDirectory || !File(only, "etc").exists()) {
            return
        }
        val nested = only.listFiles() ?: return
        for (child in nested) {
            val target = File(root, child.name)
            if (target.exists()) {
                target.deleteRecursively()
            }
            if (!child.renameTo(target)) {
                throw IllegalStateException("Cannot normalize rootfs layout")
            }
        }
        only.delete()
    }

    private fun setMode(file: File, mode: Int, directory: Boolean) {
        var permissions = mode and 0x1FF
        if (permissions == 0) {
            permissions = if (directory) 0x1ED else 0x1A4
        }
        try {
            Os.chmod(file.absolutePath, permissions)
        } catch (_: Exception) {
            file.setReadable(true, false)
            if (directory || (permissions and 0x49) != 0) {
                file.setExecutable(true, false)
            }
        }
    }

    private fun installAgyFile(source: File, target: File) {
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, ".agy.tmp")
        temp.delete()
        source.inputStream().use { input ->
            temp.outputStream().use { output ->
                input.copyTo(output, 64 * 1024)
            }
        }
        installAgyTemp(temp, target)
    }

    private fun extractAgy(archive: File, target: File) {
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, ".agy.tmp")
        temp.delete()
        var found = false
        GzipCompressorInputStream(
            BufferedInputStream(archive.inputStream(), 64 * 1024),
        ).use { gzip ->
            TarArchiveInputStream(gzip).use { tar ->
                var entry = tar.nextEntry
                while (entry != null) {
                    if (!entry.isDirectory) {
                        val name = entry.name.removePrefix("./")
                        if (
                            name == "antigravity" ||
                            name == "agy" ||
                            name.endsWith("/antigravity") ||
                            name.endsWith("/agy")
                        ) {
                            temp.outputStream().use { output ->
                                tar.copyTo(output, 64 * 1024)
                            }
                            found = true
                            break
                        }
                    }
                    entry = tar.nextEntry
                }
            }
        }
        if (!found) {
            throw IllegalStateException("AGY binary not found in package")
        }
        installAgyTemp(temp, target)
    }

    private fun installAgyTemp(temp: File, target: File) {
        if (temp.length() < 50L * 1024 * 1024) {
            temp.delete()
            throw IllegalStateException("Downloaded AGY binary is too small")
        }
        temp.setReadable(true, false)
        temp.setExecutable(true, false)
        target.delete()
        if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = true)
            temp.delete()
        }
        target.setReadable(true, false)
        target.setExecutable(true, false)
    }

    private fun fetchManifest(): JSONObject {
        val connection = (URL(AGY_MANIFEST_URL).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15000
            readTimeout = 15000
            setRequestProperty("User-Agent", "AstraCodeAgent/Android")
            instanceFollowRedirects = true
        }
        try {
            val code = connection.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("AGY manifest request failed ($code)")
            }
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            return JSONObject(body)
        } finally {
            connection.disconnect()
        }
    }

    private fun download(
        url: String,
        target: File,
        algorithm: String,
        expected: String,
        label: String,
    ) {
        val temp = File(target.parentFile, ".${target.name}.part")
        temp.delete()
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30000
            readTimeout = 60000
            setRequestProperty("User-Agent", "AstraCodeAgent/Android")
            instanceFollowRedirects = true
        }
        try {
            val code = connection.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("$label download failed ($code)")
            }
            total = connection.contentLengthLong.takeIf { it > 0 } ?: 0L
            progress = 0L
            val digest = MessageDigest.getInstance(algorithm)
            var read = 0L
            var logged = 0L
            connection.inputStream.use { input ->
                temp.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) {
                            break
                        }
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        read += count
                        progress = read
                        if (read - logged >= 10L * 1024 * 1024) {
                            logged = read
                            log("$label: ${read / (1024 * 1024)} MB downloaded")
                        }
                    }
                }
            }
            val actual = hex(digest.digest())
            if (!actual.equals(expected, ignoreCase = true)) {
                temp.delete()
                throw IllegalStateException("$label checksum mismatch")
            }
            target.delete()
            if (!temp.renameTo(target)) {
                temp.copyTo(target, overwrite = true)
                temp.delete()
            }
            log("$label download complete")
        } finally {
            connection.disconnect()
        }
    }

    private fun execute(
        context: Context,
        command: List<String>,
        timeoutSeconds: Int,
    ): Map<String, Any?> {
        val builder = ProcessBuilder(command)
            .directory(rootfsDir(context))
            .redirectErrorStream(true)
        prepareEnvironment(builder, context)
        val process = builder.start()
        val output = StringBuilder()
        val reader = Thread {
            try {
                process.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        synchronized(output) {
                            if (output.length < MAX_OUTPUT) {
                                output.append(line).append('\n')
                            }
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true }
        reader.start()
        val finished = process.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)
        if (!finished) {
            process.destroyForcibly()
            process.waitFor(2, TimeUnit.SECONDS)
        }
        reader.join(2000)
        val text = synchronized(output) { output.toString() }
        return mapOf(
            "exitCode" to if (finished) process.exitValue() else -1,
            "timedOut" to !finished,
            "output" to text,
        )
    }

    private fun prepareEnvironment(builder: ProcessBuilder, context: Context) {
        val environment = builder.environment()
        environment["HOME"] = homeDir(context).absolutePath
        environment["TMPDIR"] = tmpDir(context).absolutePath
        environment["LD_LIBRARY_PATH"] = libDir(context).absolutePath
        environment["PROOT_TMP_DIR"] = tmpDir(context).absolutePath
        environment.remove("LD_PRELOAD")
    }

    private fun prootArgs(
        context: Context,
        inner: List<String>,
        workspace: File? = null,
    ): List<String> {
        val rootfs = rootfsDir(context)
        val home = homeDir(context).apply { mkdirs() }
        val work = (workspace ?: File(home, "projects")).apply { mkdirs() }
        val tmp = tmpDir(context).apply { mkdirs() }
        val args = mutableListOf(
            prootFile(context).absolutePath,
            "--kill-on-exit",
            "--link2symlink",
            "--sysvipc",
            "-0",
            "-r",
            rootfs.absolutePath,
            "-w",
            "/root",
            "--bind=/dev",
            "--bind=/proc",
            "--bind=/sys",
        )
        listOf("/apex", "/system", "/system_ext", "/vendor", "/product", "/odm").forEach {
            val path = File(it)
            if (path.exists() && path.canRead()) {
                args.add("--bind=$it")
            }
        }
        args.add("--bind=${home.absolutePath}:/root")
        args.add("--bind=${tmp.absolutePath}:/tmp")
        args.add("--bind=${work.absolutePath}:/workspace")
        args.addAll(inner)
        return args
    }

    private fun checkFreeSpace(context: Context) {
        val directory = linuxDir(context).apply { mkdirs() }
        val free = StatFs(directory.absolutePath).availableBytes
        if (free < MIN_FREE_BYTES) {
            throw IllegalStateException(
                "Not enough free space: ${free / (1024 * 1024)} MB available, " +
                    "at least ${MIN_FREE_BYTES / (1024 * 1024)} MB required",
            )
        }
    }

    private fun digest(file: File, algorithm: String): String {
        val digest = MessageDigest.getInstance(algorithm)
        file.inputStream().use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) {
                    break
                }
                digest.update(buffer, 0, count)
            }
        }
        return hex(digest.digest())
    }

    private fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            out.append("0123456789abcdef"[value ushr 4])
            out.append("0123456789abcdef"[value and 0x0F])
        }
        return out.toString()
    }

    private fun packageUpdateTime(context: Context): Long = try {
        context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
    } catch (_: Exception) {
        0L
    }

    private fun Process.safePid(): Long = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Process::class.java.getMethod("pid").invoke(this) as? Long ?: 0L
        } else {
            0L
        }
    } catch (_: Exception) {
        0L
    }

    private fun log(message: String) {
        synchronized(lock) {
            logs.addLast(message)
            while (logs.size > MAX_LOG_LINES) {
                logs.removeFirst()
            }
        }
        Log.d(TAG, message)
    }

    private fun linuxDir(context: Context): File = File(context.filesDir, "linux")

    private fun prootDir(context: Context): File = File(linuxDir(context), "bin")

    private fun libDir(context: Context): File = File(linuxDir(context), "lib")

    private fun rootfsDir(context: Context): File = File(linuxDir(context), "rootfs")

    private fun homeDir(context: Context): File = File(linuxDir(context), "home")

    private fun tmpDir(context: Context): File = File(linuxDir(context), "tmp")

    private fun cacheDir(context: Context): File = File(linuxDir(context), "cache")

    private fun prootFile(context: Context): File = File(prootDir(context), "proot")

    private fun agyFile(context: Context): File =
        File(File(homeDir(context), ".local/bin"), "agy")

    private const val bridgeGuestPath = "/opt/astra/agy_ide_bridge"
}
