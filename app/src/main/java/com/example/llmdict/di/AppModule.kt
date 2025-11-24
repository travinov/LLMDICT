package com.example.llmdict.di

import android.content.Context
import android.content.SharedPreferences
import androidx.room.Room
import com.example.llmdict.data.RecordingRepository
import com.example.llmdict.data.SettingsRepository
import com.example.llmdict.data.local.AppDatabase

object AppModule {

    @Volatile
    private var database: AppDatabase? = null

    @Volatile
    private var settingsRepository: SettingsRepository? = null

    fun provideDatabase(context: Context): AppDatabase {
        return database ?: synchronized(this) {
            database ?: Room.databaseBuilder(
                context.applicationContext,
                AppDatabase::class.java,
                "llm_dictaphone.db"
            )
            .fallbackToDestructiveMigration() // Сбрасываем БД при обновлении схемы
            .build().also { database = it }
        }
    }

    private fun provideSettingsPrefs(context: Context): SharedPreferences {
        return context.getSharedPreferences("llmdict_settings", Context.MODE_PRIVATE)
    }

    fun provideSettingsRepository(context: Context): SettingsRepository {
        return settingsRepository ?: synchronized(this) {
            settingsRepository ?: SettingsRepository(
                prefs = provideSettingsPrefs(context.applicationContext)
            ).also { settingsRepository = it }
        }
    }

    fun provideRecordingRepository(context: Context): RecordingRepository {
        val db = provideDatabase(context)
        val settings = provideSettingsRepository(context)
        return RecordingRepository(
            context = context,
            dao = db.recordingDao(),
            promptDao = db.promptDao(),
            settingsRepository = settings
        )
    }
}
