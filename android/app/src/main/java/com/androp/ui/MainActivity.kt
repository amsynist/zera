package com.androp.ui

import android.Manifest
import android.content.*
import android.graphics.*
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.util.Size
import android.graphics.drawable.BitmapDrawable
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.*
import androidx.activity.addCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.androp.R
import com.androp.gesture.EdgeGestureDetector
import com.androp.network.*
import com.androp.overlay.EdgeOverlayService
import com.google.android.material.materialswitch.MaterialSwitch
import kotlinx.coroutines.*

/** A gallery first: tap a photo or video, then glide the picture itself off any edge to the Mac. */
class MainActivity : AppCompatActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val prefs by lazy { getSharedPreferences("androp", MODE_PRIVATE) }
    private lateinit var ripple: EdgeRippleView
    private lateinit var hint: TextView
    private lateinit var overlaySwitch: MaterialSwitch
    private lateinit var viewer: View
    private lateinit var settings: View
    private lateinit var card: ImageView
    private var content: TransferContent? = null
    private var activePhoneEdge = "LEFT"
    private var dragId: String? = null
    private var dragContent: TransferContent? = null
    private var sending = false
    private var updatingSwitch = false
    private var wantsOverlay = false
    private var media: MediaGrid? = null
    private var files: FileBrowser? = null
    private var onFiles = false
    private var opening: Job? = null
    /** A grid photo lifted by press-and-hold: it follows the same finger off an edge. */
    private var lifted: ImageView? = null
    private var liftedTile: View? = null
    private var liftDetector: EdgeGestureDetector? = null
    private var liftSent = false
    private var pendingEdge: String? = null
    private var touchX = 0f
    private var touchY = 0f
    private val swipe = object : EdgeGestureDetector.Listener {
        override fun onDragEnter(edge: String) {
            activePhoneEdge = edge
            ripple.edge = edge
            if (sending) return
            dragContent = content
            // A lifted photo may reach the edge before it has finished loading; announce it once ready.
            if (dragContent == null) { pendingEdge = edge; return }
            runCatching { dragContent?.let { dragId = AndropConnection.enter(it, phoneEdge = activePhoneEdge) } }
                .onFailure { hint.text = it.message }
            if (dragId != null) ripple.approach(0.5f)
        }
        override fun onDragUpdate(normalizedY: Float, crossRatio: Float, velocityX: Float, velocityY: Float) {
            dragId?.let {
                ripple.approach(normalizedY)
                ripple.cross(crossRatio)
                AndropConnection.client.sendDragUpdate(DragUpdatePacket(it, normalizedY, crossRatio, velocityX, velocityY))
            }
        }
        override fun onDragRelease(committed: Boolean, velocityX: Float, velocityY: Float) {
            pendingEdge = null
            ripple.release(committed && dragId != null)
            val id = dragId; dragId = null
            if (id == null) return
            if (!committed) { AndropConnection.cancel(id); return }
            send(id, dragContent)
            val view = lifted ?: card
            liftSent = lifted != null
            view.post { flyOff(view) }
        }
    }
    private val observer: (Boolean, String) -> Unit = { connected, message ->
        findViewById<TextView>(R.id.tvStatus).text = if (connected) "●  CONNECTED" else "○  OFFLINE"
        findViewById<TextView>(R.id.connectionStatus).text = message
    }
    private val overlayPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (wantsOverlay && Settings.canDrawOverlays(this)) requestNotificationsAndStart()
        else { wantsOverlay = false; syncSwitch() }
    }
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { startOverlay() }
    private val mediaAccess = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { showMedia() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        val root = findViewById<View>(R.id.rootContainer)
        root.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION")
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        root.requestApplyInsets()
        ripple = findViewById(R.id.edgeRipple)
        hint = findViewById(R.id.tvHint)
        card = findViewById(R.id.dragCard)
        viewer = findViewById(R.id.viewer)
        settings = findViewById(R.id.settings)
        overlaySwitch = findViewById(R.id.overlaySwitch)
        AndropConnection.acquire(this)
        AndropConnection.observe(observer)
        findViewById<EditText>(R.id.etHost).setText(prefs.getString("host", ""))
        findViewById<EditText>(R.id.etCode).setText(prefs.getString("code", ""))
        findViewById<View>(R.id.btnConnect).setOnClickListener {
            runCatching { AndropConnection.pair(findViewById<EditText>(R.id.etHost).text.toString().trim(), findViewById<EditText>(R.id.etCode).text.toString()) }
                .onFailure { findViewById<TextView>(R.id.connectionStatus).text = it.message }
        }
        // Unpaired: settings first. Paired: straight to the photos.
        settings.visibility = if (prefs.getString("code", "").isNullOrEmpty()) View.VISIBLE else View.GONE
        findViewById<View>(R.id.btnSettings).setOnClickListener { settings.visibility = View.VISIBLE }
        findViewById<View>(R.id.tvStatus).setOnClickListener { settings.visibility = View.VISIBLE }
        findViewById<View>(R.id.settingsClose).setOnClickListener { settings.visibility = View.GONE }
        findViewById<View>(R.id.btnMedia).setOnClickListener { mediaAccess.launch(mediaPermissions()) }
        findViewById<View>(R.id.btnFiles).setOnClickListener { askFileAccess() }
        findViewById<View>(R.id.tabPhotos).setOnClickListener { showTab(files = false) }
        findViewById<View>(R.id.tabFiles).setOnClickListener { showTab(files = true) }
        showTab(files = prefs.getBoolean("filesTab", false))
        findViewById<View>(R.id.viewerClose).setOnClickListener { closeViewer() }
        findViewById<View>(R.id.viewerSend).setOnClickListener { if (!sending && content != null) { send(); closeViewer() } }
        onBackPressedDispatcher.addCallback(this) {
            when {
                settings.visibility == View.VISIBLE -> settings.visibility = View.GONE
                viewer.visibility == View.VISIBLE -> closeViewer()
                onFiles && files?.up() == true -> Unit
                else -> { isEnabled = false; onBackPressedDispatcher.onBackPressed(); isEnabled = true }
            }
        }
        showMedia()
        overlaySwitch.setOnCheckedChangeListener { _, enabled ->
            if (!updatingSwitch) {
                if (enabled) enableOverlay() else { wantsOverlay = false; stopService(Intent(this, EdgeOverlayService::class.java)) }
            }
        }
        findViewById<View>(R.id.btnTestEdge).setOnClickListener {
            if (Settings.canDrawOverlays(this)) {
                ContextCompat.startForegroundService(this, Intent(this, EdgeOverlayService::class.java).setAction("PREVIEW"))
            } else enableOverlay()
        }
        scope.launch { EdgeOverlayService.status.collect { findViewById<TextView>(R.id.edgeStatus).text = it; syncSwitch() } }
        val radius = 14 * resources.displayMetrics.density
        card.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) = outline.setRoundRect(0, 0, view.width, view.height, radius)
        }
        card.clipToOutline = true
        card.setOnTouchListener(EdgeGestureDetector(card, ::edge, swipe))
        // After a press-and-hold the grid (or file list) hands its touch stream to the lifted item instead of scrolling.
        val forward = View.OnTouchListener { _, event ->
            val view = lifted
            if (view == null) { touchX = event.rawX; touchY = event.rawY; return@OnTouchListener false }
            liftDetector?.onTouch(view, event)
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) settleLift()
            true
        }
        findViewById<GridView>(R.id.mediaGrid).setOnTouchListener(forward)
        findViewById<ListView>(R.id.filesList).setOnTouchListener(forward)
    }

    private fun showTab(files: Boolean) {
        onFiles = files
        prefs.edit().putBoolean("filesTab", files).apply()
        findViewById<View>(R.id.photosPane).visibility = if (files) View.GONE else View.VISIBLE
        findViewById<View>(R.id.filesPane).visibility = if (files) View.VISIBLE else View.GONE
        for ((id, on) in listOf(R.id.tabPhotos to !files, R.id.tabFiles to files)) findViewById<TextView>(id).apply {
            setTextColor(if (on) Color.rgb(18, 41, 32) else Color.rgb(196, 236, 221))
            background = if (on) android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = 18 * resources.displayMetrics.density; setColor(Color.rgb(196, 236, 221))
            } else null
        }
        if (files) showFiles() else showMedia()
    }

    private fun hasFileAccess() = if (Build.VERSION.SDK_INT >= 30) android.os.Environment.isExternalStorageManager()
        else ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun askFileAccess() {
        if (Build.VERSION.SDK_INT < 30) { mediaAccess.launch(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)); return }
        runCatching { startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))) }
            .onFailure { startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)) }
    }

    /** Downloads, Documents and the rest of shared storage, once access is granted. */
    private fun showFiles() {
        val granted = hasFileAccess()
        findViewById<View>(R.id.filesEmpty).visibility = if (granted) View.GONE else View.VISIBLE
        findViewById<View>(R.id.filesList).visibility = if (granted) View.VISIBLE else View.GONE
        hint.text = if (granted) "Hold a file, then glide it off any edge to your Mac." else "Press and hold, then glide it off any edge to your Mac."
        if (!granted) return
        val shown = files ?: FileBrowser(this, findViewById(R.id.filesList), findViewById(R.id.places), findViewById(R.id.filesPath),
            onOpen = { openFile(it) }, onLift = { file, row -> liftFile(file, row) }).also { files = it }
        shown.show()
    }

    private fun fileContent(file: java.io.File) = TransferContent.file(this, file) { FileCard.render(this, it.name, it.size, it.mime) }

    private fun openFile(file: java.io.File) {
        openWith(false) { fileContent(file).let { it to (it.thumbnail.takeIf { t -> t.isNotEmpty() }?.let { t -> decode(t) }) } }
    }

    /** Press and hold a file: its card rises out of the row under the finger, ready to cross. */
    private fun liftFile(file: java.io.File, row: View) {
        val density = resources.displayMetrics.density
        val w = (220 * density).toInt(); val h = (147 * density).toInt()
        val mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: ""
        val card = FileCard.render(this, file.name, file.length(), mime)
        lift(row, card, w, h, offsetX = (16 * density).toInt()) { fileContent(file) }
    }

    private fun decode(base64: String): Bitmap? =
        android.util.Base64.decode(base64, android.util.Base64.DEFAULT).let { BitmapFactory.decodeByteArray(it, 0, it.size) }

    private fun mediaPermissions() = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    /** Any granted media access (including Android 14's "selected photos") shows the grid. */
    private fun showMedia() {
        val granted = mediaPermissions().any { ContextCompat.checkSelfPermission(this, it) == android.content.pm.PackageManager.PERMISSION_GRANTED }
        findViewById<View>(R.id.mediaEmpty).visibility = if (granted) View.GONE else View.VISIBLE
        val grid = findViewById<GridView>(R.id.mediaGrid)
        grid.visibility = if (granted) View.VISIBLE else View.GONE
        if (!granted) return
        hint.text = "Press and hold, then glide it off any edge to your Mac."
        val shown = media ?: MediaGrid(this, grid, { uri, video -> open(uri, video) }, { uri, _, tile -> liftPhoto(uri, tile) }).also { media = it }
        shown.load()
    }

    /** One photo or video, full screen, sized to its own shape so its edges are the ones that cross. */
    private fun open(uri: Uri, video: Boolean) {
        openWith(video) {
            val payload = TransferContent.read(this@MainActivity, uri)
            payload to (large(uri) ?: payload.thumbnail.takeIf { it.isNotEmpty() }?.let { decode(it) })
        }
    }

    private fun openWith(video: Boolean, load: () -> Pair<TransferContent, Bitmap?>) {
        if (sending) return
        opening?.cancel()
        content = null
        card.setImageDrawable(null)
        card.translationX = 0f; card.translationY = 0f; card.rotation = 0f; card.alpha = 1f
        findViewById<TextView>(R.id.viewerName).text = ""
        viewer.visibility = View.VISIBLE
        opening = scope.launch {
            runCatching { withContext(Dispatchers.IO) { load() } }.onSuccess { (payload, picture) ->
                content = payload
                findViewById<TextView>(R.id.viewerName).text = (if (video) "▶  " else "") + payload.name
                card.contentDescription = "${payload.name}. Glide it off any edge to send it to your Mac."
                picture?.let { fit(it) }
            }.onFailure { hint.text = it.message ?: "Couldn't open it"; closeViewer() }
        }
    }

    private fun large(uri: Uri): Bitmap? = if (Build.VERSION.SDK_INT >= 29)
        runCatching { contentResolver.loadThumbnail(uri, Size(1600, 1600), null) }.getOrNull() else null

    private fun fit(picture: Bitmap) {
        viewer.post {
            val margin = 20 * resources.displayMetrics.density
            val maxW = viewer.width - 2 * margin
            val maxH = viewer.height - 9 * margin
            val scale = minOf(maxW / picture.width, maxH / picture.height)
            card.layoutParams = (card.layoutParams as FrameLayout.LayoutParams).apply {
                width = (picture.width * scale).toInt(); height = (picture.height * scale).toInt()
            }
            card.setImageBitmap(picture)
        }
    }

    /** Sent: the rest of the picture leaves through the edge it was crossing, then back to the grid. */
    private fun flyOff(view: View) {
        view.animate().cancel()
        val root = findViewById<View>(R.id.rootContainer)
        val far = 2f * maxOf(root.width, root.height)
        val (x, y) = when (activePhoneEdge) { "LEFT" -> -far to 0f; "RIGHT" -> far to 0f; "TOP" -> 0f to -far; else -> 0f to far }
        view.animate().translationXBy(x).translationYBy(y).setDuration(220)
            .withEndAction { if (view === card) closeViewer() else dropLift() }.start()
    }

    /** Press and hold a photo: it rises out of its tile under the finger, already carrying its real details. */
    private fun liftPhoto(uri: Uri, tile: View) {
        val picture = ((tile as? FrameLayout)?.getChildAt(0) as? ImageView)?.drawable as? BitmapDrawable ?: return
        lift(tile, picture.bitmap, tile.width, tile.height) { TransferContent.read(this@MainActivity, uri) }
    }

    private fun lift(source: View, picture: Bitmap, w: Int, h: Int, offsetX: Int = 0, load: () -> TransferContent) {
        if (sending || lifted != null) return
        val tile = source
        val root = findViewById<FrameLayout>(R.id.rootContainer)
        val at = IntArray(2).also { tile.getLocationOnScreen(it) }
        val origin = IntArray(2).also { root.getLocationOnScreen(it) }
        val radius = 12 * resources.displayMetrics.density
        val view = ImageView(this).apply {
            setImageBitmap(picture)
            scaleType = ImageView.ScaleType.CENTER_CROP
            elevation = 16 * resources.displayMetrics.density
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) = outline.setRoundRect(0, 0, view.width, view.height, radius)
            }
            clipToOutline = true
            contentDescription = "Lifted photo. Glide it off any edge to send it to your Mac."
        }
        root.addView(view, FrameLayout.LayoutParams(w, h).apply {
            leftMargin = at[0] - origin[0] - root.paddingLeft + offsetX
            topMargin = at[1] - origin[1] - root.paddingTop + (tile.height - h) / 2
        })
        tile.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        tile.alpha = 0.25f
        view.animate().scaleX(1.08f).scaleY(1.08f).setDuration(120).start()
        lifted = view; liftedTile = tile; liftSent = false; pendingEdge = null
        content = null
        liftDetector = EdgeGestureDetector(view, ::edge, swipe).also { detector ->
            val now = SystemClock.uptimeMillis()
            MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, touchX, touchY, 0).also { detector.onTouch(view, it); it.recycle() }
        }
        scope.launch {
            val payload = runCatching { withContext(Dispatchers.IO) { load() } }
                .onFailure { hint.text = it.message ?: "Couldn't read it" }.getOrNull() ?: return@launch
            if (lifted !== view) return@launch
            content = payload
            pendingEdge?.let { edge -> pendingEdge = null; swipe.onDragEnter(edge) }
        }
    }

    /** Let go without sending: the photo settles back into its tile. */
    private fun settleLift() {
        val view = lifted ?: return
        if (liftSent) return
        if (dragId != null) return
        view.animate().scaleX(1f).scaleY(1f).translationX(0f).translationY(0f).rotation(0f).setDuration(200)
            .withEndAction { dropLift() }.start()
    }

    private fun dropLift() {
        val view = lifted ?: return
        (view.parent as? FrameLayout)?.removeView(view)
        liftedTile?.alpha = 1f
        lifted = null; liftedTile = null; liftDetector = null; liftSent = false; pendingEdge = null
    }

    private fun closeViewer() {
        opening?.cancel()
        viewer.visibility = View.GONE
        card.animate().cancel()
        card.translationX = 0f; card.translationY = 0f; card.rotation = 0f
    }

    private fun edge() = "AUTO"

    private fun send(existingId: String? = null, selected: TransferContent? = content) {
        val payload = selected ?: return
        if (sending) return
        scope.launch {
            sending = true
            hint.text = "Passing through…"
            runCatching {
                val id = existingId ?: AndropConnection.enter(payload, phoneEdge = activePhoneEdge)
                AndropConnection.commit(id, payload) { sent, total, rate ->
                    val size = android.text.format.Formatter.formatShortFileSize(this@MainActivity, sent)
                    hint.text = if (total != null && total > 0) "${sent * 100 / total}% · ${android.text.format.Formatter.formatShortFileSize(this@MainActivity, rate)}/s" else "$size · ${android.text.format.Formatter.formatShortFileSize(this@MainActivity, rate)}/s"
                }
            }.onSuccess { hint.text = it; hint.announceForAccessibility(it) }
                .onFailure { hint.text = if (it is TimeoutCancellationException) "No confirmation from Mac. Check Downloads before retrying." else it.message ?: "Transfer interrupted" }
            sending = false
        }
    }

    private fun enableOverlay() {
        wantsOverlay = true
        if (!Settings.canDrawOverlays(this)) {
            overlayPermission.launch(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        } else requestNotificationsAndStart()
    }
    private fun requestNotificationsAndStart() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        else startOverlay()
    }
    private fun startOverlay() {
        if (!Settings.canDrawOverlays(this)) { syncSwitch(); return }
        runCatching { ContextCompat.startForegroundService(this, Intent(this, EdgeOverlayService::class.java)) }
            .onFailure { findViewById<TextView>(R.id.edgeStatus).text = "Couldn't start edge receiver: ${it.message}" }
        wantsOverlay = false
        scope.launch { delay(350); syncSwitch() }
    }
    private fun syncSwitch() {
        updatingSwitch = true
        overlaySwitch.isChecked = Settings.canDrawOverlays(this) && EdgeOverlayService.isRunning
        updatingSwitch = false
    }
    override fun onResume() {
        super.onResume()
        if (::overlaySwitch.isInitialized && !wantsOverlay) syncSwitch()
        // New photos or files since last time, or access granted in system settings.
        if (::viewer.isInitialized) { if (onFiles) showFiles() else showMedia() }
    }
    override fun onDestroy() {
        dragId?.let { AndropConnection.cancel(it) }
        media?.close()
        files?.close()
        scope.cancel()
        AndropConnection.removeObserver(observer)
        AndropConnection.release()
        super.onDestroy()
    }
}
