package com.androp.network

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Size
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Holds a source, not a whole photo/video. Original bytes are read only as chunks are sent. */
data class TransferContent(
    val name: String,
    val mime: String,
    val bytes: ByteArray? = null,
    val thumbnail: String = "",
    val uri: Uri? = null,
    val size: Long? = bytes?.size?.toLong()
) {
    fun open(context: Context): InputStream = bytes?.let { ByteArrayInputStream(it) }
        ?: context.contentResolver.openInputStream(requireNotNull(uri))
        ?: error("The source app didn't grant file access. Share it to Androp instead.")

    companion object {
        fun text(value: String) = TransferContent("Note.txt", "text/plain", value.toByteArray(Charsets.UTF_8))

        /** A file from Androp's own Files tab (all-files access); read through the same stream path. */
        fun file(context: Context, file: java.io.File, card: (TransferContent) -> android.graphics.Bitmap?): TransferContent {
            val read = read(context, Uri.fromFile(file))
            if (read.thumbnail.isNotEmpty()) return read
            // No picture of its own: the drawn file card travels as its preview, so both screens show the same thing.
            val drawn = card(read) ?: return read
            return read.copy(thumbnail = encodeThumbnail(drawn).also { drawn.recycle() })
        }

        fun read(context: Context, uri: Uri): TransferContent {
            require(uri.scheme == "content" || uri.scheme == "file") { "Choose a file from the picker or Share menu" }
            val resolver = context.contentResolver
            var name = "File"
            var size: Long? = null
            if (uri.scheme == "file") uri.path?.let { java.io.File(it) }?.let { name = it.name; size = it.length() }
            else resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                if (it.moveToFirst()) {
                    val n = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = it.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0) name = it.getString(n) ?: name
                    if (s >= 0 && !it.isNull(s)) size = it.getLong(s).takeIf { value -> value >= 0 }
                }
            }
            val mime = (if (uri.scheme == "file") android.webkit.MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) else resolver.getType(uri))
                ?: "application/octet-stream"
            val preview = if (mime.startsWith("image/") || mime.startsWith("video/")) runCatching { preview(context, uri, mime) }.getOrNull() else null
            val thumbnail = preview?.let { encodeThumbnail(it).also { _ -> it.recycle() } } ?: ""
            return TransferContent(name, mime, thumbnail = thumbnail, uri = uri, size = size)
        }

        /** The Mac shows the photo or video frame itself as the card, so this must look like the file. */
        private fun preview(context: Context, uri: Uri, mime: String): Bitmap? {
            val resolver = context.contentResolver
            // The system thumbnail is upright (EXIF/rotation applied) and covers videos too.
            if (Build.VERSION.SDK_INT >= 29) runCatching { return resolver.loadThumbnail(uri, Size(THUMB, THUMB), null) }
            if (mime.startsWith("video/")) {
                val retriever = MediaMetadataRetriever()
                return try {
                    retriever.setDataSource(context, uri)
                    if (Build.VERSION.SDK_INT >= 27) retriever.getScaledFrameAtTime(-1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, THUMB, THUMB)
                    else retriever.getFrameAtTime(-1)
                } finally { retriever.release() }
            }
            // Bounds + sampled decoding keeps even very large camera originals out of the heap.
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
            options.inSampleSize = 1
            while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > THUMB) options.inSampleSize *= 2
            options.inJustDecodeBounds = false
            return resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
        }

        /** At most 480 px, JPEG: well inside the protocol's 512 KiB preview limit. */
        fun encodeThumbnail(source: Bitmap): String {
            val scale = minOf(1f, THUMB.toFloat() / maxOf(source.width, source.height))
            val software = if (source.config == Bitmap.Config.HARDWARE) source.copy(Bitmap.Config.ARGB_8888, false) else source
            val bitmap = if (scale < 1f) Bitmap.createScaledBitmap(software, (software.width * scale).toInt().coerceAtLeast(1),
                (software.height * scale).toInt().coerceAtLeast(1), true) else software
            val output = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 78, output)
            if (bitmap !== source) bitmap.recycle()
            if (software !== source && software !== bitmap) software.recycle()
            return Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
        }

        private const val THUMB = 480
    }
}
