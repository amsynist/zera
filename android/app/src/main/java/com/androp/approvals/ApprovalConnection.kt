package com.androp.approvals

import android.net.Uri
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

internal class ApprovalPairing private constructor(val host: String, val port: Int, val key: ByteArray) {
    /** Matches the Mac's Bonjour name suffix: the first four bytes of SHA-256(key), in hex. */
    val fingerprint: String get() = fingerprint(key)

    fun moved(host: String, port: Int) = ApprovalPairing(host, port, key)

    fun toJson(): JSONObject = JSONObject().put("host", host).put("port", port)
        .put("key", Base64.encodeToString(key, Base64.NO_WRAP))

    companion object {
        fun fingerprint(key: ByteArray): String =
            java.security.MessageDigest.getInstance("SHA-256").digest(key).take(4).joinToString("") { "%02x".format(it) }

        fun restore(json: JSONObject): ApprovalPairing {
            val key = Base64.decode(json.getString("key"), Base64.NO_WRAP)
            val port = json.getInt("port")
            require(key.size == 32 && port in 1..65535)
            return ApprovalPairing(json.getString("host"), port, key)
        }

        fun parse(text: String): ApprovalPairing {
            require(text.length <= 200) { "Scan the approval QR in Zera → Settings → Extras." }
            val uri = Uri.parse(text)
            require(uri.scheme == "zerax" && uri.encodedAuthority == "approvals" && uri.path.isNullOrEmpty() &&
                uri.fragment == null && uri.queryParameterNames == setOf("v", "host", "port", "key") &&
                uri.queryParameterNames.all { uri.getQueryParameters(it).size == 1 } &&
                uri.getQueryParameter("v") == "1") { "Scan the approval QR in Zera → Settings → Extras." }
            val host = uri.getQueryParameter("host").orEmpty()
            val octets = host.split('.')
            require(octets.size == 4 && octets.all { it.toIntOrNull()?.let { n -> n in 0..255 && it == n.toString() } == true } &&
                octets.first().toInt() in 1..223 && !host.startsWith("127.")) { "Invalid Mac address." }
            val port = uri.getQueryParameter("port")?.toIntOrNull()
            require(port != null && port in 1..65535) { "Invalid approval port." }
            val encoded = uri.getQueryParameter("key").orEmpty()
            require(encoded.matches(Regex("[A-Za-z0-9_-]{43}"))) { "Invalid approval QR." }
            val key = Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            require(key.size == 32) { "Invalid approval key." }
            return ApprovalPairing(host, port, key)
        }
    }
}

internal class ApprovalConnection(private val pairing: ApprovalPairing) : AutoCloseable {
    private val socket = Socket(Proxy.NO_PROXY)
    private val key = SecretKeySpec(pairing.key, "AES")
    private lateinit var input: DataInputStream
    private lateinit var output: DataOutputStream
    private lateinit var challenge: ByteArray
    private var sent = 0L
    private var received = 0L

    suspend fun connect() = withContext(Dispatchers.IO) {
        socket.connect(InetSocketAddress(pairing.host, pairing.port), 4500)
        socket.soTimeout = 150_000 // the Mac answers each 60 s ping; two missed replies mean the link is gone
        socket.tcpNoDelay = true
        input = DataInputStream(socket.getInputStream())
        output = DataOutputStream(socket.getOutputStream())
        challenge = readFrame(32, 32)
        send(JSONObject().put("type", "hello"))
    }

    @Synchronized fun send(packet: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(aad(0, sent))
        val frame = cipher.iv + cipher.doFinal(packet.toString().toByteArray(Charsets.UTF_8))
        output.writeInt(frame.size)
        output.write(frame)
        output.flush()
        sent++
    }

    fun receive(): JSONObject {
        val frame = readFrame(28, 32768)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, frame, 0, 12))
        cipher.updateAAD(aad(1, received))
        val plaintext = cipher.doFinal(frame, 12, frame.size - 12)
        received++
        return JSONObject(String(plaintext, Charsets.UTF_8))
    }

    private fun readFrame(min: Int, max: Int): ByteArray {
        val length = input.readInt()
        require(length in min..max)
        return ByteArray(length).also(input::readFully)
    }

    private fun aad(direction: Int, sequence: Long): ByteArray =
        ByteBuffer.allocate(41).put(challenge).put(direction.toByte()).putLong(sequence).array()

    override fun close() { runCatching { socket.close() } }
}
