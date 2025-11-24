package com.example.llmdict.ui.recordings

import android.app.Application
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.llmdict.data.RecordingRepository
import com.example.llmdict.data.local.RecordingEntity
import com.example.llmdict.di.AppModule
import com.example.llmdict.recording.PcmAudioPlayer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

class RecordingsViewModel(
    application: Application,
    private val repository: RecordingRepository
) : AndroidViewModel(application) {

    val recordings: StateFlow<List<RecordingEntity>> =
        repository.getRecordings()
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(5_000),
                initialValue = emptyList()
            )
            
    private val _playingRecordingId = MutableStateFlow<Long?>(null)
    val playingRecordingId: StateFlow<Long?> = _playingRecordingId.asStateFlow()

    private val player = PcmAudioPlayer()

    fun transcribe(entity: RecordingEntity) {
        viewModelScope.launch {
            repository.transcribeBySettings(entity)
        }
    }
    
    fun delete(entity: RecordingEntity) {
        stopPlayback()
        viewModelScope.launch {
            repository.deleteRecording(entity)
        }
    }
    
    fun togglePlayback(entity: RecordingEntity) {
        if (_playingRecordingId.value == entity.localId) {
            stopPlayback()
        } else {
            playRecording(entity)
        }
    }
    
    private fun playRecording(entity: RecordingEntity) {
        val file = File(entity.filePath)
        if (file.exists()) {
            _playingRecordingId.value = entity.localId
            player.play(file) {
                _playingRecordingId.value = null
            }
        }
    }
    
    fun stopPlayback() {
        player.stop()
        _playingRecordingId.value = null
    }
    
    override fun onCleared() {
        super.onCleared()
        player.stop()
    }
}

@Composable
fun rememberRecordingsViewModel(): RecordingsViewModel {
    val context = LocalContext.current.applicationContext as Application
    val repository = AppModule.provideRecordingRepository(context)
    return androidx.lifecycle.viewmodel.compose.viewModel(
        factory = RecordingsViewModelFactory(context, repository)
    )
}

class RecordingsViewModelFactory(
    private val application: Application,
    private val repository: RecordingRepository
) : androidx.lifecycle.ViewModelProvider.Factory {
    override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T {
        if (modelClass.isAssignableFrom(RecordingsViewModel::class.java)) {
            @Suppress("UNCHECKED_CAST")
            return RecordingsViewModel(application, repository) as T
        }
        throw IllegalArgumentException("Unknown ViewModel class")
    }
}
