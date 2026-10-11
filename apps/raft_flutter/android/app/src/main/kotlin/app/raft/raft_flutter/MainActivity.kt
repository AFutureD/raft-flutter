package app.raft.raft_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import androidx.core.content.IntentCompat
import java.util.ArrayDeque
import android.os.Build
import android.content.Intent
import android.net.Uri
import java.io.File

class MainActivity : FlutterActivity() {
    private var shareReceiverReady = false
    private val earlyShares = ArrayDeque<Intent>()
    private var sharing: NativeSharingBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        prepareSharedUris(intent)
        super.onCreate(savedInstanceState)
        // Flutter switches to NormalTheme before first paint. Restore the
        // selected brand background synchronously for that startup interval.
        window.setBackgroundDrawableResource(AppIconPalette.background(this))
        consumeShare(intent)
    }

    // receive_intent forwards extras, but not ClipData. Normalize URI references
    // only: no file queries, copies, or binary data are processed here.
    private fun prepareSharedUris(intent: Intent) {
        if (intent.action !in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) {
            intent.action = Intent.ACTION_MAIN
            return
        }
        try {
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.let { text ->
                if (text.length > 65536) { intent.action = Intent.ACTION_MAIN; return }
                intent.putExtra(Intent.EXTRA_TEXT, text.toString())
            }
            val streams = if (intent.action == Intent.ACTION_SEND_MULTIPLE)
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
            else listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            val clips = intent.clipData?.let { clip ->
                (0 until minOf(clip.itemCount, 11)).mapNotNull { clip.getItemAt(it).uri }
            } ?: emptyList()
            intent.putStringArrayListExtra("app.raft.sharedUris", ArrayList((streams + clips).distinct().map { it.toString() }))
        } catch (_: Exception) { intent.action = Intent.ACTION_MAIN }
    }

    private fun consumeShare(intent: Intent) {
        if (intent.action in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            intent.action = Intent.ACTION_MAIN
            intent.removeExtra(Intent.EXTRA_STREAM)
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra("app.raft.sharedUris")
            intent.clipData = null
        }
    }

    private fun shareReceiverAttached() {
        shareReceiverReady = true
        while (earlyShares.isNotEmpty()) dispatchNewIntent(earlyShares.removeFirst())
    }

    private fun dispatchNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeShare(intent)
    }
    private var systemFonts: NativeSystemFontsBridge? = null
    private var saveResult: MethodChannel.Result? = null
    private val saveRequest = 45071
    private val localNetworkRequest = 45072
    private val localNetworkResults = mutableListOf<MethodChannel.Result>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sharing = NativeSharingBridge(this, flutterEngine, ::shareReceiverAttached)
        systemFonts = NativeSystemFontsBridge(this, flutterEngine)
        NativePdfPreviewBridge(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.raft/local-network")
            .setMethodCallHandler { call, result ->
                if (call.method != "ensure") {
                    result.notImplemented()
                } else if (Build.VERSION.SDK_INT < 37 ||
                    checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED) {
                    result.success(true)
                } else if (call.argument<Boolean>("request") != true) {
                    result.success(false)
                } else {
                    localNetworkResults.add(result)
                    if (localNetworkResults.size == 1) {
                        requestPermissions(arrayOf(Manifest.permission.ACCESS_LOCAL_NETWORK), localNetworkRequest)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.raft/attachment-files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "chooseSave" -> {
                        if (saveResult != null) {
                            result.error("busy", "A document picker is already open.", null)
                        } else {
                            saveResult = result
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = call.argument<String>("mimeType") ?: "application/octet-stream"
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("filename") ?: "attachment")
                            }
                            try { startActivityForResult(intent, saveRequest) }
                            catch (_: Exception) {
                                saveResult = null
                                result.error("unavailable", "No document picker is available.", null)
                            }
                        }
                    }
                    "writeSaved" -> {
                        val uri = call.argument<String>("uri")
                        val path = call.argument<String>("path")
                        if (uri == null || path == null ||
                            !File(path).canonicalPath.startsWith(cacheDir.canonicalPath + File.separator)) {
                            result.error("invalid", "Invalid temporary attachment file.", null)
                        } else {
                            Thread {
                                try {
                                    contentResolver.openOutputStream(Uri.parse(uri), "wt").use { output ->
                                        requireNotNull(output)
                                        File(path).inputStream().use { input -> input.copyTo(output) }
                                    }
                                    runOnUiThread { result.success(null) }
                                } catch (_: Exception) {
                                    runOnUiThread { result.error("save_failed", "The attachment could not be saved.", null) }
                                }
                            }.start()
                        }
                    }
                    "openSaved" -> {
                        try {
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(Uri.parse(call.argument<String>("uri")),
                                    call.argument<String>("mimeType") ?: "application/octet-stream")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("no_viewer", "No application can open this file.", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        prepareSharedUris(intent)
        if (!shareReceiverReady && intent.action in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            earlyShares.addLast(intent)
            return
        }
        dispatchNewIntent(intent)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        systemFonts?.configurationChanged()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == localNetworkRequest) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            val pending = localNetworkResults.toList()
            localNetworkResults.clear()
            pending.forEach { it.success(granted) }
        }
    }

    override fun onDestroy() {
        earlyShares.clear()
        sharing?.dispose()
        systemFonts?.dispose()
        localNetworkResults.forEach { it.success(false) }
        localNetworkResults.clear()
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (sharing?.onActivityResult(requestCode) == true) return
        if (requestCode == saveRequest) {
            val pending = saveResult
            saveResult = null
            pending?.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
        } else { super.onActivityResult(requestCode, resultCode, data) }
    }
}
