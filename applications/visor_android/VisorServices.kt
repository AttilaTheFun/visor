// The client's services on Android: a WebSocket client of our own over an
// SSL socket (the platform has none built in and the app carries no
// dependency for one), HTTP over HttpURLConnection, and settings in
// SharedPreferences. Installed through the generated installVisorBridges.

package dev.isomer.runtime

import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLSocketFactory
import kotlin.concurrent.thread
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

object VisorAndroidServices {
    /** `intent`: the launch intent, whose `fixture` / `fixture.screen` extras
     *  (the snapshot tests': `am start --es fixture snapshot --es
     *  fixture.screen chat`) stand in for those settings for this launch. */
    fun install(intent: android.content.Intent? = null) {
        PreferencesSettings.launchOverrides.clear()
        for (key in listOf("fixture", "fixture.screen")) {
            intent?.getStringExtra(key)?.let { PreferencesSettings.launchOverrides[key] = it }
        }
        SwiftUIBridge.installVisorBridges(
            socket = SocketClient(),
            http = HttpClient(),
            settings = PreferencesSettings(),
        )
        SwiftUIBridge.installVisorNetwork(network = NetworkWatch.shared)
    }
}

/** One RFC 6455 client per id; events queue up and `next` hands them over. */
class SocketClient : SocketBridge {
    private class Connection {
        val events = LinkedBlockingQueue<String>()
        @Volatile var output: OutputStream? = null
        @Volatile var socket: java.net.Socket? = null
        @Volatile var gone = false
    }

    private val connections = ConcurrentHashMap<Int, Connection>()
    private val ids = AtomicInteger(1)
    private val random = SecureRandom()

    override fun open(url: String): Int {
        val uri = try { URI(url) } catch (_: Exception) { return -1 }
        val host = uri.host ?: return -1
        val secure = uri.scheme == "wss"
        val port = if (uri.port > 0) uri.port else if (secure) 443 else 80
        val path = if (uri.rawPath.isNullOrEmpty()) "/" else uri.rawPath + (uri.rawQuery?.let { "?$it" } ?: "")
        val id = ids.getAndIncrement()
        val connection = Connection()
        connections[id] = connection
        thread(name = "visor-socket-$id") {
            try {
                val socket = if (secure) SSLSocketFactory.getDefault().createSocket(host, port) else java.net.Socket(host, port)
                connection.socket = socket
                val output = socket.getOutputStream()
                val input = DataInputStream(socket.getInputStream())
                val key = ByteArray(16).also { random.nextBytes(it) }
                val request = "GET $path HTTP/1.1\r\nHost: $host\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: ${android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP)}\r\nSec-WebSocket-Version: 13\r\n\r\n"
                output.write(request.toByteArray(Charsets.UTF_8))
                output.flush()
                val status = readHeaders(input)
                if (!status.startsWith("HTTP/1.1 101")) {
                    connection.events.put("error " + status.lineSequence().firstOrNull().orEmpty())
                    connection.gone = true
                    socket.close()
                    return@thread
                }
                connection.output = output
                connection.events.put("open")
                val message = java.io.ByteArrayOutputStream()
                while (!connection.gone) {
                    val first = input.readUnsignedByte()
                    val fin = first and 0x80 != 0
                    val opcode = first and 0x0F
                    val second = input.readUnsignedByte()
                    val masked = second and 0x80 != 0
                    var length = (second and 0x7F).toLong()
                    if (length == 126L) length = input.readUnsignedShort().toLong()
                    else if (length == 127L) length = input.readLong()
                    val mask = if (masked) ByteArray(4).also { input.readFully(it) } else null
                    val payload = ByteArray(length.toInt()).also { input.readFully(it) }
                    if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
                    when (opcode) {
                        0x1, 0x0 -> { message.write(payload); if (fin) { connection.events.put("message " + message.toString("UTF-8")); message.reset() } }
                        0x2 -> { if (fin) message.reset() }
                        0x8 -> { connection.gone = true; connection.events.put("close closed by the server") }
                        0x9 -> synchronized(connection) { output.write(frame(0xA, payload)); output.flush() }
                        else -> {}
                    }
                }
            } catch (error: Exception) {
                if (!connection.gone) {
                    connection.gone = true
                    connection.events.put("close " + (error.message ?: "connection lost"))
                }
            } finally {
                try { connection.socket?.close() } catch (_: Exception) {}
            }
        }
        return id
    }

    private fun readHeaders(input: InputStream): String {
        val bytes = java.io.ByteArrayOutputStream()
        var last = 0
        while (true) {
            val b = input.read()
            if (b < 0) break
            bytes.write(b)
            last = (last shl 8 or b) and 0xFFFFFFFF.toInt()
            if (last == 0x0D0A0D0A) break
        }
        return bytes.toString("UTF-8")
    }

    /** A masked client frame. */
    private fun frame(opcode: Int, payload: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(0x80 or opcode)
        val length = payload.size
        when {
            length < 126 -> out.write(0x80 or length)
            length < 65536 -> { out.write(0x80 or 126); out.write(length shr 8); out.write(length and 0xFF) }
            else -> { out.write(0x80 or 127); for (shift in 56 downTo 0 step 8) out.write((length.toLong() shr shift).toInt() and 0xFF) }
        }
        val mask = ByteArray(4).also { random.nextBytes(it) }
        out.write(mask)
        for (i in payload.indices) out.write(payload[i].toInt() xor mask[i % 4].toInt())
        return out.toByteArray()
    }

    override fun send(id: Int, text: String) {
        val connection = connections[id] ?: return
        val output = connection.output ?: return
        thread(name = "visor-send") {
            try { synchronized(connection) { output.write(frame(0x1, text.toByteArray(Charsets.UTF_8))); output.flush() } } catch (_: Exception) {}
        }
    }

    override fun disconnect(id: Int) {
        val connection = connections.remove(id) ?: return
        connection.gone = true
        try { connection.socket?.close() } catch (_: Exception) {}
        connection.events.put("close disconnected")
    }

    override suspend fun next(id: Int): String = suspendCoroutine { cont ->
        val connection = connections[id]
        if (connection == null) { cont.resumeWithException(RuntimeException("no such socket")); return@suspendCoroutine }
        thread(name = "visor-next-$id") {
            val event = connection.events.take()
            if (event.startsWith("close") || event.startsWith("error")) connections.remove(id)
            cont.resume(event)
        }
    }

    override suspend fun delay(milliseconds: Int): Unit = suspendCoroutine { cont ->
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ cont.resume(Unit) }, milliseconds.coerceAtLeast(0).toLong())
    }
}

/** One request with a bearer token: the body for 2xx, a throw otherwise. */
class HttpClient : HttpBridge {
    override suspend fun request(method: String, url: String, body: String, authorization: String): String = suspendCoroutine { cont ->
        thread(name = "visor-http") {
            try {
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.requestMethod = if (method.isEmpty()) "GET" else method
                connection.connectTimeout = 15000
                connection.readTimeout = 30000
                connection.setRequestProperty("Authorization", "Bearer $authorization")
                if (body.isNotEmpty()) {
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.doOutput = true
                    connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
                val status = connection.responseCode
                val stream = if (status in 200..299) connection.inputStream else (connection.errorStream ?: connection.inputStream)
                val text = try { stream.use { String(it.readBytes(), Charsets.UTF_8) } } catch (_: Exception) { "" }
                if (status in 200..299) cont.resume(text) else cont.resumeWithException(RuntimeException("HTTP $status: ${text.take(200)}"))
            } catch (error: Exception) {
                cont.resumeWithException(error)
            }
        }
    }
}

/** The device's networks: each IPv4 interface's address and mask, and the
 *  system's word when the default network changes, passed on when the
 *  interfaces differ (not for the network the callback reports when it is
 *  registered, which would set every sign-in under way going again). */
class NetworkWatch private constructor() : NetworkBridge {
    companion object {
        /** One for the process: an activity made again (a rotation) installs
         *  the services again, and each would register a callback. */
        val shared by lazy { NetworkWatch() }
    }

    private val lock = Object()
    private var reported = currentInterfaces()
    /** A change not yet asked for, and the client waiting on the next. */
    private var pending = false
    private var waiter: kotlin.coroutines.Continuation<Unit>? = null

    init {
        val manager = HostServices.appContext?.getSystemService(android.net.ConnectivityManager::class.java)
        manager?.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) = updated()
            override fun onLost(network: android.net.Network) = updated()
            override fun onLinkPropertiesChanged(network: android.net.Network, properties: android.net.LinkProperties) = updated()
        })
    }

    override fun interfaces(): String = currentInterfaces()

    override suspend fun changed(): Unit = suspendCoroutine { cont ->
        val now = synchronized(lock) {
            if (pending) { pending = false; true } else { waiter = cont; false }
        }
        if (now) cont.resume(Unit)
    }

    private fun updated() {
        val now = currentInterfaces()
        val waiting = synchronized(lock) {
            if (now == reported) return
            reported = now
            val waiting = waiter
            waiter = null
            if (waiting == null) pending = true
            waiting
        }
        waiting?.resume(Unit)
    }

    /** "address/mask" per IPv4 interface, loopback left out, sorted. */
    private fun currentInterfaces(): String {
        val lines = ArrayList<String>()
        try {
            for (networkInterface in java.net.NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()) {
                if (!networkInterface.isUp || networkInterface.isLoopback) continue
                for (entry in networkInterface.interfaceAddresses) {
                    val address = entry.address as? java.net.Inet4Address ?: continue
                    val prefix = entry.networkPrefixLength.toInt().coerceIn(0, 32)
                    val mask = if (prefix == 0) 0L else (0xFFFFFFFFL shl (32 - prefix)) and 0xFFFFFFFFL
                    val dotted = "${mask shr 24}.${(mask shr 16) and 255}.${(mask shr 8) and 255}.${mask and 255}"
                    lines.add("${address.hostAddress}/$dotted")
                }
            }
        } catch (_: Exception) {
        }
        return lines.sorted().joinToString("\n")
    }
}

/** The saved computers and caches, in a private preferences file. */
class PreferencesSettings : SettingsBridge {
    companion object {
        /** Settings the launch intent gave (see VisorAndroidServices.install). */
        val launchOverrides = HashMap<String, String>()
    }

    private val preferences get() = HostServices.appContext?.getSharedPreferences("visor", android.content.Context.MODE_PRIVATE)

    // `host.deviceName`: what the servers this client carries messages for
    // call it (the phone's model); `host.appVersion` and `host.platform`:
    // this build and system, which the client reports to them.
    override fun get(key: String): String = when (key) {
        "host.deviceName" -> android.os.Build.MODEL
        "host.appVersion" -> appVersion()
        "host.platform" -> "Android"
        // Android suspends the app in the background and its sockets with it.
        "host.socketsDropInBackground" -> "1"
        else -> launchOverrides[key] ?: preferences?.getString(key, "") ?: ""
    }

    private fun appVersion(): String {
        val context = HostServices.appContext ?: return ""
        return try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            "${info.versionName} (${info.longVersionCode})"
        } catch (error: Exception) {
            ""
        }
    }

    override fun set(key: String, value: String) {
        val editor = preferences?.edit() ?: return
        if (value.isEmpty()) editor.remove(key) else editor.putString(key, value)
        editor.apply()
    }
}
