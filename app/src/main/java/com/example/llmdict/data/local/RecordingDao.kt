package com.example.llmdict.data.local

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface RecordingDao {

    @Query("SELECT * FROM recordings_local ORDER BY createdAt DESC")
    fun getAll(): Flow<List<RecordingEntity>>
    
    @Query("SELECT * FROM recordings_local WHERE localId = :id")
    suspend fun getById(id: Long): RecordingEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: RecordingEntity): Long

    @Update
    suspend fun update(entity: RecordingEntity)

    @Query("DELETE FROM recordings_local WHERE localId = :id")
    suspend fun deleteById(id: Long)

    @Query("UPDATE recordings_local SET status = 'error' WHERE status IN ('transcribing', 'transcribing_openai')")
    suspend fun resetStuckStates()
}
