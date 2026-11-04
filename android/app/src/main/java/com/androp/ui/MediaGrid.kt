package com.androp.ui

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.GridView
import android.widget.ImageView
import android.widget.TextView
import kotlinx.coroutines.*

/**
 * The phone's own photos and videos inside Androp, newest first. Picking one here puts it on the
 * card with its real thumbnail and details, so the whole swipe to the Mac shows the picture itself
 * (a drag from another app only reveals the item at the drop).
 */
class MediaGrid(private val context: Context, private val grid: GridView, private val onPick: (Uri, Boolean) -> Unit,
                private val onLift: (Uri, Boolean, View) -> Unit) {
    private data class Item(val uri: Uri, val video: Boolean)
    private val items = mutableListOf<Item>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val thumbnails = object : LruCache<Uri, Bitmap>(12 * 1024 * 1024) {
        override fun sizeOf(key: Uri, value: Bitmap) = value.byteCount
    }
    private val adapter = object : BaseAdapter() {
        override fun getCount() = items.size
        override fun getItem(position: Int) = items[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View = tile(items[position], convertView, parent)
    }

    init {
        grid.adapter = adapter
        grid.setOnItemClickListener { _, _, position, _ -> onPick(items[position].uri, items[position].video) }
        // Press and hold lifts the photo out of the grid, ready to glide off an edge.
        grid.setOnItemLongClickListener { _, view, position, _ -> onLift(items[position].uri, items[position].video, view); true }
    }

    fun load() {
        scope.launch {
            val found = withContext(Dispatchers.IO) { runCatching { query() }.getOrDefault(emptyList()) }
            items.clear(); items.addAll(found)
            adapter.notifyDataSetChanged()
        }
    }

    fun close() = scope.cancel()

    private fun query(): List<Item> {
        val found = mutableListOf<Item>()
        val columns = arrayOf(MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE)
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"
        context.contentResolver.query(MediaStore.Files.getContentUri("external"), columns, selection, null,
            "${MediaStore.Files.FileColumns.DATE_ADDED} DESC")?.use { cursor ->
            val id = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val type = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            while (cursor.moveToNext() && found.size < 600) {
                val video = cursor.getInt(type) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val base = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                found.add(Item(ContentUris.withAppendedId(base, cursor.getLong(id)), video))
            }
        }
        return found
    }

    private fun tile(item: Item, recycled: View?, parent: ViewGroup): View {
        val columns = grid.numColumns.coerceAtLeast(1)
        val side = ((parent.width - parent.paddingLeft - parent.paddingRight - (columns - 1) * grid.horizontalSpacing) / columns).coerceAtLeast(1)
        val frame = (recycled as? FrameLayout) ?: FrameLayout(context).apply {
            val radius = 12 * context.resources.displayMetrics.density
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) = outline.setRoundRect(0, 0, view.width, view.height, radius)
            }
            clipToOutline = true
            addView(ImageView(context).apply { scaleType = ImageView.ScaleType.CENTER_CROP; setBackgroundColor(Color.rgb(27, 41, 43)) },
                FrameLayout.LayoutParams(-1, -1))
            addView(TextView(context).apply { text = "▶"; setTextColor(Color.WHITE); textSize = 12f; setShadowLayer(4f, 0f, 1f, Color.BLACK) },
                FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.END).apply { setMargins(0, 0, 8, 4) })
        }
        frame.layoutParams = ViewGroup.LayoutParams(side, side)
        frame.contentDescription = if (item.video) "Video" else "Photo"
        val image = frame.getChildAt(0) as ImageView
        frame.getChildAt(1).visibility = if (item.video) View.VISIBLE else View.GONE
        image.tag = item.uri
        val cached = thumbnails.get(item.uri)
        image.setImageBitmap(cached)
        if (cached == null) scope.launch {
            val bitmap = withContext(Dispatchers.IO) { runCatching { thumbnail(item, side) }.getOrNull() } ?: return@launch
            thumbnails.put(item.uri, bitmap)
            if (image.tag == item.uri) image.setImageBitmap(bitmap)
        }
        return frame
    }

    private fun thumbnail(item: Item, side: Int): Bitmap? = if (Build.VERSION.SDK_INT >= 29) {
        context.contentResolver.loadThumbnail(item.uri, Size(side, side), null)
    } else {
        @Suppress("DEPRECATION")
        if (item.video) MediaStore.Video.Thumbnails.getThumbnail(context.contentResolver, ContentUris.parseId(item.uri), MediaStore.Video.Thumbnails.MINI_KIND, null)
        else MediaStore.Images.Thumbnails.getThumbnail(context.contentResolver, ContentUris.parseId(item.uri), MediaStore.Images.Thumbnails.MINI_KIND, null)
    }
}
