package com.example.llmdict.data.remote

import okhttp3.MultipartBody
import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Multipart
import retrofit2.http.POST
import retrofit2.http.Part
import retrofit2.http.Path

interface BackendApi {

    @POST("/api/recordings")
    suspend fun createRecording(): CreateRecordingResponse

    @Multipart
    @POST("/api/recordings/{id}/chunks")
    suspend fun uploadChunk(
        @Path("id") recordingId: String,
        @Part file: MultipartBody.Part
    ): Response<Unit>

    @POST("/api/recordings/{id}/finish")
    suspend fun finishRecording(
        @Path("id") recordingId: String
    ): Response<Unit>

    @GET("/api/recordings/{id}/transcript.txt")
    suspend fun getTranscript(
        @Path("id") recordingId: String
    ): ResponseBody
}

