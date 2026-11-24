package com.zhixin.app

import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.result.contract.ActivityResultContracts
import com.alipay.sdk.app.EnvUtils
import com.alipay.sdk.app.PayTask
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class MainActivity : FlutterFragmentActivity() {
    private companion object {
        val alipayInProgress = AtomicBoolean(false)
    }

    private data class PendingExport(val source: File, val result: MethodChannel.Result)

    private var pendingExport: PendingExport? = null

    // 保存位置选择器改用 Activity Result API：旧的 startActivityForResult
    // 从 API 30 起已弃用，只有 ComponentActivity 才能注册这个回调。
    private val createDocument =
        registerForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
            val export = pendingExport ?: return@registerForActivityResult
            pendingExport = null
            if (uri == null) {
                export.result.success(null)
            } else {
                copyExport(export, uri)
            }
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerAlipay(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.zhixin.app/data_package")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val fileName = call.argument<String>("fileName")
                if (path == null || fileName.isNullOrBlank()) {
                    result.error("invalid_export", "缺少数据包路径或文件名", null)
                    return@setMethodCallHandler
                }
                if (pendingExport != null) {
                    result.error("export_busy", "已有数据包正在导出", null)
                    return@setMethodCallHandler
                }
                pendingExport = PendingExport(File(path), result)
                try {
                    createDocument.launch(fileName)
                } catch (error: Exception) {
                    pendingExport = null
                    result.error("export_picker_failed", "无法打开保存位置选择器", null)
                }
            }
    }

    private fun registerAlipay(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.zhixin.app/alipay")
            .setMethodCallHandler { call, result ->
                if (call.method != "pay") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val order = call.argument<String>("order")
                val sandbox = call.argument<Boolean>("sandbox")
                if (order.isNullOrBlank() || sandbox == null) {
                    result.error("invalid_payment", "缺少支付宝订单参数", null)
                    return@setMethodCallHandler
                }
                if (!alipayInProgress.compareAndSet(false, true)) {
                    result.error("payment_busy", "已有支付宝收银台正在处理付款", null)
                    return@setMethodCallHandler
                }
                thread(name = "zhixin-alipay") {
                    val checkout = runCatching {
                        EnvUtils.setEnv(
                            if (sandbox) EnvUtils.EnvEnum.SANDBOX else EnvUtils.EnvEnum.ONLINE,
                        )
                        PayTask(this).payV2(order, true)["resultStatus"]
                    }
                    runOnUiThread {
                        alipayInProgress.set(false)
                        checkout.fold(
                            onSuccess = { result.success(it) },
                            onFailure = {
                                result.error("payment_unavailable", "暂时无法打开支付宝收银台", null)
                            },
                        )
                    }
                }
            }
    }

    // 在后台线程把 zip 流式写进用户选定的位置；大包不整段读进内存。
    private fun copyExport(export: PendingExport, uri: Uri) {
        val resolver = applicationContext.contentResolver
        thread(name = "zhixin-data-export") {
            val copy =
                runCatching {
                    export.source.inputStream().use { input ->
                        val output =
                            resolver.openOutputStream(uri) ?: throw IOException("无法打开目标文件")
                        output.use { input.copyTo(it) }
                    }
                }
            if (copy.isFailure) {
                runCatching { DocumentsContract.deleteDocument(resolver, uri) }
            }
            runOnUiThread {
                copy.fold(
                    onSuccess = { export.result.success(uri.toString()) },
                    onFailure = {
                        export.result.error("export_write_failed", "无法写入所选位置", null)
                    },
                )
            }
        }
    }
}
