package com.astra.agent

import android.content.Intent
import android.net.Uri
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val bridgeExecutor = Executors.newSingleThreadExecutor()
    private val installExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> bridgeExecutor.execute {
                        try {
                            val token = call.argument<String>("token")
                            val port = call.argument<Int>("port") ?: 1234
                            val hubPort = call.argument<Int>("hubPort") ?: 1235
                            val workspace = call.argument<String>("workspace")
                            val status = BridgeLauncher.start(
                                applicationContext,
                                token,
                                port,
                                hubPort,
                                workspace,
                            )
                            runOnUiThread { result.success(status) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("start_failed", error.message, null)
                            }
                        }
                    }

                    "stop" -> bridgeExecutor.execute {
                        val status = BridgeLauncher.stop()
                        runOnUiThread { result.success(status) }
                    }

                    "status" -> result.success(BridgeLauncher.status())
                    "token" -> result.success(BridgeLauncher.token(applicationContext))
                    "logs" -> result.success(BridgeLauncher.logs())
                    "clearLogs" -> {
                        BridgeLauncher.clearLogs()
                        result.success(null)
                    }

                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad_url", "url is required", null)
                        } else {
                            try {
                                startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                                result.success(true)
                            } catch (error: Exception) {
                                result.error("open_failed", error.message, null)
                            }
                        }
                    }

                    "getBridgeConfig" -> {
                        result.success(readBridgeConfig())
                    }

                    "getChatHistory" -> {
                        val historyFile = File(filesDir, CHAT_HISTORY_FILE)
                        result.success(if (historyFile.exists()) historyFile.readText() else "[]")
                    }

                    "saveChatHistory" -> {
                        val json = call.argument<String>("json")
                        if (json == null) {
                            result.error("bad_history", "json is required", null)
                        } else {
                            try {
                                val historyFile = File(filesDir, CHAT_HISTORY_FILE)
                                val tempFile = File(filesDir, "$CHAT_HISTORY_FILE.tmp")
                                tempFile.writeText(json)
                                if (!tempFile.renameTo(historyFile)) {
                                    tempFile.copyTo(historyFile, overwrite = true)
                                    tempFile.delete()
                                }
                                result.success(true)
                            } catch (error: Exception) {
                                result.error("save_history_failed", error.message, null)
                            }
                        }
                    }

                    "setBridgeConfig" -> {
                        val mode = call.argument<String>("mode") ?: "external"
                        val url = call.argument<String>("url") ?: ""
                        val token = call.argument<String>("token") ?: ""
                        getSharedPreferences(PREFS, MODE_PRIVATE)
                            .edit()
                            .putString("mode", mode)
                            .putString("url", url)
                            .putString("token", token)
                            .apply()
                        result.success(readBridgeConfig())
                    }

                    "termuxStatus" -> {
                        result.success(TermuxRunner.status(applicationContext))
                    }

                    "termuxRequestPermission" -> {
                        TermuxRunner.requestPermission(this)
                        result.success(true)
                    }

                    "termuxRun" -> {
                        val script = call.argument<String>("script")
                        val background =
                            call.argument<Boolean>("background") ?: false
                        if (script.isNullOrBlank()) {
                            result.error("bad_script", "script is required", null)
                        } else {
                            try {
                                TermuxRunner.run(
                                    applicationContext,
                                    script,
                                    background,
                                )
                                result.success(true)
                            } catch (error: Exception) {
                                result.error(
                                    "termux_run_failed",
                                    error.message,
                                    null,
                                )
                            }
                        }
                    }

                    "termuxOpen" -> {
                        try {
                            TermuxRunner.open(applicationContext)
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("termux_open_failed", error.message, null)
                        }
                    }

                    "termuxOpenSettings" -> {
                        try {
                            TermuxRunner.openSettings(applicationContext)
                            result.success(true)
                        } catch (error: Exception) {
                            result.error(
                                "termux_settings_failed",
                                error.message,
                                null,
                            )
                        }
                    }

                    "termuxAssetPort" -> {
                        try {
                            result.success(
                                TermuxRunner.assetServerPort(applicationContext),
                            )
                        } catch (error: Exception) {
                            result.error(
                                "termux_asset_failed",
                                error.message,
                                null,
                            )
                        }
                    }

                    "agyStatus" -> {
                        try {
                            result.success(AgyRuntime.status(applicationContext))
                        } catch (error: Exception) {
                            result.error("agy_status_failed", error.message, null)
                        }
                    }

                    "agyInstall" -> installExecutor.execute {
                        try {
                            val status = AgyRuntime.install(applicationContext)
                            runOnUiThread { result.success(status) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("agy_install_failed", error.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        if (isFinishing) {
            BridgeLauncher.stop()
            TermuxRunner.stopServer()
            bridgeExecutor.shutdown()
        }
        super.onDestroy()
    }

    private fun readBridgeConfig(): Map<String, Any?> {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        return mapOf(
            "mode" to prefs.getString("mode", "external"),
            "url" to prefs.getString("url", "http://127.0.0.1:1234"),
            "token" to prefs.getString("token", ""),
        )
    }

    companion object {
        private const val CHANNEL = "com.astra.agent/bridge"
        private const val PREFS = "astra_bridge"
        private const val CHAT_HISTORY_FILE = "chat_history.json"
    }
}
