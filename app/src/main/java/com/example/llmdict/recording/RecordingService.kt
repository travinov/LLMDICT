package com.example.llmdict.recording

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import android.util.Log
import com.example.llmdict.R
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs

class RecordingService : Service() {

    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    @Volatile
    private var isRecording: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val fileName = intent?.getStringExtra(EXTRA_FILE_NAME)
            ?: "recording_${System.currentTimeMillis()}.pcm"
        val outputFile = File(filesDir, fileName)

        startForeground(NOTIFICATION_ID, buildNotification())
        startRecording(outputFile)

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRecording()
    }

    private fun startRecording(file: File) {
        val sampleRate = SAMPLE_RATE
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        
        val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        val bufferSize = if (minBufferSize > 0) minBufferSize * 2 else sampleRate * 2

        val recorder = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize
        )

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            Log.e("RecordingService", "AudioRecord not initialized")
            stopSelf()
            return
        }

        try {
            recorder.startRecording()
            Log.d("RecordingService", "AudioRecord started successfully")
        } catch (e: Exception) {
            Log.e("RecordingService", "Failed to start recording", e)
            recorder.release()
            stopSelf()
            return
        }

        audioRecord = recorder
        isRecording = true

        recordingThread = Thread {
            try {
                FileOutputStream(file).use { output ->
                    val buffer = ByteArray(bufferSize)
                    var totalBytesRead = 0L
                    while (isRecording) {
                        val read = recorder.read(buffer, 0, buffer.size)
                        if (read > 0) {
                            output.write(buffer, 0, read)
                            updateMicLevel(buffer, read)
                            totalBytesRead += read
                            
                            // Логируем каждые ~100 Кб, чтобы не спамить, но видеть прогресс
                            if (totalBytesRead % (100 * 1024) < bufferSize) {
                                Log.d("RecordingService", "Recording... bytes: $totalBytesRead")
                            }
                        } else {
                            Log.w("RecordingService", "AudioRecord read error: $read")
                            // Если постоянно ошибка - можно прерывать, но лучше подождать
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e("RecordingService", "Error saving recording", e)
            }
        }.apply { start() }
    }

    private fun stopRecording() {
        isRecording = false
        try {
            audioRecord?.apply {
                stop()
                release()
            }
        } catch (_: Exception) {
        } finally {
            audioRecord = null
            recordingThread = null
            RecordingLevelMonitor.updateLevel(0f)
        }
    }

    private fun updateMicLevel(buffer: ByteArray, bytesRead: Int) {
        if (bytesRead <= 0) {
            RecordingLevelMonitor.updateLevel(0f)
            return
        }
        var maxSample = 0
        var i = 0
        while (i + 1 < bytesRead) {
            val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)).toShort().toInt()
            val absSample = abs(sample)
            if (absSample > maxSample) maxSample = absSample
            i += 2
        }
        val normalized = maxSample / 32768f
        RecordingLevelMonitor.updateLevel(normalized)
    }

    private fun buildNotification(): Notification {
        val channelId = createNotificationChannel()
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(getString(R.string.notification_recording_title))
            .setContentText(getString(R.string.notification_recording_text))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel(): String {
        val channelId = "recording_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                getString(R.string.notification_channel_recording),
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
        return channelId
    }

    companion object {
        const val EXTRA_FILE_NAME = "extra_file_name"
        private const val NOTIFICATION_ID = 1
        const val SAMPLE_RATE = 44_100 
    }
}
