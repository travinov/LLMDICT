package com.example.llmdict.data.local

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "recordings_local")
data class RecordingEntity(
    @PrimaryKey(autoGenerate = true) val localId: Long = 0L,
    val serverId: String? = null,
    val title: String,
    val createdAt: Long,
    val updatedAt: Long,
    val durationMs: Long,
    val filePath: String,
    val status: String,
    val transcriptPreview: String?
)

