package com.androp.fixture

import android.app.Activity
import android.content.*
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.*
import android.net.Uri
import android.os.*
import android.provider.OpenableColumns
import android.view.View
import android.widget.*
import java.io.File

/** Separate UID: exercises real cross-app drag grants, rather than same-app access. */
class DragSourceActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val image = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
        Canvas(image).apply { drawColor(Color.rgb(110, 169, 150)); drawCircle(220f, 80f, 40f, Paint().apply { color = Color.rgb(244, 230, 190) }) }
        val edge = intent.getStringExtra("edge").takeIf { it in listOf("LEFT", "RIGHT", "TOP", "BOTTOM") } ?: "LEFT"
        val name = if (intent.getBooleanExtra("large", false)) "large.bin" else "fixture-$edge.png"
        if (name == "large.bin") {
            val file = File(filesDir, name)
            if (file.length() != 100L * 1024 * 1024) {
                val chunk = ByteArray(1024 * 1024) { (it % 251).toByte() }
                file.outputStream().use { output -> repeat(100) { output.write(chunk) } }
            }
        } else File(filesDir, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(48, 180, 48, 40) }
        layout.addView(TextView(this).apply { text = "Long press, then drag to Androp's edge"; textSize = 24f })
        val uri = Uri.parse("content://com.androp.fixture.files/$name")
        layout.addView(ImageView(this).apply {
            setImageBitmap(image); contentDescription = "Fixture image"
            setOnLongClickListener { startDragAndDrop(ClipData.newUri(contentResolver, "Fixture image", uri), View.DragShadowBuilder(this), null, View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ) }
        }, LinearLayout.LayoutParams(-1, 600))
        layout.addView(TextView(this).apply {
            text = "Drag this text to your Mac"; textSize = 22f; setPadding(20, 80, 20, 80)
            setOnLongClickListener { startDragAndDrop(ClipData.newPlainText("Fixture note", "A note from another app."), View.DragShadowBuilder(this), null, View.DRAG_FLAG_GLOBAL) }
        })
        setContentView(layout)
    }
}
class FixtureProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = if (uri.lastPathSegment?.endsWith(".png") == true) "image/png" else "application/octet-stream"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply { addRow(arrayOf(uri.lastPathSegment, file(uri).length())) }
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r")
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }
    private fun file(uri: Uri): File {
        val name = requireNotNull(uri.lastPathSegment)
        require(name in listOf("fixture-LEFT.png", "fixture-RIGHT.png", "fixture-TOP.png", "fixture-BOTTOM.png", "large.bin"))
        return File(context!!.filesDir, name)
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
}
