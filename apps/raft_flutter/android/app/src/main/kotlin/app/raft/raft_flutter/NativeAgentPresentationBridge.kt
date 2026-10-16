package app.raft.raft_flutter

import android.app.Activity
import android.app.Presentation
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.WindowInsets
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/// Agent mode on an external display (wired HDMI or a wireless display that
/// Android exposes as a presentation display). A second Flutter engine runs
/// `agentTvMain` inside an Android [Presentation]; the phone engine stays the
/// controller and sends the front layer as JSON. Nothing runs unless agent
/// mode asks for it.
private const val TAG = "AgentPresentation"

class NativeAgentPresentationBridge(private val activity: Activity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "app.raft/agent-presentation")
    private val displays = activity.getSystemService(DisplayManager::class.java)
    private var presentation: Presentation? = null
    private var tvEngine: FlutterEngine? = null
    private var tvChannel: MethodChannel? = null
    private var lastFrame: Any? = null

    private val listener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = channel.invokeMethod("displaysChanged", null)
        override fun onDisplayRemoved(displayId: Int) {
            if (presentation?.display?.displayId == displayId) hide()
            channel.invokeMethod("displaysChanged", null)
        }
        override fun onDisplayChanged(displayId: Int) {}
    }

    init {
        displays?.registerDisplayListener(listener, Handler(Looper.getMainLooper()))
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "displays" -> result.success(
                    presentationDisplays().map {
                        mapOf("id" to it.displayId, "name" to it.name)
                    },
                )
                "show" -> {
                    val display = displays?.getDisplay(call.argument<Int>("id") ?: -1)
                    if (display == null) result.success(false) else {
                        show(display)
                        result.success(true)
                    }
                }
                "frame" -> {
                    lastFrame = call.arguments
                    tvChannel?.invokeMethod("frame", lastFrame)
                    result.success(tvChannel != null)
                }
                "hide" -> { hide(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    // Some vendor desktop modes (e.g. Motorola Ready For) put the external
    // display in its own display group, and the presentation category can
    // come back empty even though the display carries FLAG_PRESENTATION.
    private fun presentationDisplays(): List<Display> {
        val dm = displays ?: return emptyList()
        val listed = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION).toList()
        val all = dm.displays.toList()
        Log.i(TAG, "displays: presentation=${listed.map { it.displayId }} all=${all.map { "${it.displayId}:${it.flags}:${it.name}" }}")
        if (listed.isNotEmpty()) return listed
        return all.filter {
            it.displayId != Display.DEFAULT_DISPLAY &&
                (it.flags and Display.FLAG_PRESENTATION) != 0
        }
    }

    private fun show(display: Display) {
        if (presentation?.display?.displayId == display.displayId) return
        hide()
        val engine = FlutterEngine(activity)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "package:raft_flutter/features/agent_mode/agent_tv.dart",
                "agentTvMain",
            ),
        )
        engine.lifecycleChannel.appIsResumed()
        val tv = MethodChannel(engine.dartExecutor.binaryMessenger, "app.raft/agent-presentation-tv")
        // The TV engine asks for the latest frame once its handler is ready.
        tv.setMethodCallHandler { call, result ->
            if (call.method == "ready") result.success(lastFrame) else result.notImplemented()
        }
        tvEngine = engine
        tvChannel = tv
        presentation = object : Presentation(activity, display) {
            override fun onCreate(savedInstanceState: Bundle?) {
                super.onCreate(savedInstanceState)
                val view = FlutterView(context)
                setContentView(view)
                view.attachToFlutterEngine(engine)
                window?.let { w ->
                    w.setDecorFitsSystemWindows(false)
                    w.insetsController?.hide(WindowInsets.Type.systemBars())
                }
            }
        }.also {
            try {
                it.show()
                Log.i(TAG, "presentation shown on display ${display.displayId}")
            } catch (e: Exception) {
                Log.w(TAG, "presentation failed on display ${display.displayId}", e)
            }
        }
    }

    fun hide() {
        presentation?.dismiss()
        presentation = null
        tvChannel = null
        tvEngine?.destroy()
        tvEngine = null
    }

    fun dispose() {
        displays?.unregisterDisplayListener(listener)
        hide()
    }
}
