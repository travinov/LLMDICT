package com.example.llmdict.recording

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

object RecordingLevelMonitor {

    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level

    fun updateLevel(value: Float) {
        _level.value = value.coerceIn(0f, 1f)
    }
}

