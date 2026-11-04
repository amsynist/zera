package com.androp

import android.app.Activity
import android.app.Instrumentation
import android.content.ContentValues
import android.content.Intent
import android.graphics.*
import android.os.*
import android.provider.MediaStore
import android.view.*
import android.widget.GridView
import android.widget.ImageView
import com.androp.network.AndropConnection
import java.io.File

/** Release media uses only this synthetic artwork on a disposable emulator. */
class MediaCapture(private val test: Instrumentation) {
    private val context get() = test.targetContext
    fun seed() {
        val resolver = context.contentResolver
        val photographs = File(context.filesDir, "media-assets").listFiles { file -> file.extension.lowercase() in setOf("png", "jpg", "jpeg") }?.sortedBy { it.name }.orEmpty()
        if (photographs.isNotEmpty()) {
            resolver.delete(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "${MediaStore.Images.Media.DISPLAY_NAME} LIKE ?", arrayOf("Zera demo%"))
            // External original assets are copied byte-for-byte; no drawing or recompression.
            for (index in 0 until photographs.size * 3) {
                val selected = index == photographs.size * 3 - 1
                val source = if (selected) photographs.first { it.name.startsWith("00-") } else photographs[(index * 5 + index / photographs.size) % photographs.size]
                val name = if (selected) "Zera coast.png" else "Zera demo ${index.toString().padStart(2, '0')}.png"
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name); put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Zera demo"); put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
                resolver.openOutputStream(uri)!!.use { output -> source.inputStream().use { it.copyTo(output) } }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
                if (selected) source.copyTo(File(context.filesDir, "transfer-photo.png"), overwrite = true)
                Thread.sleep(1100)
            }
            return
        }
        resolver.delete(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "${MediaStore.Images.Media.DISPLAY_NAME} LIKE ?", arrayOf("Zera demo%"))
        for (index in 0..7) {
            val bitmap = Bitmap.createBitmap(1440, 1008, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val pairs = arrayOf(0xffedb58b.toInt() to 0xff8675ab.toInt(), 0xffb9d9d0.toInt() to 0xff647e82.toInt(),
                0xffd9c5a7.toInt() to 0xffa28f77.toInt(), 0xffc4d5df.toInt() to 0xff637e99.toInt())
            val pair = pairs[index % pairs.size]
            paint.shader = LinearGradient(0f, 0f, 0f, 1008f, pair.first, pair.second, Shader.TileMode.CLAMP)
            canvas.drawRect(0f, 0f, 1440f, 1008f, paint); paint.shader = null
            paint.color = 0xffffedc7.toInt(); canvas.drawCircle(1020f, 270f, 111f, paint)
            for (hill in 0..2) {
                paint.color = intArrayOf(0xff70848e.toInt(), 0xff485f70.toInt(), 0xff293f51.toInt())[hill]
                val y = 550f + hill * 145
                val path = Path().apply { moveTo(0f, y); cubicTo(420f, y - 190, 960f, y + 150, 1440f, y + 30)
                    lineTo(1440f, 1008f); lineTo(0f, 1008f); close() }
                canvas.drawPath(path, paint)
            }
            val name = if (index == 7) "Zera coast.png" else "Zera demo $index.png"
            val values = ContentValues().apply { put(MediaStore.Images.Media.DISPLAY_NAME, name); put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Zera demo"); put(MediaStore.Images.Media.IS_PENDING, 1) }
            val uri = checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
            resolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            if (index == 7) File(context.filesDir, "transfer-photo.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            Thread.sleep(1100) // MediaStore ordering is seconds on older devices.
        }
    }
    fun share() {
        val result = Bundle()
        File(context.filesDir, "phone-timing.json").delete()
        try {
            val activity = test.startActivitySync(Intent(context, com.androp.ui.MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            test.waitForIdleSync()
            val deadline = SystemClock.uptimeMillis() + 12000
            while (!AndropConnection.isConnected && SystemClock.uptimeMillis() < deadline) Thread.sleep(100)
            check(AndropConnection.isConnected) { "The isolated Mac receiver is not connected" }
            val grid = activity.findViewById<GridView>(R.id.mediaGrid)
            while (grid.childCount == 0 && SystemClock.uptimeMillis() < deadline) Thread.sleep(100)
            check(grid.childCount > 0) { "Demo gallery is empty" }
            result.putLong("connected_epoch_ms", System.currentTimeMillis())
            Thread.sleep(2800); screenshot("phone-home.png")
            // Select our exact synthetic image even if a previous recording is newer in MediaStore.
            val position = (0 until grid.childCount).first { index ->
                val frame = grid.getChildAt(index) as android.view.ViewGroup
                val uri = (frame.getChildAt(0) as ImageView).tag as android.net.Uri
                context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                    it.moveToFirst() && it.getString(0).startsWith("Zera coast")
                } == true
            } + grid.firstVisiblePosition
            result.putLong("selected_epoch_ms", System.currentTimeMillis())
            test.runOnMainSync { grid.performItemClick(grid.getChildAt(position - grid.firstVisiblePosition), position, grid.adapter.getItemId(position)) }
            Thread.sleep(1600); screenshot("phone-photo.png")
            Thread.sleep(500)
            val card = activity.findViewById<ImageView>(R.id.dragCard)
            val point = IntArray(2)
            var x = 0f; var y = 0f
            test.runOnMainSync { card.getLocationOnScreen(point); x = point[0] + card.width / 2f; y = point[1] + card.height / 2f }
            val width = context.resources.displayMetrics.widthPixels.toFloat()
            val t = SystemClock.uptimeMillis()
            fun inject(action: Int, px: Float, wait: Boolean = false) {
                val event = MotionEvent.obtain(t, SystemClock.uptimeMillis(), action, px, y, 0)
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                check(test.uiAutomation.injectInputEvent(event, wait)); event.recycle()
            }
            result.putLong("gesture_epoch_ms", System.currentTimeMillis())
            inject(MotionEvent.ACTION_DOWN, x, true)
            // Asynchronous injection keeps Binder acknowledgement latency out of the gesture cadence.
            // Match display vsync over a natural 1.1-second continuous swipe.
            val swipeStart = SystemClock.uptimeMillis()
            for (step in 1..66) {
                val due = swipeStart + step * 1100L / 66
                val pause = due - SystemClock.uptimeMillis()
                if (pause > 0) Thread.sleep(pause)
                val fraction = step / 66f
                val eased = fraction * fraction * (3 - 2 * fraction)
                inject(MotionEvent.ACTION_MOVE, x + (width - 3 - x) * eased)
            }
            result.putLong("release_epoch_ms", System.currentTimeMillis())
            inject(MotionEvent.ACTION_UP, width - 3, true)
            Thread.sleep(15000)
            result.putString("stream", "Real native Gallery photo gesture captured; verify the Mac original SHA-256.\n")
            File(context.filesDir, "phone-timing.json").writeText(org.json.JSONObject().apply {
                for (key in result.keySet()) put(key, result.get(key))
            }.toString(2))
            test.finish(Activity.RESULT_OK, result)
        } catch (e: Throwable) {
            result.putString("stream", e.stackTraceToString()); test.finish(Activity.RESULT_CANCELED, result)
        }
    }
    private fun screenshot(name: String) {
        test.uiAutomation.takeScreenshot()?.let { bitmap -> File(context.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle() }
    }
}
