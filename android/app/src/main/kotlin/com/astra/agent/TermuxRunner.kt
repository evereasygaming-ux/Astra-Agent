package com.astra.agent

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

object TermuxRunner {
    private const val TAG = "AstraTermux"
    private const val TERMUX_PACKAGE = "com.termux"
    private const val RUN_COMMAND_SERVICE = "com.termux.app.RunCommandService"
    private const val RUN_COMMAND_ACTION = "com.termux.RUN_COMMAND"
    private const val RUN_COMMAND_PERMISSION = "com.termux.permission.RUN_COMMAND"
    private const val PROOT_DISTRO = "/data/data/com.termux/files/usr/bin/proot-distro"
    private const val TERMUX_HOME = "/data/data/com.termux/files/home"
    private const val BRIDGE_ASSET = "bin/agy_ide_bridge"

    @Volatile
    private var server: ServerSocket? = null

    @Volatile
    private var serverPort: Int = 0

    fun isInstalled(context: Context): Boolean = try {
        context.packageManager.getPackageInfo(TERMUX_PACKAGE, 0)
        true
    } catch (_: Exception) {
        false
    }

    fun hasPermission(context: Context): Boolean =
        context.checkSelfPermission(RUN_COMMAND_PERMISSION) ==
            PackageManager.PERMISSION_GRANTED

    fun status(context: Context): Map<String, Any?> = mapOf(
        "installed" to isInstalled(context),
        "permission" to hasPermission(context),
        "port" to serverPort,
    )

    fun requestPermission(activity: Activity) {
        if (!isInstalled(activity) || hasPermission(activity)) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.requestPermissions(
                arrayOf(RUN_COMMAND_PERMISSION),
                PERMISSION_REQUEST,
            )
        }
    }

    fun run(context: Context, script: String, background: Boolean) {
        val intent = Intent().apply {
            component = ComponentName(TERMUX_PACKAGE, RUN_COMMAND_SERVICE)
            action = RUN_COMMAND_ACTION
            putExtra("com.termux.RUN_COMMAND_PATH", PROOT_DISTRO)
            putExtra(
                "com.termux.RUN_COMMAND_ARGUMENTS",
                arrayOf("login", "debian", "--", "/bin/bash", "-lc", script),
            )
            putExtra("com.termux.RUN_COMMAND_WORKDIR", TERMUX_HOME)
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", background)
            if (!background) {
                putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
            }
        }
        context.startService(intent)
    }

    fun open(context: Context) {
        val intent = context.packageManager.getLaunchIntentForPackage(
            TERMUX_PACKAGE,
        ) ?: throw IllegalStateException("Termux is not installed")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    fun openSettings(context: Context) {
        val intent = Intent().apply {
            component = ComponentName(
                TERMUX_PACKAGE,
                "com.termux.app.SettingsActivity",
            )
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (error: Exception) {
            Log.w(TAG, "Termux settings unavailable: ${error.message}")
            open(context)
        }
    }

    @Synchronized
    fun assetServerPort(context: Context): Int {
        val existing = server
        if (existing != null && !existing.isClosed && serverPort > 0) {
            return serverPort
        }
        val socket = ServerSocket(
            0,
            4,
            InetAddress.getByName("127.0.0.1"),
        )
        server = socket
        serverPort = socket.localPort
        val appContext = context.applicationContext
        Thread {
            while (!socket.isClosed) {
                try {
                    val client = socket.accept()
                    Thread { serve(appContext, client) }.apply {
                        isDaemon = true
                    }.start()
                } catch (_: Exception) {
                    break
                }
            }
        }.apply { isDaemon = true }.start()
        return serverPort
    }

    @Synchronized
    fun stopServer() {
        try {
            server?.close()
        } catch (_: Exception) {
            // Already closed.
        }
        server = null
        serverPort = 0
    }

    private fun serve(context: Context, client: Socket) {
        client.use { socket ->
            val reader = socket.getInputStream().bufferedReader()
            val requestLine = reader.readLine() ?: return
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) {
                    break
                }
            }
            val path = requestLine.split(" ").getOrNull(1) ?: "/"
            val output = socket.getOutputStream()
            if (path != "/agy_ide_bridge") {
                output.write(
                    (
                        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" +
                            "Connection: close\r\n\r\n"
                        ).toByteArray(),
                )
                output.flush()
                return
            }
            val binary = bridgeFile(context)
            output.write(
                (
                    "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: application/octet-stream\r\n" +
                        "Content-Length: ${binary.length()}\r\n" +
                        "Connection: close\r\n\r\n"
                    ).toByteArray(),
            )
            binary.inputStream().use { input -> input.copyTo(output) }
            output.flush()
        }
    }

    private fun bridgeFile(context: Context): File {
        val target = File(context.cacheDir, "agy_ide_bridge")
        if (target.exists() && target.length() > 0) {
            return target
        }
        val temp = File(context.cacheDir, "agy_ide_bridge.tmp")
        context.assets.open(BRIDGE_ASSET).use { input ->
            temp.outputStream().use { output -> input.copyTo(output) }
        }
        if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = true)
            temp.delete()
        }
        return target
    }

    private const val PERMISSION_REQUEST = 4101
}
