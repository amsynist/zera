package com.androp.ui

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Environment
import android.text.TextUtils
import android.text.format.DateUtils
import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.*
import kotlinx.coroutines.*
import java.io.File

/**
 * The Files tab: Downloads, Documents and the rest of shared storage, like the Files app. Folders
 * first, then newest files. Tap a file to open its card; press and hold to lift it off an edge.
 */
class FileBrowser(
    private val context: Context,
    private val list: ListView,
    private val places: LinearLayout,
    private val path: TextView,
    private val onOpen: (File) -> Unit,
    private val onLift: (File, View) -> Unit,
) {
    private val storage = Environment.getExternalStorageDirectory()
    private val roots = listOf(
        "Downloads" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        "Documents" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
        "Pictures" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
        "Movies" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
        "Music" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
        "All storage" to storage,
    )
    private var root = roots.first().second
    private var current = root
    private val entries = mutableListOf<File>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val density = context.resources.displayMetrics.density
    private val adapter = object : BaseAdapter() {
        override fun getCount() = entries.size
        override fun getItem(position: Int) = entries[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View = row(entries[position], convertView)
    }

    init {
        list.adapter = adapter
        list.setOnItemClickListener { _, _, position, _ ->
            val file = entries[position]
            if (file.isDirectory) show(file) else onOpen(file)
        }
        list.setOnItemLongClickListener { _, view, position, _ ->
            val file = entries[position]
            if (file.isDirectory) false else { onLift(file, view); true }
        }
        roots.forEach { (label, dir) -> places.addView(chip(label, dir)) }
        markChips()
    }

    fun show(dir: File = current) {
        current = dir
        path.text = if (dir == root) "" else dir.absolutePath.removePrefix(root.absolutePath).trimStart('/')
        path.visibility = if (path.text.isEmpty()) View.GONE else View.VISIBLE
        scope.launch {
            val found = withContext(Dispatchers.IO) {
                (dir.listFiles() ?: emptyArray()).filter { !it.name.startsWith(".") }
                    .sortedWith(compareByDescending<File> { it.isDirectory }.thenByDescending { it.lastModified() })
            }
            entries.clear(); entries.addAll(found)
            adapter.notifyDataSetChanged()
            list.setSelection(0)
        }
    }

    /** Back inside a place goes up a folder; at a place's top it lets the screen handle Back. */
    fun up(): Boolean {
        if (current == root) return false
        show(current.parentFile ?: root)
        return true
    }

    fun close() = scope.cancel()

    private fun chip(label: String, dir: File) = TextView(context).apply {
        text = label; tag = dir; textSize = 12f; gravity = Gravity.CENTER
        setPadding((14 * density).toInt(), 0, (14 * density).toInt(), 0)
        layoutParams = LinearLayout.LayoutParams(-2, (36 * density).toInt()).apply { marginEnd = (8 * density).toInt() }
        setOnClickListener { root = dir; markChips(); show(dir) }
    }

    private fun markChips() {
        for (i in 0 until places.childCount) {
            val chip = places.getChildAt(i) as TextView
            val on = chip.tag == root
            chip.setTextColor(if (on) Color.rgb(18, 41, 32) else Color.rgb(196, 236, 221))
            chip.background = GradientDrawable().apply {
                cornerRadius = 18 * density
                setColor(if (on) Color.rgb(196, 236, 221) else Color.rgb(34, 57, 51))
            }
        }
    }

    private fun row(file: File, recycled: View?): View {
        val row = (recycled as? LinearLayout) ?: LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding((16 * density).toInt(), (10 * density).toInt(), (16 * density).toInt(), (10 * density).toInt())
            addView(TextView(context).apply {
                gravity = Gravity.CENTER; setTextColor(Color.WHITE); textSize = 10f
                typeface = android.graphics.Typeface.DEFAULT_BOLD
            }, LinearLayout.LayoutParams((44 * density).toInt(), (44 * density).toInt()))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding((14 * density).toInt(), 0, 0, 0)
                addView(TextView(context).apply { setTextColor(Color.rgb(237, 243, 233)); textSize = 14f; maxLines = 1; ellipsize = TextUtils.TruncateAt.MIDDLE })
                addView(TextView(context).apply { setTextColor(Color.rgb(150, 173, 164)); textSize = 11f; maxLines = 1 })
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }
        val badge = row.getChildAt(0) as TextView
        val texts = row.getChildAt(1) as LinearLayout
        val kind = if (file.isDirectory) "▸" else FileCard.label(file.name, "")
        badge.text = kind
        badge.textSize = if (kind.length > 3) 9f else 11f
        badge.background = GradientDrawable().apply {
            cornerRadius = 12 * density
            setColor(if (file.isDirectory) Color.rgb(34, 57, 51) else FileCard.color(kind))
        }
        (texts.getChildAt(0) as TextView).text = file.name
        val age = DateUtils.getRelativeTimeSpanString(file.lastModified(), System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
        (texts.getChildAt(1) as TextView).text =
            if (file.isDirectory) "Folder  ·  $age" else "${Formatter.formatShortFileSize(context, file.length())}  ·  $age"
        row.contentDescription = if (file.isDirectory) "Folder ${file.name}" else "${file.name}. Press and hold to lift it, then glide it off an edge."
        return row
    }
}
