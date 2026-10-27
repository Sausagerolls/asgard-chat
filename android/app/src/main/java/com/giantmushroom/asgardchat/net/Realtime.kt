package com.giantmushroom.asgardchat.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

enum class ConnectionState { disconnected, connecting, connected }

class RealtimeEvent(val type: String, val data: JsonElement?)

/** WebSocket with automatic reconnect and exponential backoff. Frames are {"type", "data"}. */
class Realtime(private val api: ApiClient, private val scope: CoroutineScope) {
    private val _events = MutableSharedFlow<RealtimeEvent>(extraBufferCapacity = 256, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val events: SharedFlow<RealtimeEvent> = _events
    private val _state = MutableStateFlow(ConnectionState.disconnected)
    val state: StateFlow<ConnectionState> = _state
    private var socket: WebSocket? = null
    private var stopped = true
    private var attempt = 0
    private var reconnectJob: Job? = null

    fun start() {
        stopped = false
        connect()
    }

    fun stop() {
        stopped = true
        reconnectJob?.cancel()
        socket?.close(1000, null)
        socket = null
        _state.value = ConnectionState.disconnected
    }

    /** Forces a fresh connection, e.g. when the app returns to the foreground. */
    fun nudge() { if (!stopped && _state.value != ConnectionState.connected) { reconnectJob?.cancel(); connect() } }

    fun send(type: String, data: JsonObject) {
        socket?.send(buildJsonObject { put("type", kotlinx.serialization.json.JsonPrimitive(type)); put("data", data) }.toString())
    }

    private fun connect() {
        if (stopped) return
        _state.value = ConnectionState.connecting
        val req = Request.Builder().url(api.webSocketURL).header("Authorization", "Bearer ${api.token}").build()
        socket = ApiClient.shared.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                attempt = 0
                _state.value = ConnectionState.connected
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val frame = runCatching { AsgardJson.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
                val type = frame["type"]?.jsonPrimitive?.content ?: return
                _events.tryEmit(RealtimeEvent(type, frame["data"]))
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = scheduleReconnect(webSocket)
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = scheduleReconnect(webSocket)
        })
    }

    private fun scheduleReconnect(ws: WebSocket) {
        if (ws !== socket) return
        _state.value = ConnectionState.disconnected
        if (stopped) return
        val wait = minOf(30_000L, 500L * (1L shl minOf(attempt++, 6)))
        reconnectJob = scope.launch { delay(wait); connect() }
    }
}
