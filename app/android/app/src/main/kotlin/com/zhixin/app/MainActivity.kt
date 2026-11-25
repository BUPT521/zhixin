package com.zhixin.app

import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import kotlin.concurrent.thread

class MainActivity : FlutterFragmentActivity() {
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
