package com.example.llmdict.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Base64
import android.util.Log
import com.example.llmdict.BuildConfig
import com.example.llmdict.R
import com.example.llmdict.data.local.PromptDao
import com.example.llmdict.data.local.RecordingDao
import com.example.llmdict.data.local.RecordingEntity
import com.example.llmdict.recording.RecordingService
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.logging.HttpLoggingInterceptor
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

class RecordingRepository(
    private val context: Context,
    private val dao: RecordingDao,
    private val promptDao: PromptDao,
    private val settingsRepository: SettingsRepository,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
) {

    init {
        CoroutineScope(ioDispatcher).launch {
            try {
                dao.resetStuckStates()
            } catch (e: Exception) {
                Log.e("RecordingRepository", "Failed to reset stuck states", e)
            }
        }
    }

    fun getRecordings(): Flow<List<RecordingEntity>> = dao.getAll()

    suspend fun getRecordingById(id: Long): RecordingEntity? = withContext(ioDispatcher) {
        dao.getById(id)
    }

    suspend fun createLocalRecording(title: String, filePath: String): RecordingEntity = withContext(ioDispatcher) {
        val now = System.currentTimeMillis()
        val entity = RecordingEntity(
            title = title,
            createdAt = now,
            updatedAt = now,
            durationMs = 0L,
            filePath = filePath,
            status = "local_only",
            transcriptPreview = null
        )
        val id = dao.insert(entity)
        entity.copy(localId = id)
    }

    suspend fun deleteRecording(entity: RecordingEntity) = withContext(ioDispatcher) {
        try {
            val pcmFile = File(entity.filePath)
            if (pcmFile.exists()) pcmFile.delete()
            
            val wavName = pcmFile.nameWithoutExtension + ".wav"
            val wavFile = File(context.cacheDir, "openai_wav/$wavName")
            if (wavFile.exists()) wavFile.delete()

            dao.deleteById(entity.localId)
        } catch (e: Exception) {
            Log.e("RecordingRepository", "Failed to delete recording", e)
        }
    }

    suspend fun transcribeBySettings(entity: RecordingEntity): Result<String> {
        val model = settingsRepository.getTranscriptionModel()
        val selectedPrompt = promptDao.getSelected()?.content
        
        Log.d("RecordingRepository", ">>> Transcribing ID=${entity.localId}")
        Log.d("RecordingRepository", ">>> Model: $model")
        
        return when (model) {
            TranscriptionModel.OPENAI_WHISPER -> transcribeWithWhisper(entity, selectedPrompt)
            TranscriptionModel.OPENAI_GPT4O -> transcribeWithGpt4o(entity, selectedPrompt)
            TranscriptionModel.SBER_SALUTE -> transcribeWithSber(entity)
        }
    }

    /**
     * Sber SaluteSpeech (GigaAM)
     */
    private suspend fun transcribeWithSber(entity: RecordingEntity): Result<String> = withContext(ioDispatcher) {
        val tag = "SberSalute"
        runCatching {
            if (!isNetworkAvailable()) throw IOException("Нет интернета")
            
            val authKey = settingsRepository.getSberAuthKey().trim()
            if (authKey.isBlank()) throw IllegalStateException("Sber Auth Key не задан")

            val now = System.currentTimeMillis()
            dao.update(entity.copy(updatedAt = now, status = "transcribing"))

            // Используем клиент с поддержкой российских сертификатов
            val client = getSberOkHttpClient()
            val rquid = UUID.randomUUID().toString()
            
            val tokenRequest = Request.Builder()
                .url("https://ngw.devices.sberbank.ru:9443/api/v2/oauth")
                .header("Authorization", "Basic $authKey")
                .header("RqUID", rquid)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .post("scope=SALUTE_SPEECH_PERS".toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                .build()

            val tokenResponse = client.newCall(tokenRequest).execute()
            val accessToken = tokenResponse.use { resp ->
                if (!resp.isSuccessful) throw IOException("Sber Auth failed: ${resp.code} ${resp.body?.string()}")
                JSONObject(resp.body?.string() ?: "").getString("access_token")
            }

            val pcmFile = File(entity.filePath)
            if (!pcmFile.exists()) throw IOException("Audio file missing")
            
            val wavFile = pcmToWav(pcmFile, File(context.cacheDir, "sber_wav"))

            val recognizeRequest = Request.Builder()
                .url("https://smartspeech.sber.ru/rest/v1/speech:recognize")
                .header("Authorization", "Bearer $accessToken")
                .header("Content-Type", "audio/x-wav")
                .post(wavFile.asRequestBody("audio/x-wav".toMediaType()))
                .build()

            val recognizeResponse = client.newCall(recognizeRequest).execute()
            
            recognizeResponse.use { resp ->
                if (!resp.isSuccessful) throw IOException("Sber recognize failed: ${resp.code} ${resp.body?.string()}")
                val respBody = resp.body?.string() ?: ""
                val text = try {
                     val jsonArray = JSONArray(respBody)
                     if (jsonArray.length() > 0) jsonArray.getJSONObject(0).optString("result") else respBody
                } catch (e: Exception) {
                    respBody
                }
                
                updateEntitySuccess(entity, text)
                text
            }
        }.onFailure {
            Log.e(tag, "Failed", it)
            dao.update(entity.copy(status = "error"))
        }
    }

    private suspend fun transcribeWithWhisper(entity: RecordingEntity, prompt: String?): Result<String> = withContext(ioDispatcher) {
        val tag = "Whisper"
        runCatching {
            validateNetworkAndKey()
            
            val now = System.currentTimeMillis()
            dao.update(entity.copy(updatedAt = now, status = "transcribing"))

            val pcmFile = File(entity.filePath)
            if (!pcmFile.exists()) throw IOException("Audio file missing")
            
            val wavFile = pcmToWav(pcmFile, File(context.cacheDir, "openai_wav"))

            val baseUrl = settingsRepository.getOpenAiBaseUrl().removeSuffix("/")
            val url = "$baseUrl/audio/transcriptions"

            val client = createOkHttpClient()
            
            val requestBodyBuilder = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart("file", wavFile.name, wavFile.asRequestBody("audio/wav".toMediaType()))
                .addFormDataPart("model", "whisper-1")
                .addFormDataPart("language", "ru")
                .addFormDataPart("response_format", "json")

            if (!prompt.isNullOrBlank()) {
                val cleanPrompt = prompt.replace("{system}", "").replace("{user}", "").trim()
                requestBodyBuilder.addFormDataPart("prompt", cleanPrompt)
            }
            
            val request = Request.Builder()
                .url(url)
                .header("Authorization", "Bearer ${getApiKey()}")
                .post(requestBodyBuilder.build())
                .build()

            val response = client.newCall(request).execute()
            handleResponse(response, entity)
        }.onFailure { 
            Log.e(tag, "Failed", it)
            dao.update(entity.copy(status = "error"))
        }
    }

    private suspend fun transcribeWithGpt4o(entity: RecordingEntity, rawPrompt: String?): Result<String> = withContext(ioDispatcher) {
        val tag = "GPT4o"
        runCatching {
            validateNetworkAndKey()
            
            val now = System.currentTimeMillis()
            dao.update(entity.copy(updatedAt = now, status = "transcribing"))

            val pcmFile = File(entity.filePath)
            if (!pcmFile.exists()) throw IOException("Audio file missing")
            
            val wavFile = pcmToWav(pcmFile, File(context.cacheDir, "openai_wav"))
            val base64Audio = Base64.encodeToString(wavFile.readBytes(), Base64.NO_WRAP)

            val baseUrl = settingsRepository.getOpenAiBaseUrl().removeSuffix("/")
            val url = "$baseUrl/chat/completions"
            
            val messagesArray = JSONArray()

            var systemText = ""
            var userText = "Transcribe this audio."

            if (!rawPrompt.isNullOrBlank()) {
                if (rawPrompt.contains("{system}") || rawPrompt.contains("{user}")) {
                    val parts = rawPrompt.split(Regex("(?=\\{system\\}|\\{user\\})"))
                    for (part in parts) {
                        when {
                            part.startsWith("{system}") -> systemText += part.removePrefix("{system}").trim() + " "
                            part.startsWith("{user}") -> userText = part.removePrefix("{user}").trim()
                        }
                    }
                    systemText = systemText.trim()
                } else {
                    systemText = rawPrompt.trim()
                    userText = "Process this audio according to system instructions."
                }
            }
            
            if (systemText.isNotEmpty()) {
                messagesArray.put(JSONObject().apply {
                    put("role", "system")
                    put("content", systemText)
                })
            }

            val contentArray = JSONArray()
            if (userText.isNotEmpty()) {
                contentArray.put(JSONObject().put("type", "text").put("text", userText))
            }
            
            val audioObj = JSONObject().apply {
                put("data", base64Audio)
                put("format", "wav")
            }
            contentArray.put(JSONObject().put("type", "input_audio").put("input_audio", audioObj))

            messagesArray.put(JSONObject().apply {
                put("role", "user")
                put("content", contentArray)
            })
            
            val jsonBody = JSONObject().apply {
                put("model", "gpt-4o-audio-preview")
                put("modalities", JSONArray().put("text"))
                put("messages", messagesArray)
            }

            val client = createOkHttpClient()
            val request = Request.Builder()
                .url(url)
                .header("Authorization", "Bearer ${getApiKey()}")
                .header("Content-Type", "application/json")
                .post(jsonBody.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = client.newCall(request).execute()
            
            response.use { resp ->
                if (!resp.isSuccessful) throw IOException("GPT-4o failed: ${resp.code} ${resp.body?.string()}")
                val respJson = JSONObject(resp.body?.string() ?: "")
                val content = respJson.getJSONArray("choices")
                    .getJSONObject(0)
                    .getJSONObject("message")
                    .optString("content", "")
                
                updateEntitySuccess(entity, content)
                content
            }
        }.onFailure {
            Log.e(tag, "Failed", it)
            dao.update(entity.copy(status = "error"))
        }
    }

    private suspend fun handleResponse(response: okhttp3.Response, entity: RecordingEntity): String {
        response.use { resp ->
            if (!resp.isSuccessful) throw IOException("API failed: ${resp.code} ${resp.body?.string()}")
            val json = JSONObject(resp.body?.string() ?: "")
            val text = json.optString("text", "") 
            updateEntitySuccess(entity, text)
            return text
        }
    }

    private suspend fun updateEntitySuccess(entity: RecordingEntity, text: String) {
        dao.update(entity.copy(
            updatedAt = System.currentTimeMillis(),
            status = "transcribed",
            transcriptPreview = text 
        ))
    }

    private fun getApiKey(): String {
        val key = settingsRepository.getOpenAiApiKey().ifBlank { BuildConfig.OPENAI_API_KEY }
        return key.trim()
    }

    private fun validateNetworkAndKey() {
        if (!isNetworkAvailable()) throw IOException("No internet connection")
        if (getApiKey().isBlank()) throw IllegalStateException("API Key is missing")
    }

    private fun createOkHttpClient(): OkHttpClient {
        val logging = HttpLoggingInterceptor { Log.d("OkHttp", it) }
        logging.level = HttpLoggingInterceptor.Level.HEADERS
        return OkHttpClient.Builder()
            .addInterceptor(logging)
            .connectTimeout(120, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .writeTimeout(120, TimeUnit.SECONDS)
            .build()
    }

    // Safe Sber Client with Russian Certificate
    private fun getSberOkHttpClient(): OkHttpClient {
        try {
            // 1. Load Russian Cert from Resources
            val cf = CertificateFactory.getInstance("X.509")
            val certInput: InputStream = context.resources.openRawResource(R.raw.russian_trusted_root_ca)
            val ca = certInput.use { cf.generateCertificate(it) }

            // 2. Create a KeyStore containing our trusted CAs
            val keyStoreType = KeyStore.getDefaultType()
            val keyStore = KeyStore.getInstance(keyStoreType)
            keyStore.load(null, null)
            keyStore.setCertificateEntry("ca", ca)

            // 3. Create a TrustManager that trusts the CAs in our KeyStore
            val tmfAlgorithm = TrustManagerFactory.getDefaultAlgorithm()
            val tmf = TrustManagerFactory.getInstance(tmfAlgorithm)
            tmf.init(keyStore)

            // 4. Create an SSLContext that uses our TrustManager
            val sslContext = SSLContext.getInstance("TLS")
            sslContext.init(null, tmf.trustManagers, null)

            val logging = HttpLoggingInterceptor { Log.d("OkHttp", it) }
            logging.level = HttpLoggingInterceptor.Level.HEADERS

            return OkHttpClient.Builder()
                .sslSocketFactory(sslContext.socketFactory, tmf.trustManagers[0] as X509TrustManager)
                .addInterceptor(logging)
                .connectTimeout(60, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .build()
        } catch (e: Exception) {
            Log.e("RecordingRepository", "Failed to setup Sber SSL", e)
            // Fallback to default client if something goes wrong (but it will likely fail SSL handshake)
            return createOkHttpClient()
        }
    }
    
    private fun isNetworkAvailable(): Boolean {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivityManager.activeNetwork ?: return false
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun pcmToWav(pcmFile: File, outputDir: File): File {
        if (!outputDir.exists()) outputDir.mkdirs()
        val wavFile = File(outputDir, pcmFile.nameWithoutExtension + ".wav")
        FileOutputStream(wavFile).use { out ->
            val pcmData = pcmFile.readBytes()
            val totalDataLen = pcmData.size + 36
            val sampleRate = RecordingService.SAMPLE_RATE 
            val byteRate = 16 * sampleRate * 1 / 8

            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray())
                putInt(totalDataLen)
                put("WAVE".toByteArray())
                put("fmt ".toByteArray())
                putInt(16)
                putShort(1) // PCM
                putShort(1) // Mono
                putInt(sampleRate)
                putInt(byteRate)
                putShort(2) // BlockAlign
                putShort(16) // BitsPerSample
                put("data".toByteArray())
                putInt(pcmData.size)
            }.array()

            out.write(header)
            out.write(pcmData)
        }
        return wavFile
    }
}
