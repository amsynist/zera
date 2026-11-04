package com.androp.network

import org.json.JSONObject

data class DragEnterPacket(
    val id: String,
    val name: String,
    val mimeType: String,
    val thumbnailBase64: String,
    val edge: String = "RIGHT" // Tells Mac which edge to emerge from
) {
    fun toJson(): String {
        return JSONObject().apply {
            put("type", "DRAG_ENTER")
            put("id", id)
            put("name", name)
            put("mimeType", mimeType)
            put("thumbnail", thumbnailBase64)
            put("edge", edge)
        }.toString()
    }
}

data class DragUpdatePacket(
    val id: String,
    val normalizedY: Float,
    val crossRatio: Float,
    val velocityX: Float,
    val velocityY: Float
) {
    fun toJson(): String {
        return JSONObject().apply {
            put("type", "DRAG_UPDATE")
            put("id", id)
            put("normalizedY", normalizedY)
            put("crossRatio", crossRatio)
            put("velocityX", velocityX)
            put("velocityY", velocityY)
        }.toString()
    }
}

data class DragReleasePacket(
    val id: String,
    val action: String, // "COMMIT" or "CANCEL"
    val velocityX: Float,
    val velocityY: Float,
    val fullDataBase64: String? = null
) {
    fun toJson(): String {
        return JSONObject().apply {
            put("type", "DRAG_RELEASE")
            put("id", id)
            put("action", action)
            put("velocityX", velocityX)
            put("velocityY", velocityY)
            if (fullDataBase64 != null) {
                put("fullData", fullDataBase64)
            }
        }.toString()
    }
}
