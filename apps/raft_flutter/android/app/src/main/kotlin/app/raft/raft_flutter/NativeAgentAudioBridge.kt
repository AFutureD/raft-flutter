package app.raft.raft_flutter

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicLong

/**
 * Agent mode demo audio: 16 kHz PCM16 microphone chunks out, 24 kHz PCM16
 * speech in. The microphone uses the voice-communication source with echo
 * cancellation so live mode can be interrupted while the agent speaks.
 * Also opens the QR scan used to enter the voice provider key.
 */
class NativeAgentAudioBridge(private val activity: Activity, engine: FlutterEngine) {
    companion object {
        const val PERMISSION_REQUEST = 45074
        private const val SCAN_REQUEST = 45075
        private const val MIC_RATE = 16000
        private const val SPEAKER_RATE = 24000
    }

    private val main = Handler(Looper.getMainLooper())
    private val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val methods = MethodChannel(engine.dartExecutor.binaryMessenger, "app.raft/agent-audio")
    private val micEvents = EventChannel(engine.dartExecutor.binaryMessenger, "app.raft/agent-audio/mic")

    private var sink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private var scanResult: MethodChannel.Result? = null

    @Volatile private var capturing = false
    private var recordThread: Thread? = null

    @Volatile private var track: AudioTrack? = null
    private var playThread: Thread? = null
    private val playQueue = LinkedBlockingQueue<ByteArray>()
    @Volatile private var playGeneration = 0

    // Speech still to be heard: bytes queued here plus frames handed to the
    // track that its playback head has not reached. Lets the app time a
    // visual to the moment the words before it have been spoken.
    private val queuedBytes = AtomicLong()
    @Volatile private var writtenFrames = 0L
    @Volatile private var headBase = 0L
    private var communication = false
    private var speaker = false

    // 录屏模式: speech plays as media (USAGE_MEDIA) and the call mode is not
    // entered, because Android's screen recorder cannot capture
    // voice-communication audio. The microphone stays on the
    // voice-communication source.
    @Volatile private var recording = false
    private var modeSet = false

    init {
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "permission" -> requestPermission(result)
                "play" -> {
                    enterCommunication()
                    ensureTrack()
                    val data = call.arguments as ByteArray
                    queuedBytes.addAndGet(data.size.toLong())
                    playQueue.put(data)
                    result.success(null)
                }
                "pendingMs" -> result.success(pendingMs())
                "stopPlayback" -> {
                    stopPlayback()
                    result.success(null)
                }
                "scanCode" -> scanCode(result)
                "setRecordingMode" -> {
                    val on = call.arguments == true
                    if (on != recording) {
                        recording = on
                        dropTrack()
                        if (communication) {
                            leaveCommunication()
                            if (capturing) enterCommunication()
                        }
                    }
                    result.success(null)
                }
                "setOutput" -> {
                    speaker = call.arguments == "speaker"
                    if (modeSet) routeOutput()
                    result.success(null)
                }
                "release" -> {
                    release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        micEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                startCapture()
            }

            override fun onCancel(arguments: Any?) {
                stopCapture()
                sink = null
            }
        })
    }

    private fun granted() = activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
        PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (granted()) return result.success(true)
        permissionResult?.success(false)
        permissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
    }

    fun onPermissionResult(grantResults: IntArray) {
        val pending = permissionResult ?: return
        permissionResult = null
        pending.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    private fun scanCode(result: MethodChannel.Result) {
        scanResult?.success(null)
        scanResult = result
        activity.startActivityForResult(Intent(activity, QrScanActivity::class.java), SCAN_REQUEST)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SCAN_REQUEST) return false
        val pending = scanResult ?: return true
        scanResult = null
        pending.success(if (resultCode == Activity.RESULT_OK) data?.getStringExtra(QrScanActivity.EXTRA_VALUE) else null)
        return true
    }

    // Echo cancellation works on the communication path. Speech goes to the
    // chosen earpiece or loudspeaker; a headset or other output always wins.
    private fun enterCommunication() {
        if (communication) return
        communication = true
        if (recording) {
            activity.volumeControlStream = AudioManager.STREAM_MUSIC
            return
        }
        modeSet = true
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        routeOutput()
        activity.volumeControlStream = AudioManager.STREAM_VOICE_CALL
    }

    private fun routeOutput() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audio.availableCommunicationDevices
            val external = devices.firstOrNull {
                it.type != AudioDeviceInfo.TYPE_BUILTIN_EARPIECE &&
                    it.type != AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            val builtIn = if (speaker) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            (external ?: devices.firstOrNull { it.type == builtIn })
                ?.let { audio.setCommunicationDevice(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = speaker
        }
    }

    private fun leaveCommunication() {
        if (!communication) return
        communication = false
        activity.volumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE
        if (!modeSet) return
        modeSet = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audio.clearCommunicationDevice()
        audio.mode = AudioManager.MODE_NORMAL
    }

    private fun startCapture() {
        if (capturing) return
        if (!granted()) {
            sink?.error("permission", "Microphone access was declined.", null)
            return
        }
        enterCommunication()
        capturing = true
        recordThread = Thread {
            val min = AudioRecord.getMinBufferSize(MIC_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val record = try {
                AudioRecord(
                    MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                    MIC_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(min, MIC_RATE * 2),
                )
            } catch (e: SecurityException) {
                main.post { sink?.error("permission", e.message, null) }
                capturing = false
                return@Thread
            }
            val echo = if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(record.audioSessionId) else null
            echo?.enabled = true
            val noise = if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(record.audioSessionId) else null
            noise?.enabled = true
            record.startRecording()
            // 100 ms chunks.
            val chunk = ByteArray(MIC_RATE / 10 * 2)
            while (capturing) {
                var filled = 0
                while (capturing && filled < chunk.size) {
                    val n = record.read(chunk, filled, chunk.size - filled)
                    if (n <= 0) break
                    filled += n
                }
                if (filled > 0) {
                    val out = chunk.copyOf(filled)
                    main.post { sink?.success(out) }
                }
            }
            record.stop()
            record.release()
            echo?.release()
            noise?.release()
        }.also { it.start() }
    }

    private fun stopCapture() {
        capturing = false
        recordThread?.join(500)
        recordThread = null
        if (track == null) leaveCommunication()
    }

    private fun ensureTrack() {
        if (track != null) return
        val min = AudioTrack.getMinBufferSize(SPEAKER_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val created = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(
                        if (recording) AudioAttributes.USAGE_MEDIA else AudioAttributes.USAGE_VOICE_COMMUNICATION,
                    )
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SPEAKER_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(min, SPEAKER_RATE))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track = created
        created.play()
        playThread = Thread {
            var speaking = false
            while (track === created) {
                val data = playQueue.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
                if (data != null) queuedBytes.addAndGet(-data.size.toLong())
                if (data == null) {
                    if (speaking && pendingMs() <= 0) {
                        speaking = false
                        main.post { methods.invokeMethod("playbackIdle", null) }
                    }
                    continue
                }
                val generation = playGeneration
                speaking = true
                var offset = 0
                while (offset < data.size && generation == playGeneration && track === created) {
                    val n = created.write(data, offset, data.size - offset)
                    if (n <= 0) break
                    offset += n
                    if (generation == playGeneration) writtenFrames += n / 2
                }
            }
        }.also { it.start() }
    }

    private fun stopPlayback() {
        playGeneration++
        playQueue.clear()
        queuedBytes.set(0)
        track?.let {
            it.pause()
            it.flush()
            headBase = it.playbackHeadPosition.toLong() and 0xffffffffL
            writtenFrames = 0
            it.play()
        }
    }

    private fun pendingMs(): Long {
        val t = track ?: return 0
        val played = (t.playbackHeadPosition.toLong() and 0xffffffffL) - headBase
        val frames = queuedBytes.get() / 2 + maxOf(0L, writtenFrames - played)
        return frames * 1000 / SPEAKER_RATE
    }

    // The next speech builds a new track (the usage differs by mode).
    private fun dropTrack() {
        playGeneration++
        playQueue.clear()
        queuedBytes.set(0)
        val old = track
        track = null
        playThread?.join(500)
        playThread = null
        old?.stop()
        old?.release()
    }

    private fun release() {
        stopCapture()
        playGeneration++
        playQueue.clear()
        val old = track
        track = null
        playThread?.join(500)
        playThread = null
        old?.stop()
        old?.release()
        leaveCommunication()
    }

    fun dispose() {
        release()
        methods.setMethodCallHandler(null)
        micEvents.setStreamHandler(null)
        permissionResult?.success(false)
        permissionResult = null
        scanResult?.success(null)
        scanResult = null
    }
}
