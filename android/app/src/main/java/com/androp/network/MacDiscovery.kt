package com.androp.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper

/** Start/stop are confined to the main looper, including all NSD callbacks. */
class MacDiscovery(context: Context, private val onMacFound: (String, Int, String) -> Unit) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val main = Handler(Looper.getMainLooper())
    private var lock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.DiscoveryListener? = null
    private var resolving = false

    fun start() {
        if (listener != null) return
        val current = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onServiceFound(info: NsdServiceInfo) { main.post {
                if (listener !== this || resolving || !info.serviceType.contains("_androp._tcp")) return@post
                resolving = true
                val discovery = listener
                @Suppress("DEPRECATION")
                manager.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) { main.post { if (listener === discovery) resolving = false } }
                    override fun onServiceResolved(info: NsdServiceInfo) { main.post {
                        if (listener === discovery) { resolving = false; info.host?.hostAddress?.let { onMacFound(it, info.port, info.serviceName) } }
                    } }
                })
            } }
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) { main.post { stop() } }
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
        }
        listener = current
        runCatching {
            lock = wifi.createMulticastLock("androp.discovery").apply { setReferenceCounted(false); acquire() }
            manager.discoverServices("_androp._tcp.", NsdManager.PROTOCOL_DNS_SD, current) }.onFailure { stop() }
    }

    fun stop() {
        val current = listener
        listener = null
        resolving = false
        if (current != null) runCatching { manager.stopServiceDiscovery(current) }
        lock?.let { if (it.isHeld) it.release() }
        lock = null
    }
}
