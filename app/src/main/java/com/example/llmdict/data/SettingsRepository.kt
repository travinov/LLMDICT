package com.example.llmdict.data

import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

enum class TranscriptionModel {
    OPENAI_WHISPER,
    OPENAI_GPT4O,
    SBER_SALUTE
}

class SettingsRepository(
    private val prefs: SharedPreferences
) {

    fun getOpenAiApiKey(): String =
        prefs.getString(KEY_OPENAI_API_KEY, "") ?: ""

    suspend fun setOpenAiApiKey(value: String) {
        withContext(Dispatchers.IO) {
            // Оставляем только trim(), без удаления символов внутри
            prefs.edit()
                .putString(KEY_OPENAI_API_KEY, value.trim())
                .apply()
        }
    }

    fun getOpenAiBaseUrl(): String =
        prefs.getString(KEY_OPENAI_BASE_URL, "https://api.openai.com/v1") ?: "https://api.openai.com/v1"

    suspend fun setOpenAiBaseUrl(value: String) {
        withContext(Dispatchers.IO) {
            val cleanUrl = value.trim().removeSuffix("/")
            prefs.edit()
                .putString(KEY_OPENAI_BASE_URL, cleanUrl)
                .apply()
        }
    }
    
    fun getSberAuthKey(): String =
        prefs.getString(KEY_SBER_AUTH_KEY, "") ?: ""

    suspend fun setSberAuthKey(value: String) {
        withContext(Dispatchers.IO) {
            // Оставляем только trim()
            prefs.edit()
                .putString(KEY_SBER_AUTH_KEY, value.trim())
                .apply()
        }
    }

    fun getTranscriptionModel(): TranscriptionModel {
        val raw = prefs.getString(KEY_TRANSCRIPTION_MODEL, null)
        return runCatching { TranscriptionModel.valueOf(raw ?: "") }
            .getOrDefault(TranscriptionModel.OPENAI_WHISPER)
    }

    suspend fun setTranscriptionModel(model: TranscriptionModel) {
        withContext(Dispatchers.IO) {
            prefs.edit()
                .putString(KEY_TRANSCRIPTION_MODEL, model.name)
                .apply()
        }
    }

    fun isAudioEnhancementEnabled(): Boolean {
        return prefs.getBoolean(KEY_AUDIO_ENHANCEMENT, false)
    }

    suspend fun setAudioEnhancementEnabled(enabled: Boolean) {
        withContext(Dispatchers.IO) {
            prefs.edit()
                .putBoolean(KEY_AUDIO_ENHANCEMENT, enabled)
                .apply()
        }
    }

    fun isVoskModelLoaded(): Boolean = false
    fun setVoskModelLoaded(loaded: Boolean) {}

    companion object {
        private const val KEY_OPENAI_API_KEY = "openai_api_key"
        private const val KEY_OPENAI_BASE_URL = "openai_base_url"
        private const val KEY_SBER_AUTH_KEY = "sber_auth_key"
        private const val KEY_TRANSCRIPTION_MODEL = "transcription_model"
        private const val KEY_AUDIO_ENHANCEMENT = "audio_enhancement"
        private const val KEY_VOSK_MODEL_LOADED = "vosk_model_loaded"
    }
}
