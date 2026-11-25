package com.androp.network

import okhttp3.HttpUrl
import java.net.URI

internal data class PairingEndpoint(val host: String, val port: Int) {
    val address: String
        get() {
            val literal = if (':' in host) "[$host]" else host
            return if (port == DEFAULT_PORT) literal else "$literal:$port"
        }

    companion object {
        const val DEFAULT_PORT = 8989
        private val codePattern = Regex("[0-9]{6}")
        private val ipv4Pattern = Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}")

        fun validCode(code: String) = codePattern.matches(code)

        fun manual(input: String): PairingEndpoint {
            val error = "Enter the Mac address shown in Zera, such as 192.168.1.24"
            require(input.isNotEmpty() && input.none { it.isWhitespace() || it in "/\\@?#%" }) { error }
            val host: String
            val port: Int
            if (input.startsWith("[")) {
                val end = input.indexOf(']')
                require(end > 1) { error }
                host = input.substring(1, end)
                val suffix = input.substring(end + 1)
                port = if (suffix.isEmpty()) DEFAULT_PORT else {
                    require(suffix.startsWith(':')) { error }
                    requireNotNull(suffix.drop(1).toIntOrNull()) { error }
                }
            } else if (input.count { it == ':' } == 1) {
                host = input.substringBefore(':')
                port = requireNotNull(input.substringAfter(':').toIntOrNull()) { error }
            } else {
                host = input
                port = DEFAULT_PORT
            }
            val url = runCatching { HttpUrl.Builder().scheme("http").host(host).port(port).build() }.getOrNull()
            requireNotNull(url) { error }
            return PairingEndpoint(url.host, url.port)
        }

        fun scanned(payload: String): Pair<PairingEndpoint, String> {
            val error = "Scan the pairing QR from Zera’s Android sharing settings"
            require(payload.length <= 180) { error }
            val uri = requireNotNull(runCatching { URI(payload) }.getOrNull()) { error }
            require(uri.scheme == "androp" && uri.rawAuthority == "pair" &&
                uri.rawPath.isEmpty() && uri.rawFragment == null) { error }
            val entries = uri.rawQuery.orEmpty().split('&').map { it.split('=', limit = 2) }
            require(entries.size == 4 && entries.all { it.size == 2 }) { error }
            val fields = entries.associate { it[0] to it[1] }
            val host = fields["host"].orEmpty()
            val port = fields["port"]?.toIntOrNull()
            val code = fields["code"].orEmpty()
            require(fields["v"] == "1" && validCode(code) && port != null && port in 1..65535 &&
                ipv4Pattern.matches(host) && host.split('.').all { it.toInt() <= 255 } &&
                host.substringBefore('.').toInt() in 1..223 && !host.startsWith("127.")) { error }
            return PairingEndpoint(host, port) to code
        }
    }
}
