package com.androp.approvals

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.ContextCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.net.Inet4Address
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume

/**
 * Remembers the Mac pairing across app updates and reboots. The approval key is sealed with a
 * non-exportable Android Keystore key; the watch choice is not secret and is kept beside it.
 */
internal object ApprovalStore {
    private const val PREFS = "zerax_approvals"
    private const val ALIAS = "zerax-approval-pairing"

    fun load(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, 0)
        if (Approvals.watchId == null) {
            Approvals.watchId = prefs.getString("watch_id", null)
            Approvals.watchName = prefs.getString("watch_name", null)
        }
        if (Approvals.pairing != null) return
        val sealed = prefs.getString("pairing", null) ?: return
        Approvals.pairing = runCatching {
            val bytes = Base64.decode(sealed, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            ApprovalPairing.restore(JSONObject(String(cipher.doFinal(bytes, 12, bytes.size - 12), Charsets.UTF_8)))
        }.getOrElse { prefs.edit().remove("pairing").apply(); null }
    }

    fun savePairing(context: Context, pairing: ApprovalPairing) {
        Approvals.pairing = pairing
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(pairing.toJson().toString().toByteArray(Charsets.UTF_8))
        context.getSharedPreferences(PREFS, 0).edit().putString("pairing", Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    fun saveWatch(context: Context, id: String?, name: String?) {
        Approvals.watchId = id
        Approvals.watchName = name
        context.getSharedPreferences(PREFS, 0).edit().putString("watch_id", id).putString("watch_name", name).apply()
    }

    fun forget(context: Context) {
        Approvals.pairing = null
        context.getSharedPreferences(PREFS, 0).edit().remove("pairing").apply()
    }

    fun hasPairing(context: Context) = Approvals.pairing != null || context.getSharedPreferences(PREFS, 0).contains("pairing")

    /** Starts the link when a pairing is remembered. Safe to call from a visible activity or an exempt broadcast. */
    fun resume(context: Context) {
        load(context)
        if (Approvals.pairing != null && Approvals.service == null) {
            runCatching { ContextCompat.startForegroundService(context, Intent(context, ApprovalService::class.java)) }
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return generator.generateKey()
    }
}

/** Finds the paired Mac on the local network when its address or port changed since the QR scan. */
internal object MacFinder {
    suspend fun find(context: Context, fingerprint: String): Pair<String, Int>? = withTimeoutOrNull(6_000) {
        val nsd = context.getSystemService(NsdManager::class.java)
        suspendCancellableCoroutine { done ->
            var finished = false
            lateinit var discovery: NsdManager.DiscoveryListener
            fun finish(value: Pair<String, Int>?) {
                if (finished) return
                finished = true
                runCatching { nsd.stopServiceDiscovery(discovery) }
                if (done.isActive) done.resume(value)
            }
            discovery = object : NsdManager.DiscoveryListener {
                override fun onServiceFound(info: NsdServiceInfo) {
                    if (!info.serviceName.endsWith(fingerprint)) return
                    @Suppress("DEPRECATION")
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, code: Int) = Unit
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            val address = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses.firstOrNull { it is Inet4Address }
                                else @Suppress("DEPRECATION") info.host.takeIf { it is Inet4Address }
                            address?.hostAddress?.let { host -> finish(host to info.port) }
                        }
                    })
                }
                override fun onServiceLost(info: NsdServiceInfo) = Unit
                override fun onDiscoveryStarted(type: String) = Unit
                override fun onDiscoveryStopped(type: String) = Unit
                override fun onStartDiscoveryFailed(type: String, code: Int) { finished = true; if (done.isActive) done.resume(null) }
                override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
            }
            done.invokeOnCancellation { if (!finished) runCatching { nsd.stopServiceDiscovery(discovery) } }
            nsd.discoverServices("_zerax._tcp", NsdManager.PROTOCOL_DNS_SD, discovery)
        }
    }
}

/** App updates and reboots: resume a remembered Mac link. Both broadcasts may start a foreground service. */
class ApprovalRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            ApprovalStore.resume(context)
        }
    }
}
