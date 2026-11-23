package com.example.print_app

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    companion object {
        private const val SHARE_CHANNEL = "com.example.print_app/share"
        private const val PREVIEW_CHANNEL = "com.example.print_app/pdf_preview"
    }

    private var shareChannel: MethodChannel? = null
    private var initialSharedPath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialSharedPath = extractSharedFilePath(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "getInitialSharedFile") {
                    result.success(initialSharedPath)
                    initialSharedPath = null
                } else {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PREVIEW_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "renderPdfPages") {
                val bytes = call.argument<ByteArray>("bytes")
                val maxWidth = call.argument<Int>("maxWidth") ?: 900
                if (bytes == null) {
                    result.error("INVALID_ARGS", "Missing PDF bytes", null)
                    return@setMethodCallHandler
                }
                thread {
                    try {
                        val pages = renderPdfBytes(bytes, maxWidth)
                        runOnUiThread { result.success(pages) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("RENDER_ERROR", e.message, null) }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun renderPdfBytes(pdfBytes: ByteArray, maxWidth: Int): List<ByteArray> {
        val tempFile = File.createTempFile("preview_", ".pdf", cacheDir)
        try {
            tempFile.writeBytes(pdfBytes)
            ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
                PdfRenderer(pfd).use { renderer ->
                    val images = ArrayList<ByteArray>(renderer.pageCount)
                    for (i in 0 until renderer.pageCount) {
                        renderer.openPage(i).use { page ->
                            val targetW = maxWidth.coerceAtLeast(300)
                            val targetH = ((targetW.toFloat() / page.width.coerceAtLeast(1)) * page.height)
                                .toInt()
                                .coerceAtLeast(1)
                            val bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                            try {
                                val canvas = Canvas(bitmap)
                                canvas.drawColor(Color.WHITE)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                val out = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.PNG, 90, out)
                                images.add(out.toByteArray())
                            } finally {
                                bitmap.recycle()
                            }
                        }
                    }
                    return images
                }
            }
        } finally {
            tempFile.delete()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val path = extractSharedFilePath(intent)
        if (path != null) {
            if (shareChannel != null) {
                shareChannel?.invokeMethod("onSharedFile", path)
            } else {
                initialSharedPath = path
            }
        }
    }

    private fun extractSharedFilePath(intent: Intent?): String? {
        if (intent == null) return null
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_SEND -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            }
            Intent.ACTION_VIEW -> intent.data
            else -> null
        }
        return uri?.let { copyUriToCache(it) }
    }

    private fun copyUriToCache(uri: Uri): String? {
        return try {
            val fileName = getDisplayName(uri).replace(Regex("[^A-Za-z0-9._-]"), "_")
            val destFile = File(cacheDir, "shared_${System.currentTimeMillis()}_$fileName")
            contentResolver.openInputStream(uri)?.use { input ->
                destFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            destFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun getDisplayName(uri: Uri): String {
        if (uri.scheme == "content") {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)
                        if (!name.isNullOrBlank()) return name
                    }
                }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "document.pdf"
    }
}
