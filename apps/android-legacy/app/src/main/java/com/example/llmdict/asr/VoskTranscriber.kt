package com.example.llmdict.asr

import android.content.Context
import android.util.Log
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

class VoskTranscriber(
    private val context: Context
) {

    @Volatile
    private var model: Model? = null

    init {
        LibVosk.setLogLevel(LogLevel.WARNINGS)
    }

    fun transcribePcmFile(
        audioFile: File,
        sampleRate: Int = 16_000
    ): String {
        val model = ensureModel()
        val recognizer = Recognizer(model, sampleRate.toFloat())

        audioFile.inputStream().buffered().use { input ->
            val buffer = ByteArray(4_096)
            while (true) {
                val bytesRead = input.read(buffer)
                if (bytesRead <= 0) break
                recognizer.acceptWaveForm(buffer, bytesRead)
            }
        }

        val finalJson = recognizer.finalResult
        return extractTextFromResult(finalJson)
    }

    private fun ensureModel(): Model {
        val cached = model
        if (cached != null) return cached

        synchronized(this) {
            val cachedAgain = model
            if (cachedAgain != null) return cachedAgain

            // 1. Пробуем найти импортированную пользователем модель (большую)
            val appModelDir = File(context.getExternalFilesDir(null), "vosk-model-imported")
            
            if (isValidModelDir(appModelDir)) {
                Log.d("VoskTranscriber", "Found imported manual model: ${appModelDir.absolutePath}")
                return Model(appModelDir.absolutePath).also { model = it }
            }
            
            val subDir = appModelDir.listFiles()?.find { isValidModelDir(it) }
            if (subDir != null) {
                Log.d("VoskTranscriber", "Found imported manual model in subdir: ${subDir.absolutePath}")
                return Model(subDir.absolutePath).also { model = it }
            }

            // 2. Если ручной модели нет — используем ВСТРОЕННУЮ маленькую (из assets)
            Log.d("VoskTranscriber", "No manual model found. Using built-in small model.")
            val internalModelDir = File(context.filesDir, "vosk-model-small")
            
            if (!isValidModelDir(internalModelDir)) {
                Log.d("VoskTranscriber", "Extracting small model from assets...")
                if (internalModelDir.exists()) internalModelDir.deleteRecursively()
                internalModelDir.mkdirs()
                // Имя файла должно точно совпадать с тем, что лежит в app/src/main/assets
                extractModelFromAssets("vosk-model-small-ru-0.22.zip", internalModelDir)
            }
            
            val validInternal = if (isValidModelDir(internalModelDir)) internalModelDir else resolveActualModelDir(internalModelDir)
            Log.d("VoskTranscriber", "Loading internal model from: ${validInternal.absolutePath}")
            
            return Model(validInternal.absolutePath).also { model = it }
        }
    }

    /**
     * Импортирует модель из указанного пути (File) во внутреннюю память.
     */
    fun importModelFromPath(sourceDir: File): Boolean {
        if (!sourceDir.exists() || !sourceDir.isDirectory) return false
        
        val targetDir = File(context.getExternalFilesDir(null), "vosk-model-imported")
        if (targetDir.exists()) {
            targetDir.deleteRecursively()
        }
        targetDir.mkdirs()

        Log.d("VoskTranscriber", "Starting import from ${sourceDir.absolutePath}")
        
        try {
            // Если это папка с моделью (содержит conf), копируем её содержимое
            if (isValidModelDir(sourceDir)) {
                 sourceDir.copyRecursively(targetDir, overwrite = true)
            } else {
                // Если это папка-контейнер (внутри папка модели), ищем и копируем правильную подпапку
                val subDir = sourceDir.listFiles()?.find { isValidModelDir(it) }
                if (subDir != null) {
                    subDir.copyRecursively(targetDir, overwrite = true)
                } else {
                    // На всякий случай копируем всё, вдруг структура хитрая
                    sourceDir.copyRecursively(targetDir, overwrite = true)
                }
            }
            
            Log.d("VoskTranscriber", "Import completed")
            model = null
            return true
        } catch (e: Exception) {
            Log.e("VoskTranscriber", "Import failed", e)
            return false
        }
    }

    private fun extractModelFromAssets(assetName: String, targetDir: File) {
        try {
            context.assets.open(assetName).use { inputStream ->
                ZipInputStream(inputStream).use { zis ->
                    var entry = zis.nextEntry
                    while (entry != null) {
                        val outFile = File(targetDir, entry.name)
                        if (entry.isDirectory) {
                            outFile.mkdirs()
                        } else {
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { output ->
                                zis.copyTo(output)
                            }
                        }
                        zis.closeEntry()
                        entry = zis.nextEntry
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("VoskTranscriber", "Failed to extract asset $assetName", e)
        }
    }

    private fun resolveActualModelDir(rootDir: File): File {
        val children = rootDir.listFiles()?.filter { it.isDirectory } ?: return rootDir
        if (children.size == 1) return children.first()
        return rootDir
    }

    private fun isValidModelDir(dir: File): Boolean {
        if (!dir.exists() || !dir.isDirectory) return false
        return File(dir, "conf").exists() || File(dir, "final.mdl").exists()
    }

    private fun extractTextFromResult(json: String?): String {
        if (json.isNullOrBlank()) return ""
        return try {
            JSONObject(json).optString("text", "")
        } catch (_: Exception) {
            ""
        }
    }
}
