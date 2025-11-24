package com.example.llmdict.ui.record

import android.app.Application
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.llmdict.data.RecordingRepository
import com.example.llmdict.di.AppModule
import com.example.llmdict.recording.RecordingService
import com.example.llmdict.recording.RecordingLevelMonitor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File

class RecordViewModel(
    application: Application,
    private val repository: RecordingRepository
) : AndroidViewModel(application) {

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording

    private val _status = MutableStateFlow("Готов к записи")
    val status: StateFlow<String> = _status

    val micLevel: StateFlow<Float> = RecordingLevelMonitor.level

    private var currentFile: File? = null

    fun onPermissionDenied() {
        _status.value = "Нет доступа к микрофону"
    }

    fun startRecording() {
        if (_isRecording.value) return
        val context = getApplication<Application>()
        val fileName = "recording_${System.currentTimeMillis()}.pcm"
        currentFile = File(context.filesDir, fileName)

        val intent = Intent(context, RecordingService::class.java).apply {
            putExtra(RecordingService.EXTRA_FILE_NAME, fileName)
        }
        context.startForegroundService(intent)
        _isRecording.value = true
        _status.value = "Идёт запись…"
    }

    fun stopRecording() {
        if (!_isRecording.value) return
        val context = getApplication<Application>()
        val intent = Intent(context, RecordingService::class.java)
        context.stopService(intent)
        _isRecording.value = false
        _status.value = "Запись завершена"

        val file = currentFile ?: return
        viewModelScope.launch {
            repository.createLocalRecording(
                title = "Запись ${System.currentTimeMillis()}",
                filePath = file.absolutePath
            )
        }
    }
}

@Composable
fun rememberRecordViewModel(): RecordViewModel {
    val context = LocalContext.current.applicationContext as Application
    val repository = AppModule.provideRecordingRepository(context)
    return androidx.lifecycle.viewmodel.compose.viewModel(
        factory = RecordViewModelFactory(context, repository)
    )
}

class RecordViewModelFactory(
    private val application: Application,
    private val repository: RecordingRepository
) : androidx.lifecycle.ViewModelProvider.Factory {
    override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T {
        if (modelClass.isAssignableFrom(RecordViewModel::class.java)) {
            @Suppress("UNCHECKED_CAST")
            return RecordViewModel(application, repository) as T
        }
        throw IllegalArgumentException("Unknown ViewModel class")
    }
}
