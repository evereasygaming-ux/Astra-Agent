package com.astra.agent

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.TimeZone
import java.util.concurrent.TimeUnit

object BridgeLauncher {
    private const val TAG = "AstraBridge"
    private const val ASSET_PATH = "bin/agy_ide_bridge"
    private const val MAX_LOG_LINES = 300
    private const val PREFS_NAME = "astra_bridge"
    private const val PREF_ASSET_UPDATE = "asset_update"
    private const val PREF_TOKEN = "bridge_token"
    private const val TOKEN_CHARSET = "0123456789abcdefghijklmnopqrstuvwxyz"

    private val lock = Any()
    private val logs = ArrayDeque<String>()
    private val random = SecureRandom()

    @Volatile
    private var process: Process? = null

    @Volatile
    private var port: Int = 1234

    @Volatile
    private var processPid: Long = 0L

    @Volatile
    private var lastError: String? = null

    fun start(
        context: Context,
        token: String?,
        port: Int,
        hubPort: Int,
        workspace: String?,
    ): Map<String, Any?> = synchronized(lock) {
        stopLocked()

        val bridgeToken = token
            ?.takeIf { it.matches(Regex("^[0-9a-z]{12}$")) }
            ?: tokenLocked(context)
        val binary = ensureBinary(context)
        val claudeBin = ClaudeRuntime.ensure(context)
        val home = File(context.filesDir, "home").apply { mkdirs() }
        val projects = File(home, "projects").apply { mkdirs() }
        val tmp = File(context.filesDir, "tmp").apply { mkdirs() }
        File(home, ".gemini/antigravity-cli").mkdirs()
        File(home, ".antigem_bridge").mkdirs()

        val workDir = workspace
            ?.takeIf { it.isNotBlank() }
            ?.let { File(it) }
            ?: projects
        workDir.mkdirs()

        val tzOffset = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000
        val command = listOf(
            binary.absolutePath,
            "-f",
            "--no-hub",
            "--claude-bin",
            claudeBin,
            "--token",
            bridgeToken,
            "-p",
            port.toString(),
            "--hub-port",
            hubPort.toString(),
            "--tz-offset",
            tzOffset.toString(),
            "--dir",
            workDir.absolutePath,
        )

        val builder = ProcessBuilder(command)
            .directory(workDir)
            .redirectErrorStream(true)
        builder.environment()["HOME"] = home.absolutePath
        builder.environment()["TMPDIR"] = tmp.absolutePath
        builder.environment()["PATH"] = "/system/bin:/system/xbin:/vendor/bin"

        val started = builder.start()
        process = started
        this.port = port
        processPid = started.safePid().takeIf { it > 0 } ?: findBridgePid(binary)
        lastError = null
        appendLog("Bridge started (pid $processPid) on 127.0.0.1:$port")

        Thread {
            try {
                started.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        appendLog(line)
                        Log.d(TAG, line)
                    }
                }
            } catch (error: Exception) {
                appendLog("log reader stopped: ${error.message}")
            }
            val code = try {
                started.waitFor()
            } catch (_: InterruptedException) {
                -1
            }
            appendLog("Bridge exited (code $code)")
            synchronized(lock) {
                if (process === started) {
                    process = null
                    if (code != 0) {
                        lastError = "Bridge exited with code $code"
                    }
                }
            }
        }.apply { isDaemon = true }.start()

        statusLocked()
    }

    fun stop(): Map<String, Any?> = synchronized(lock) {
        stopLocked()
        statusLocked()
    }

    fun status(): Map<String, Any?> = synchronized(lock) { statusLocked() }

    fun token(context: Context): String = synchronized(lock) { tokenLocked(context) }

    fun logs(): String = synchronized(lock) { logs.joinToString("\n") }

    fun clearLogs() = synchronized(lock) { logs.clear() }

    private fun stopLocked() {
        val running = process ?: return
        process = null
        appendLog("Stopping bridge (pid $processPid)")
        processPid = 0L
        try {
            running.destroy()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (!running.waitFor(2, TimeUnit.SECONDS)) {
                    running.destroyForcibly()
                }
            } else {
                running.waitFor()
            }
        } catch (_: Exception) {
        }
    }

    private fun statusLocked(): Map<String, Any?> {
        val running = process
        val alive = running != null
        return mapOf(
            "running" to alive,
            "pid" to if (alive) processPid else 0L,
            "port" to port,
            "log" to logs.joinToString("\n"),
            "error" to lastError,
        )
    }

    private fun findBridgePid(binary: File): Long {
        val proc = File("/proc")
        val entries = proc.listFiles() ?: return 0L
        for (entry in entries) {
            if (!entry.isDirectory || entry.name.toLongOrNull() == null) {
                continue
            }
            try {
                val cmdline = File(entry, "cmdline").readText()
                if (cmdline.contains(binary.absolutePath)) {
                    return entry.name.toLong()
                }
            } catch (_: Exception) {
            }
        }
        return 0L
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

    private fun appendLog(line: String) {
        synchronized(lock) {
            logs.addLast(line)
            while (logs.size > MAX_LOG_LINES) {
                logs.removeFirst()
            }
        }
    }

    private fun tokenLocked(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existing = prefs.getString(PREF_TOKEN, null)
        if (existing != null && existing.matches(Regex("^[0-9a-z]{12}$"))) {
            return existing
        }
        val created = buildString(12) {
            repeat(12) {
                append(TOKEN_CHARSET[random.nextInt(TOKEN_CHARSET.length)])
            }
        }
        prefs.edit().putString(PREF_TOKEN, created).apply()
        return created
    }

    private fun ensureBinary(context: Context): File {
        val binDir = File(context.filesDir, "bin").apply { mkdirs() }
        val target = File(binDir, "agy_ide_bridge")
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val updateTime = try {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        } catch (_: Exception) {
            0L
        }
        val needsCopy = !target.exists() ||
            target.length() == 0L ||
            prefs.getLong(PREF_ASSET_UPDATE, -1L) != updateTime

        if (!needsCopy) {
            return target
        }

        val temp = File(binDir, ".agy_ide_bridge.tmp")
        context.assets.open(ASSET_PATH).use { input ->
            temp.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        temp.setReadable(true, false)
        temp.setExecutable(true, false)

        if (target.exists() && !target.delete()) {
            throw IllegalStateException("Cannot replace bridge binary")
        }
        if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = true)
            temp.delete()
        }
        target.setReadable(true, false)
        target.setExecutable(true, false)
        prefs.edit().putLong(PREF_ASSET_UPDATE, updateTime).apply()
        appendLog("Bridge binary extracted (${target.length()} bytes)")
        return target
    }
}
