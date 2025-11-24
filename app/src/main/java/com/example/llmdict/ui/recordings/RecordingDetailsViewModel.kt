package com.example.llmdict.ui.recordings

import android.app.Application
import android.content.Intent
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.example.llmdict.data.RecordingRepository
import com.example.llmdict.data.local.RecordingEntity
import com.example.llmdict.di.AppModule
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File

class RecordingDetailsViewModel(
    application: Application,
    private val repository: RecordingRepository,
    private val recordingId: Long
) : AndroidViewModel(application) {

    private val _recording = MutableStateFlow<RecordingEntity?>(null)
    val recording: StateFlow<RecordingEntity?> = _recording

    init {
        viewModelScope.launch {
            _recording.value = repository.getRecordingById(recordingId)
        }
    }
    
    fun shareText(text: String) {
        val sendIntent: Intent = Intent().apply {
            action = Intent.ACTION_SEND
            putExtra(Intent.EXTRA_TEXT, text)
            type = "text/plain"
        }
        val shareIntent = Intent.createChooser(sendIntent, null)
        shareIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        getApplication<Application>().startActivity(shareIntent)
    }
    
    fun shareAudio(filePath: String) {
        val file = File(filePath)
        if (!file.exists()) return
        
        val uri = FileProvider.getUriForFile(
            getApplication(),
            "${getApplication<Application>().packageName}.provider",
            file
        )
        
        val shareIntent = Intent().apply {
            action = Intent.ACTION_SEND
            putExtra(Intent.EXTRA_STREAM, uri)
            type = "audio/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        
        val chooser = Intent.createChooser(shareIntent, "Поделиться аудио")
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        getApplication<Application>().startActivity(chooser)
    }
}

class RecordingDetailsViewModelFactory(
    private val application: Application,
    private val repository: RecordingRepository,
    private val recordingId: Long
) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        if (modelClass.isAssignableFrom(RecordingDetailsViewModel::class.java)) {
            @Suppress("UNCHECKED_CAST")
            return RecordingDetailsViewModel(application, repository, recordingId) as T
        }
        throw IllegalArgumentException("Unknown ViewModel class")
    }
}
