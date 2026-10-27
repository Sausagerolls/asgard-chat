package com.giantmushroom.asgardchat.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

class ApiError(val status: Int, val code: String, override val message: String) : Exception(message) {
    companion object {
        val offline = ApiError(0, "offline", "You're offline. Messages will send when you reconnect.")
    }
}

/** Thin coroutine wrapper around the Asgard REST API. */
class ApiClient(val baseURL: String, val token: String?) {
    val http: OkHttpClient = shared

    fun url(path: String, query: Map<String, String> = emptyMap()) =
        (baseURL.trimEnd('/') + "/api/v1" + path).toHttpUrl().newBuilder().apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }.build()

    private fun request(method: String, path: String, query: Map<String, String> = emptyMap(), body: okhttp3.RequestBody? = null): Request =
        Request.Builder().url(url(path, query)).apply {
            token?.let { header("Authorization", "Bearer $it") }
            header("User-Agent", "AsgardChat-Android/1")
            method(method, body ?: if (method == "POST" || method == "PUT" || method == "PATCH") "{}".toRequestBody(jsonType) else null)
        }.build()

    suspend inline fun <reified T> send(method: String, path: String, body: Any? = null, query: Map<String, String> = emptyMap()): T {
        val raw = execute(method, path, body?.let { encode(it) }, query)
        return AsgardJson.decodeFromString(serializer<T>(), raw)
    }

    suspend fun call(method: String, path: String, body: Any? = null) { execute(method, path, body?.let { encode(it) }) }

    @PublishedApi internal inline fun <reified B> encode(body: B): String = when (body) {
        is JsonElement -> body.toString()
        is String -> body
        else -> AsgardJson.encodeToString(serializer(body!!::class.java), body)
    }

    suspend fun execute(method: String, path: String, json: String?, query: Map<String, String> = emptyMap()): String = withContext(Dispatchers.IO) {
        val req = request(method, path, query, json?.toRequestBody(jsonType))
        val resp = try { http.newCall(req).await() } catch (e: IOException) { throw networkError(e, req) }
        resp.use { r ->
            val text = r.body.string()
            if (!r.isSuccessful) {
                val err = runCatching { AsgardJson.decodeFromString(ApiErrorBody.serializer(), text).error }.getOrNull()
                throw ApiError(r.code, err?.code ?: "http_${r.code}", err?.message ?: r.message.ifEmpty { "Request failed (${r.code})" })
            }
            text.ifEmpty { "{}" }
        }
    }

    suspend fun upload(blob: ByteArray, purpose: String? = null, contentType: String = "application/octet-stream"): UUID = withContext(Dispatchers.IO) {
        val req = request("POST", "/media", purpose?.let { mapOf("purpose" to it) } ?: emptyMap(), blob.toRequestBody(contentType.toMediaType()))
        val resp = try { upload.newCall(req).await() } catch (e: IOException) { throw networkError(e, req) }
        resp.use { r ->
            val text = r.body.string()
            if (r.code != 201) throw ApiError(r.code, "upload_failed", runCatching { AsgardJson.decodeFromString(ApiErrorBody.serializer(), text).error.message }.getOrDefault("Upload failed."))
            UUID.fromString(Regex("\"id\"\\s*:\\s*\"([^\"]+)\"").find(text)!!.groupValues[1])
        }
    }

    suspend fun download(id: UUID): ByteArray = withContext(Dispatchers.IO) {
        val req = request("GET", "/media/${id.toString().lowercase()}")
        val resp = try { upload.newCall(req).await() } catch (e: IOException) { throw networkError(e, req) }
        resp.use { r -> if (!r.isSuccessful) throw ApiError(r.code, "download_failed", "Couldn't download media."); r.body.bytes() }
    }

    val webSocketURL: String get() = baseURL.trimEnd('/').replaceFirst("http", "ws") + "/api/v1/ws"

    private fun networkError(e: IOException, req: Request): ApiError = when (e) {
        is UnknownHostException, is ConnectException, is SocketTimeoutException ->
            ApiError(0, "unreachable", "Can't reach ${req.url.host}. Check the address and that you're on the right network.")
        else -> ApiError.offline
    }

    // Typed endpoints
    suspend fun info(): ServerInfo = send("GET", "/info")
    suspend fun conversations(): List<Conversation> = send("GET", "/conversations")
    suspend fun conversation(id: UUID): Conversation = send("GET", "/conversations/${id.lower}")
    suspend fun devicesIn(conv: UUID): List<DeviceInfo> = send("GET", "/conversations/${conv.lower}/devices")
    suspend fun devicesOf(user: UUID): List<DeviceInfo> = send("GET", "/users/${user.lower}/devices")
    suspend fun members(conv: UUID): List<Member> = send("GET", "/conversations/${conv.lower}/members")
    suspend fun sync(after: Long): SyncPage = send("GET", "/sync", query = mapOf("after" to after.toString()))
    suspend fun history(conv: UUID, beforeSeq: Long?, limit: Int = 50): List<Envelope> =
        send("GET", "/conversations/${conv.lower}/messages", query = buildMap { put("limit", "$limit"); beforeSeq?.let { put("before_seq", "$it") } })

    companion object {
        val jsonType = "application/json".toMediaType()
        val shared: OkHttpClient = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
            .pingInterval(25, TimeUnit.SECONDS).build()
        val upload: OkHttpClient = shared.newBuilder().readTimeout(10, TimeUnit.MINUTES).writeTimeout(10, TimeUnit.MINUTES).build()
    }
}

val UUID.lower: String get() = toString().lowercase()

suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = cont.resume(response) { _, _, _ -> response.close() }
        override fun onFailure(call: Call, e: IOException) = cont.resumeWithException(e)
    })
    cont.invokeOnCancellation { cancel() }
}
