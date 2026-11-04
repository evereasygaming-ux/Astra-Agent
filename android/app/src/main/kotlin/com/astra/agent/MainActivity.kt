package com.astra.agent

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val bridgeExecutor = Executors.newSingleThreadExecutor()

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

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        if (isFinishing) {
            BridgeLauncher.stop()
            bridgeExecutor.shutdown()
        }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "com.astra.agent/bridge"
    }
}
