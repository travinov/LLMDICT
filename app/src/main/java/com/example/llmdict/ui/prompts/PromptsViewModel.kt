package com.example.llmdict.ui.prompts

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.example.llmdict.data.local.PromptDao
import com.example.llmdict.data.local.PromptEntity
import com.example.llmdict.di.AppModule
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class PromptsViewModel(
    application: Application,
    private val promptDao: PromptDao
) : AndroidViewModel(application) {

    val prompts: StateFlow<List<PromptEntity>> = promptDao.getAll()
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5000),
            initialValue = emptyList()
        )

    fun addPrompt(title: String, content: String) {
        viewModelScope.launch {
            val newPrompt = PromptEntity(title = title, content = content, isSelected = false)
            promptDao.insert(newPrompt)
        }
    }

    fun updatePrompt(prompt: PromptEntity) {
        viewModelScope.launch {
            promptDao.update(prompt)
        }
    }

    fun deletePrompt(prompt: PromptEntity) {
        viewModelScope.launch {
            promptDao.delete(prompt)
        }
    }

    fun selectPrompt(id: Long) {
        viewModelScope.launch {
            promptDao.clearSelection()
            promptDao.setSelected(id)
        }
    }
    
    fun clearSelection() {
        viewModelScope.launch {
            promptDao.clearSelection()
        }
    }
}

class PromptsViewModelFactory(
    private val application: Application
) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        val db = AppModule.provideDatabase(application)
        @Suppress("UNCHECKED_CAST")
        return PromptsViewModel(application, db.promptDao()) as T
    }
}
