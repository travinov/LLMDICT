package com.example.llmdict.recording

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream

class PcmAudioPlayer {

    private var audioTrack: AudioTrack? = null
    private var playJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO)

    fun play(pcmFile: File, onCompletion: () -> Unit) {
        stop() // Остановить предыдущее

        if (!pcmFile.exists()) {
            onCompletion()
            return
        }

        playJob = scope.launch {
            try {
                // Синхронизируем с частотой записи (44100)
                val sampleRate = RecordingService.SAMPLE_RATE 
                
                val bufferSize = AudioTrack.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )

                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()

                audioTrack = track
                track.play()

                val buffer = ByteArray(bufferSize)
                FileInputStream(pcmFile).use { input ->
                    while (isActive) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        track.write(buffer, 0, read)
                    }
                }
                
                try {
                    track.stop()
                } catch (e: IllegalStateException) {
                    // ignore
                }
                track.release()
            } catch (e: Exception) {
                e.printStackTrace()
            } finally {
                audioTrack = null
                withContext(Dispatchers.Main) {
                    onCompletion()
                }
            }
        }
    }

    fun stop() {
        playJob?.cancel()
        playJob = null
        try {
            audioTrack?.let { track ->
                if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    track.pause()
                    track.flush()
                    track.stop()
                }
                track.release()
            }
        } catch (e: Exception) {
            // ignore state errors
        } finally {
            audioTrack = null
        }
    }
    
    fun isPlaying(): Boolean = audioTrack?.playState == AudioTrack.PLAYSTATE_PLAYING
}
