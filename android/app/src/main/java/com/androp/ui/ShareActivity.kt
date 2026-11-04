package com.androp.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import com.androp.network.*
import kotlinx.coroutines.*

class ShareActivity : AppCompatActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var status: TextView
    private var sent = false
    private var acquired = false
    private val observer: (Boolean, String) -> Unit = { connected, message ->
        if (!sent) { status.text = message; if (connected) send() }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(32, 56, 32, 32)
            setBackgroundColor(0xFF101A1C.toInt())
        }
        layout.addView(TextView(this).apply { text = "A little closer."; textSize = 32f; setTextColor(0xFFEDF3E9.toInt()); typeface = android.graphics.Typeface.SERIF })
        status = TextView(this).apply { textSize = 16f; setPadding(0, 24, 0, 24); setTextColor(0xFFC4ECDD.toInt()) }
        layout.addView(status)
        layout.addView(Button(this).apply { text = "Connection settings"; setOnClickListener { startActivity(Intent(this@ShareActivity, MainActivity::class.java)); finish() } })
        layout.addView(Button(this).apply { text = "Close"; setOnClickListener { finish() } })
        setContentView(layout)
        if (intent.action != Intent.ACTION_SEND) { status.text = "Share one file or a piece of text to Androp."; return }
        AndropConnection.acquire(this); acquired = true
        AndropConnection.observe(observer)
        scope.launch { delay(15_000); if (!sent) status.text = "Mac not connected. Open connection settings, check Wi-Fi, then share again." }
    }
    private fun send() {
        sent = true
        scope.launch {
            status.text = "Passing through…"
            runCatching {
                val content = withContext(Dispatchers.IO) {
                    @Suppress("DEPRECATION")
                    val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                        ?: intent.clipData?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.uri
                    uri?.let { TransferContent.read(this@ShareActivity, it) }
                        ?: TransferContent.text(intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: error("No readable content was shared"))
                }
                val id = AndropConnection.enter(content)
                AndropConnection.commit(id, content) { sent, total, rate ->
                    status.text = if (total != null && total > 0) "${sent * 100 / total}% · ${android.text.format.Formatter.formatShortFileSize(this@ShareActivity, rate)}/s" else "${android.text.format.Formatter.formatShortFileSize(this@ShareActivity, sent)} · ${android.text.format.Formatter.formatShortFileSize(this@ShareActivity, rate)}/s"
                }
            }.onSuccess { status.text = it; delay(1200); finish() }
                .onFailure { status.text = it.message ?: "Transfer interrupted. Check Downloads before retrying." }
        }
    }
    override fun onDestroy() {
        scope.cancel()
        if (acquired) { AndropConnection.removeObserver(observer); AndropConnection.release() }
        super.onDestroy()
    }
}
