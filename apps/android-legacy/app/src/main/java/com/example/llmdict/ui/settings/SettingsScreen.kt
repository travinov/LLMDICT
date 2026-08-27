package com.example.llmdict.ui.settings

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.llmdict.BuildConfig
import com.example.llmdict.data.SettingsRepository
import com.example.llmdict.data.TranscriptionModel
import com.example.llmdict.di.AppModule
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class SettingsViewModel(
    application: Application,
    private val settingsRepository: SettingsRepository
) : AndroidViewModel(application) {

    private val _apiKey = MutableStateFlow("")
    val apiKey: StateFlow<String> = _apiKey

    private val _baseUrl = MutableStateFlow("")
    val baseUrl: StateFlow<String> = _baseUrl

    private val _sberKey = MutableStateFlow("")
    val sberKey: StateFlow<String> = _sberKey

    private val _model = MutableStateFlow(TranscriptionModel.OPENAI_WHISPER)
    val model: StateFlow<TranscriptionModel> = _model

    private val _isAudioEnhancement = MutableStateFlow(false)
    val isAudioEnhancement: StateFlow<Boolean> = _isAudioEnhancement

    init {
        val savedKey = settingsRepository.getOpenAiApiKey()
        _apiKey.value = savedKey.ifBlank { BuildConfig.OPENAI_API_KEY }
        _baseUrl.value = settingsRepository.getOpenAiBaseUrl()
        _sberKey.value = settingsRepository.getSberAuthKey()
        _model.value = settingsRepository.getTranscriptionModel()
        _isAudioEnhancement.value = settingsRepository.isAudioEnhancementEnabled()
    }

    fun onApiKeyChange(value: String) {
        _apiKey.value = value
    }

    fun onBaseUrlChange(value: String) {
        _baseUrl.value = value
    }
    
    fun onSberKeyChange(value: String) {
        _sberKey.value = value
    }

    fun onModelChange(model: TranscriptionModel) {
        _model.value = model
    }

    fun onAudioEnhancementChange(enabled: Boolean) {
        _isAudioEnhancement.value = enabled
    }

    fun save() {
        val key = _apiKey.value
        val url = _baseUrl.value
        val sber = _sberKey.value
        val model = _model.value
        val enhance = _isAudioEnhancement.value
        viewModelScope.launch {
            settingsRepository.setOpenAiApiKey(key)
            settingsRepository.setOpenAiBaseUrl(url)
            settingsRepository.setSberAuthKey(sber)
            settingsRepository.setTranscriptionModel(model)
            settingsRepository.setAudioEnhancementEnabled(enhance)
        }
    }
}

@Composable
fun rememberSettingsViewModel(): SettingsViewModel {
    val context = androidx.compose.ui.platform.LocalContext.current.applicationContext as Application
    val settingsRepository = AppModule.provideSettingsRepository(context)
    return androidx.lifecycle.viewmodel.compose.viewModel(
        factory = SettingsViewModelFactory(context, settingsRepository)
    )
}

class SettingsViewModelFactory(
    private val application: Application,
    private val settingsRepository: SettingsRepository
) : androidx.lifecycle.ViewModelProvider.Factory {
    override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T {
        if (modelClass.isAssignableFrom(SettingsViewModel::class.java)) {
            @Suppress("UNCHECKED_CAST")
            return SettingsViewModel(application, settingsRepository) as T
        }
        throw IllegalArgumentException("Unknown ViewModel class")
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel,
    onBack: () -> Unit,
    onOpenPrompts: () -> Unit
) {
    val apiKey by viewModel.apiKey.collectAsState()
    val baseUrl by viewModel.baseUrl.collectAsState()
    val sberKey by viewModel.sberKey.collectAsState()
    val model by viewModel.model.collectAsState()
    val isAudioEnhancement by viewModel.isAudioEnhancement.collectAsState()

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(text = "Настройки") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Назад")
                    }
                }
            )
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState())
        ) {
            Text(text = "OpenAI Settings", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(8.dp))
            OutlinedTextField(
                value = apiKey,
                onValueChange = viewModel::onApiKeyChange,
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                placeholder = { Text("sk-...") },
                label = { Text("OpenAI API Key") }
            )
            
            Spacer(modifier = Modifier.height(8.dp))
            OutlinedTextField(
                value = baseUrl,
                onValueChange = viewModel::onBaseUrlChange,
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                placeholder = { Text("https://api.openai.com/v1") },
                label = { Text("OpenAI Base URL") }
            )
            
            Spacer(modifier = Modifier.height(24.dp))
            Text(text = "Sber Salute Settings", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(8.dp))
            OutlinedTextField(
                value = sberKey,
                onValueChange = viewModel::onSberKeyChange,
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                placeholder = { Text("Authorization Key (Base64)") },
                label = { Text("Sber Auth Key") },
                supportingText = { Text("Получите в личном кабинете developers.sber.ru") }
            )

            Spacer(modifier = Modifier.height(24.dp))
            Text(text = "Настройки записи", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(8.dp))
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Улучшение звука (шумоподавление)",
                    modifier = Modifier.weight(1f)
                )
                Switch(
                    checked = isAudioEnhancement,
                    onCheckedChange = viewModel::onAudioEnhancementChange
                )
            }

            Spacer(modifier = Modifier.height(24.dp))
            Text(text = "Активная модель", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(8.dp))

            ModelOptionRow(
                title = "OpenAI Whisper-1",
                selected = model == TranscriptionModel.OPENAI_WHISPER,
                onClick = { viewModel.onModelChange(TranscriptionModel.OPENAI_WHISPER) }
            )
            
            ModelOptionRow(
                title = "OpenAI GPT-4o Audio",
                selected = model == TranscriptionModel.OPENAI_GPT4O,
                onClick = { viewModel.onModelChange(TranscriptionModel.OPENAI_GPT4O) }
            )
            
            ModelOptionRow(
                title = "Sber SaluteSpeech (GigaAM)",
                selected = model == TranscriptionModel.SBER_SALUTE,
                onClick = { viewModel.onModelChange(TranscriptionModel.SBER_SALUTE) }
            )

            Spacer(modifier = Modifier.height(16.dp))
            
            OutlinedButton(
                onClick = onOpenPrompts,
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.Edit, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Настроить системные промпты")
            }

            Spacer(modifier = Modifier.height(24.dp))
            Button(
                onClick = {
                    viewModel.save()
                    onBack()
                },
                modifier = Modifier.align(Alignment.End)
            ) {
                Text(text = "Сохранить")
            }
        }
    }
}

@Composable
private fun ModelOptionRow(
    title: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        RadioButton(
            selected = selected,
            onClick = onClick
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = title,
            modifier = Modifier.weight(1f)
        )
    }
}
