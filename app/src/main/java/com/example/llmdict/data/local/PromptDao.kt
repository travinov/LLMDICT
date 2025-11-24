package com.example.llmdict.data.local

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface PromptDao {
    @Query("SELECT * FROM prompts ORDER BY id DESC")
    fun getAll(): Flow<List<PromptEntity>>

    @Query("SELECT * FROM prompts WHERE isSelected = 1 LIMIT 1")
    suspend fun getSelected(): PromptEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(prompt: PromptEntity)

    @Update
    suspend fun update(prompt: PromptEntity)

    @Delete
    suspend fun delete(prompt: PromptEntity)

    @Query("UPDATE prompts SET isSelected = 0")
    suspend fun clearSelection()

    @Query("UPDATE prompts SET isSelected = 1 WHERE id = :id")
    suspend fun setSelected(id: Long)
}
