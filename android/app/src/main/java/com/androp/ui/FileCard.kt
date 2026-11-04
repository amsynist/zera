package com.androp.ui

import android.graphics.*
import android.text.format.Formatter
import android.content.Context

/**
 * The card a file without a picture of its own travels as. The same image is lifted on the phone and
 * sent as the preview, so a PDF splits across the two screens exactly like a photo does.
 */
object FileCard {
    fun render(context: Context, name: String, size: Long?, mime: String): Bitmap {
        val w = 720f; val h = 480f
        val bitmap = Bitmap.createBitmap(w.toInt(), h.toInt(), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(0f, 0f, w, h, Color.rgb(36, 58, 60), Color.rgb(18, 32, 34), Shader.TileMode.CLAMP)
        canvas.drawRoundRect(0f, 0f, w, h, 44f, 44f, paint)
        paint.shader = null
        paint.style = Paint.Style.STROKE; paint.strokeWidth = 3f; paint.color = Color.rgb(64, 88, 86)
        canvas.drawRoundRect(1.5f, 1.5f, w - 1.5f, h - 1.5f, 44f, 44f, paint)
        paint.style = Paint.Style.FILL
        val kind = label(name, mime)
        paint.color = color(kind)
        canvas.drawRoundRect(56f, 56f, 256f, 256f, 40f, 40f, paint)
        paint.color = Color.WHITE; paint.textAlign = Paint.Align.CENTER
        paint.typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
        paint.textSize = if (kind.length > 3) 50f else 62f
        canvas.drawText(kind, 156f, 156f - (paint.descent() + paint.ascent()) / 2, paint)
        paint.textAlign = Paint.Align.LEFT
        paint.typeface = Typeface.create("sans-serif", Typeface.NORMAL)
        paint.textSize = 46f; paint.color = Color.rgb(237, 243, 233)
        canvas.drawText(fit(name, paint, w - 112f), 56f, 352f, paint)
        paint.textSize = 30f; paint.color = Color.rgb(169, 190, 185)
        canvas.drawText(listOfNotNull(kind, size?.let { Formatter.formatShortFileSize(context, it) }).joinToString("  ·  "), 56f, 412f, paint)
        return bitmap
    }

    /** A short type badge: the extension, or a word for the broad kind. */
    fun label(name: String, mime: String): String {
        val ext = name.substringAfterLast('.', "").uppercase()
        return when {
            ext.isNotEmpty() && ext.length <= 4 -> ext
            mime.startsWith("audio/") -> "AUDIO"
            mime.startsWith("text/") -> "TEXT"
            else -> "FILE"
        }
    }

    fun color(kind: String): Int = when (kind) {
        "PDF" -> Color.rgb(222, 86, 86)
        "ZIP", "RAR", "7Z", "TAR", "GZ" -> Color.rgb(214, 152, 58)
        "DOC", "DOCX", "TXT", "RTF", "MD", "TEXT" -> Color.rgb(78, 132, 224)
        "XLS", "XLSX", "CSV" -> Color.rgb(64, 170, 112)
        "PPT", "PPTX", "KEY" -> Color.rgb(226, 120, 64)
        "APK" -> Color.rgb(96, 196, 150)
        "MP3", "M4A", "WAV", "FLAC", "OGG", "AUDIO" -> Color.rgb(150, 112, 226)
        "JPG", "JPEG", "PNG", "HEIC", "WEBP", "GIF", "MP4", "MOV", "MKV" -> Color.rgb(64, 150, 170)
        else -> Color.rgb(90, 120, 116)
    }

    private fun fit(text: String, paint: Paint, width: Float): String {
        if (paint.measureText(text) <= width) return text
        var cut = text
        while (cut.length > 1 && paint.measureText("$cut…") > width) cut = cut.dropLast(1)
        return "$cut…"
    }
}
